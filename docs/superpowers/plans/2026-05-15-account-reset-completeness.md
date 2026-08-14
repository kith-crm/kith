# Account Reset Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Kith.Workers.AccountResetWorker` fully wipe a single account's data (imports, conversations, journal, tasks, reminders, plus existing contacts/tags/activities/audit), cancel its in-flight Oban jobs first, while leaving every other account untouched.

**Architecture:** The worker becomes a thin orchestrator that iterates over an ordered list of per-domain `Cleanup` modules. Each cleanup module exposes `wipe_for_account(account_id) :: :ok` and lives next to its domain (`Kith.Imports.Cleanup`, `Kith.Conversations.Cleanup`, etc.). Account scoping is enforced inside each cleanup with a `where: x.account_id == ^account_id` clause. In-flight Oban job cancellation queries `Oban.Job` directly with account-scoped filters (`import_id IN account's imports` / `account_id == this_account`).

**Tech Stack:** Elixir, Phoenix, Ecto, Oban, PostgreSQL. Test framework: ExUnit + Oban.Testing.

**Spec:** `docs/superpowers/specs/2026-05-15-account-reset-completeness-design.md`

**Worktree:** Work happens in the existing branch `fix/duplicate-detection` at `/Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection`. Each task is one commit; push at the end.

---

## File structure (locked-in decomposition)

**New files:**

| Path | Responsibility |
|---|---|
| `lib/kith/imports/cleanup.ex` | Wipe `imports` + `import_records` for one account |
| `lib/kith/imports/job_cancellation.ex` | Cancel Oban jobs whose `args.import_id ∈ account's imports` (+ DuplicateDetection by `account_id`) |
| `lib/kith/conversations/cleanup.ex` | Wipe `conversations` (CASCADE → `messages`) |
| `lib/kith/journal/cleanup.ex` | Wipe `journal_entries` |
| `lib/kith/tasks/cleanup.ex` | Wipe `tasks` |
| `lib/kith/reminders/cleanup.ex` | Cancel reminder Oban jobs + wipe `reminders` (CASCADE → `reminder_rules` + `reminder_instances`) |
| `lib/kith/storage/account_cleanup.ex` | Delete photo + document + import-upload files |
| `lib/kith/contacts/cleanup.ex` | Hard-delete `contacts` (CASCADE) + wipe `tags` |
| `lib/kith/activities/cleanup.ex` | Wipe `activities` |
| `lib/kith/audit_logs/cleanup.ex` | Wipe `audit_logs` |

**Refactored:**

| Path | Change |
|---|---|
| `lib/kith/workers/account_reset_worker.ex` | Replace per-domain private helpers with an ordered `@cleaners` list and `Enum.each` orchestration |

**New tests:** one per cleanup module, plus regression + isolation tests on the worker.

---

## Task ordering rationale

Each task delivers a new cleanup module + tests in one commit. Tasks 1–10 do NOT modify `AccountResetWorker` — they just create the new modules. Task 11 wires the worker to use them, in one commit, with the old private helpers removed. Task 12 adds the user-reported regression test plus the cross-account isolation test on the worker.

This ordering means each task is independently reviewable, the worker change is one atomic commit, and the bug isn't half-fixed at any commit boundary.

---

## Task 1: `Kith.Imports.Cleanup`

**Files:**
- Create: `lib/kith/imports/cleanup.ex`
- Create: `test/kith/imports/cleanup_test.exs`

This is the most bug-critical module — the user's photo sync failure traces directly to orphaned `import_records`. Do it first so end-to-end testing on dev can validate the fix early.

- [ ] **Step 1: Write the failing test**

Create `test/kith/imports/cleanup_test.exs`:

```elixir
defmodule Kith.Imports.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Imports
  alias Kith.Imports.{Cleanup, Import, ImportRecord}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "wipes imports + import_records for target account; leaves other account untouched", ctx do
    target_import =
      import_fixture(ctx.target_account, ctx.target_user, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    other_import =
      import_fixture(ctx.other_account, ctx.other_user, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    {:ok, _} = Imports.record_imported_entity(target_import, "contact", "1", "contact", 999)
    {:ok, _} = Imports.record_imported_entity(other_import, "contact", "1", "contact", 999)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Import, ctx.target_account) == 0
    assert count_for(ImportRecord, ctx.target_account) == 0

    # Control account untouched
    assert count_for(Import, ctx.other_account) == 1
    assert count_for(ImportRecord, ctx.other_account) == 1
  end

  test "is idempotent on an account with no import data", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/imports/cleanup_test.exs
```

Expected: compile error — `Kith.Imports.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/imports/cleanup.ex`:

```elixir
defmodule Kith.Imports.Cleanup do
  @moduledoc """
  Wipes all import history for a single account.

  Deletes `import_records` first then `imports`. Both tables are scoped by
  `account_id` directly. Called by `Kith.Workers.AccountResetWorker`.
  """

  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {records, _} =
      Repo.delete_all(from(r in ImportRecord, where: r.account_id == ^account_id))

    {imports, _} =
      Repo.delete_all(from(i in Import, where: i.account_id == ^account_id))

    Logger.info(
      "[Imports.Cleanup] wiped #{records} record(s) + #{imports} import(s) for account #{account_id}"
    )

    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/imports/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/imports/cleanup.ex test/kith/imports/cleanup_test.exs
git commit -m "feat: add Kith.Imports.Cleanup for account-scoped import wipe"
```

---

## Task 2: `Kith.Imports.JobCancellation`

**Files:**
- Create: `lib/kith/imports/job_cancellation.ex`
- Create: `test/kith/imports/job_cancellation_test.exs`

Cancels pending/scheduled/retryable/executing Oban jobs for this account's imports. Matches by `args.import_id IN (account's imports)` for the four import-worker classes, plus `args.account_id == this_account` for `DuplicateDetectionWorker`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/imports/job_cancellation_test.exs`:

```elixir
defmodule Kith.Imports.JobCancellationTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports.JobCancellation
  alias Kith.Repo
  alias Kith.Workers.{DuplicateDetectionWorker, MonicaPhotoSyncWorker}

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    target_import =
      import_fixture(target.account_id, target.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    other_import =
      import_fixture(other.account_id, other.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    %{
      target_account: target.account_id,
      target_import: target_import,
      other_account: other.account_id,
      other_import: other_import
    }
  end

  test "cancels target account's import jobs; leaves other account's jobs alone", ctx do
    {:ok, target_photo_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.target_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    {:ok, other_photo_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.other_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, target_photo_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_photo_job.id).state == "available"
  end

  test "cancels DuplicateDetectionWorker jobs by account_id", ctx do
    {:ok, target_dup_job} =
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: ctx.target_account}))

    {:ok, other_dup_job} =
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: ctx.other_account}))

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, target_dup_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_dup_job.id).state == "available"
  end

  test "is a no-op when account has no jobs", ctx do
    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)
  end

  test "ignores jobs already in 'completed' state", ctx do
    {:ok, completed_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.target_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    # Manually mark as completed
    completed_job
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    # Completed jobs are NOT touched
    assert Repo.get!(Oban.Job, completed_job.id).state == "completed"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/imports/job_cancellation_test.exs
```

Expected: compile error — `Kith.Imports.JobCancellation` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/imports/job_cancellation.ex`:

```elixir
defmodule Kith.Imports.JobCancellation do
  @moduledoc """
  Cancels all pending/scheduled/retryable/executing Oban jobs that belong to a
  single account's imports.

  Scoping rule: only jobs whose args reference this account (directly via
  `account_id` or transitively via `import_id` belonging to one of this
  account's imports) are touched. No other account's jobs are affected.
  """

  alias Kith.Imports.Import
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @import_workers ~w[
    Elixir.Kith.Workers.MonicaApiCrawlWorker
    Elixir.Kith.Workers.MonicaPhotoSyncWorker
    Elixir.Kith.Workers.MonicaDocumentImportWorker
    Elixir.Kith.Workers.ImportSourceWorker
  ]

  @cancellable_states ~w[available scheduled retryable executing]

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    import_ids = account_import_ids(account_id)
    import_cancelled = cancel_jobs_by_import_id(import_ids)
    account_cancelled = cancel_jobs_by_account_id(account_id)

    Logger.info(
      "[Imports.JobCancellation] cancelled #{import_cancelled} import job(s) + " <>
        "#{account_cancelled} account-scoped job(s) for account #{account_id}"
    )

    :ok
  end

  defp account_import_ids(account_id) do
    Repo.all(from(i in Import, where: i.account_id == ^account_id, select: i.id))
  end

  defp cancel_jobs_by_import_id([]), do: 0

  defp cancel_jobs_by_import_id(import_ids) do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker in ^@import_workers,
          where: j.state in ^@cancellable_states,
          where: fragment("(?->>'import_id')::int", j.args) in ^import_ids
        )
      )

    Enum.each(jobs, &Oban.cancel_job/1)
    length(jobs)
  end

  defp cancel_jobs_by_account_id(account_id) do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Elixir.Kith.Workers.DuplicateDetectionWorker",
          where: j.state in ^@cancellable_states,
          where: fragment("(?->>'account_id')::int", j.args) == ^account_id
        )
      )

    Enum.each(jobs, &Oban.cancel_job/1)
    length(jobs)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/imports/job_cancellation_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/imports/job_cancellation.ex test/kith/imports/job_cancellation_test.exs
git commit -m "feat: add Kith.Imports.JobCancellation for account-scoped Oban cancel"
```

---

## Task 3: `Kith.Storage.AccountCleanup`

**Files:**
- Create: `lib/kith/storage/account_cleanup.ex`
- Create: `test/kith/storage/account_cleanup_test.exs`

Iterates storage keys for the account's photos, documents, and import uploads, calls `Kith.Storage.delete/1` on each. Logs warnings on failure but never raises (storage failures must not abort the reset).

- [ ] **Step 1: Write the failing test**

Create `test/kith/storage/account_cleanup_test.exs`:

```elixir
defmodule Kith.Storage.AccountCleanupTest do
  use Kith.DataCase, async: false

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Storage
  alias Kith.Storage.AccountCleanup

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "deletes target account's photo + import-upload files; leaves other account's files alone",
       ctx do
    {target_photo_key, _} = upload_and_attach_photo!(ctx.target_account)
    {other_photo_key, _} = upload_and_attach_photo!(ctx.other_account)

    target_upload_key = upload_import_file!(ctx.target_account, ctx.target_user)
    other_upload_key = upload_import_file!(ctx.other_account, ctx.other_user)

    assert {:ok, _} = Storage.read(target_photo_key)
    assert {:ok, _} = Storage.read(other_photo_key)
    assert {:ok, _} = Storage.read(target_upload_key)
    assert {:ok, _} = Storage.read(other_upload_key)

    assert :ok = AccountCleanup.wipe_for_account(ctx.target_account)

    assert {:error, _} = Storage.read(target_photo_key)
    assert {:error, _} = Storage.read(target_upload_key)

    # Control account untouched
    assert {:ok, _} = Storage.read(other_photo_key)
    assert {:ok, _} = Storage.read(other_upload_key)
  end

  test "is a no-op when account has no files", ctx do
    assert :ok = AccountCleanup.wipe_for_account(ctx.target_account)
  end

  defp upload_and_attach_photo!(account_id) do
    contact = contact_fixture(account_id)
    binary = <<0xFF, 0xD8, 0xFF, 0xE0>>
    key = Storage.generate_key(account_id, "photos", "test.jpg")
    {:ok, _} = Storage.upload_binary(binary, key)

    {:ok, photo} =
      Contacts.create_photo(contact, %{
        "file_name" => "test.jpg",
        "storage_key" => key,
        "file_size" => byte_size(binary),
        "content_type" => "image/jpeg"
      })

    {key, photo}
  end

  defp upload_import_file!(account_id, user_id) do
    key = Storage.generate_key(account_id, "imports", "export.vcf")
    {:ok, _} = Storage.upload_binary("BEGIN:VCARD\nEND:VCARD\n", key)

    {:ok, _} =
      Imports.create_import(account_id, user_id, %{
        source: "vcard",
        file_name: "export.vcf",
        file_size: 22,
        file_storage_key: key
      })

    key
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/storage/account_cleanup_test.exs
```

Expected: compile error — `Kith.Storage.AccountCleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/storage/account_cleanup.ex`:

```elixir
defmodule Kith.Storage.AccountCleanup do
  @moduledoc """
  Deletes physical storage objects (photos, documents, import upload files)
  for a single account.

  Storage failures (S3 already-deleted, network blip) are logged at `:warning`
  but never raise — they must not abort the surrounding account reset.
  Storage objects are recoverable separately (S3 lifecycle, manual sweep)
  and don't affect data integrity.

  Must run BEFORE `Kith.Contacts.Cleanup` — once contacts are hard-deleted,
  the `photos` and `documents` rows are CASCADE-deleted and we can no longer
  iterate their `storage_key` values.
  """

  alias Kith.Contacts.{Contact, Document, Photo}
  alias Kith.Imports.Import
  alias Kith.{Repo, Storage}

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    photo_count = delete_keys(photo_keys(account_id))
    document_count = delete_keys(document_keys(account_id))
    upload_count = delete_keys(import_upload_keys(account_id))

    Logger.info(
      "[Storage.AccountCleanup] deleted #{photo_count} photo file(s) + " <>
        "#{document_count} document file(s) + #{upload_count} import upload(s) " <>
        "for account #{account_id}"
    )

    :ok
  end

  defp photo_keys(account_id) do
    Repo.all(
      from(p in Photo,
        join: c in Contact,
        on: p.contact_id == c.id,
        where: c.account_id == ^account_id,
        select: p.storage_key
      )
    )
  end

  defp document_keys(account_id) do
    Repo.all(
      from(d in Document,
        join: c in Contact,
        on: d.contact_id == c.id,
        where: c.account_id == ^account_id,
        select: d.storage_key
      )
    )
  end

  defp import_upload_keys(account_id) do
    Repo.all(
      from(i in Import,
        where: i.account_id == ^account_id,
        where: not is_nil(i.file_storage_key),
        select: i.file_storage_key
      )
    )
  end

  defp delete_keys(keys) do
    Enum.each(keys, &safe_delete/1)
    length(keys)
  end

  defp safe_delete(nil), do: :ok

  defp safe_delete(key) do
    case Storage.delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Storage.AccountCleanup] failed to delete #{key}: #{inspect(reason)}")
        :ok
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/storage/account_cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/storage/account_cleanup.ex test/kith/storage/account_cleanup_test.exs
git commit -m "feat: add Kith.Storage.AccountCleanup for account-scoped file wipe"
```

---

## Task 4: `Kith.Contacts.Cleanup`

**Files:**
- Create: `lib/kith/contacts/cleanup.ex`
- Create: `test/kith/contacts/cleanup_test.exs`

Hard-deletes contacts (FK CASCADE handles addresses, contact_fields, photos rows, documents rows, notes, debts, gifts, pets, emotions, relationships, calls, life_events, duplicate_candidates, immich_candidates). Also wipes `tags` (account-scoped, no contact FK). Tags share the contacts axis-of-change so they're colocated.

- [ ] **Step 1: Write the failing test**

Create `test/kith/contacts/cleanup_test.exs`:

```elixir
defmodule Kith.Contacts.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts.{Cleanup, Contact, Tag}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      other_account: other.account_id
    }
  end

  test "hard-deletes contacts + tags for target account; leaves other account untouched", ctx do
    contact_fixture(ctx.target_account)
    contact_fixture(ctx.target_account)
    contact_fixture(ctx.other_account)

    Repo.insert!(%Tag{account_id: ctx.target_account, name: "target-tag"})
    Repo.insert!(%Tag{account_id: ctx.other_account, name: "other-tag"})

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Contact, ctx.target_account) == 0
    assert count_for(Tag, ctx.target_account) == 0

    assert count_for(Contact, ctx.other_account) == 1
    assert count_for(Tag, ctx.other_account) == 1
  end

  test "ignores soft-deleted vs not — hard-deletes both", ctx do
    active = contact_fixture(ctx.target_account)
    soft = contact_fixture(ctx.target_account)

    soft
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    refute Repo.get(Contact, active.id)
    refute Repo.get(Contact, soft.id)
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/contacts/cleanup_test.exs
```

Expected: compile error — `Kith.Contacts.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/contacts/cleanup.ex`:

```elixir
defmodule Kith.Contacts.Cleanup do
  @moduledoc """
  Hard-deletes all contacts (and CASCADE sub-entities) and account-scoped
  tags for a single account.

  Sub-entities cleared via FK CASCADE: addresses, contact_fields, photos
  (rows), documents (rows), notes, debts, gifts, pets, emotions,
  relationships, calls, life_events, duplicate_candidates, immich_candidates.

  Note: `Kith.Storage.AccountCleanup` MUST run before this module so that
  photo/document storage_keys can be enumerated before their rows are wiped.

  Tags are wiped here (not in a separate module) because they share the
  contacts axis-of-change and have no other purpose.
  """

  alias Kith.Contacts.{Contact, Tag}
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @batch_size 200

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    contacts_deleted = delete_contacts_in_batches(account_id, 0)

    {tags_deleted, _} =
      Repo.delete_all(from(t in Tag, where: t.account_id == ^account_id))

    Logger.info(
      "[Contacts.Cleanup] hard-deleted #{contacts_deleted} contact(s) + " <>
        "#{tags_deleted} tag(s) for account #{account_id}"
    )

    :ok
  end

  defp delete_contacts_in_batches(account_id, acc) do
    ids =
      Repo.all(
        from(c in Contact,
          where: c.account_id == ^account_id,
          select: c.id,
          limit: @batch_size
        )
      )

    case ids do
      [] ->
        acc

      _ ->
        {deleted, _} = Repo.delete_all(from(c in Contact, where: c.id in ^ids))
        delete_contacts_in_batches(account_id, acc + deleted)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/contacts/cleanup_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/contacts/cleanup.ex test/kith/contacts/cleanup_test.exs
git commit -m "feat: add Kith.Contacts.Cleanup for account-scoped contacts+tags wipe"
```

---

## Task 5: `Kith.Conversations.Cleanup`

**Files:**
- Create: `lib/kith/conversations/cleanup.ex`
- Create: `test/kith/conversations/cleanup_test.exs`

Wipes `conversations` rows; CASCADE removes `messages`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/conversations/cleanup_test.exs`:

```elixir
defmodule Kith.Conversations.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Conversations.{Cleanup, Conversation, Message}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()
    target_contact = contact_fixture(target.account_id)
    other_contact = contact_fixture(other.account_id)

    %{
      target_account: target.account_id,
      target_user: target.id,
      target_contact: target_contact,
      other_account: other.account_id,
      other_user: other.id,
      other_contact: other_contact
    }
  end

  test "wipes conversations (CASCADE messages) for target; leaves other untouched", ctx do
    target_conv = insert_conversation!(ctx.target_account, ctx.target_user, ctx.target_contact.id)
    other_conv = insert_conversation!(ctx.other_account, ctx.other_user, ctx.other_contact.id)

    insert_message!(target_conv.id, ctx.target_account)
    insert_message!(other_conv.id, ctx.other_account)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Conversation, ctx.target_account) == 0
    assert count_for(Message, ctx.target_account) == 0

    assert count_for(Conversation, ctx.other_account) == 1
    assert count_for(Message, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp insert_conversation!(account_id, user_id, contact_id) do
    Repo.insert!(%Conversation{
      account_id: account_id,
      creator_id: user_id,
      contact_id: contact_id,
      subject: "test",
      platform: "other",
      status: "active",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp insert_message!(conversation_id, account_id) do
    Repo.insert!(%Message{
      account_id: account_id,
      conversation_id: conversation_id,
      body: "hi",
      direction: "outgoing",
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

NOTE: If the `Conversation` or `Message` schema fields shown above don't match the actual schema (check `lib/kith/conversations/conversation.ex` and `lib/kith/conversations/message.ex`), adjust the test inserts to satisfy the schema. Required fields per the conversation schema reading are `account_id`, `creator_id`, `contact_id`, `subject`, `occurred_at`. Required for messages: `conversation_id`, `body`, `sent_at`. Read the schemas if any insert fails.

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/conversations/cleanup_test.exs
```

Expected: compile error — `Kith.Conversations.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/conversations/cleanup.ex`:

```elixir
defmodule Kith.Conversations.Cleanup do
  @moduledoc """
  Wipes all conversations for a single account. FK CASCADE removes the
  associated `messages` rows.
  """

  alias Kith.Conversations.Conversation
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(c in Conversation, where: c.account_id == ^account_id))

    Logger.info("[Conversations.Cleanup] wiped #{count} conversation(s) for account #{account_id}")
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/conversations/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

If the insert step fails because of schema mismatch, read `lib/kith/conversations/conversation.ex` and `lib/kith/conversations/message.ex`, fix the test setup, and re-run.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/conversations/cleanup.ex test/kith/conversations/cleanup_test.exs
git commit -m "feat: add Kith.Conversations.Cleanup for account-scoped conversation wipe"
```

---

## Task 6: `Kith.Journal.Cleanup`

**Files:**
- Create: `lib/kith/journal/cleanup.ex`
- Create: `test/kith/journal/cleanup_test.exs`

Wipes `journal_entries`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/journal/cleanup_test.exs`:

```elixir
defmodule Kith.Journal.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Journal
  alias Kith.Journal.{Cleanup, Entry}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "wipes journal entries for target account only", ctx do
    {:ok, _} =
      Journal.create_entry(ctx.target_account, ctx.target_user, %{
        "content" => "target",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _} =
      Journal.create_entry(ctx.other_account, ctx.other_user, %{
        "content" => "other",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Entry, ctx.target_account) == 0
    assert count_for(Entry, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

NOTE: `Journal.create_entry/3` may accept atom or string-keyed attrs. If the test fails on map shape, read `lib/kith/journal.ex:47` for the signature and adjust.

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/journal/cleanup_test.exs
```

Expected: compile error — `Kith.Journal.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/journal/cleanup.ex`:

```elixir
defmodule Kith.Journal.Cleanup do
  @moduledoc """
  Wipes all journal entries for a single account.
  """

  alias Kith.Journal.Entry
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(e in Entry, where: e.account_id == ^account_id))

    Logger.info("[Journal.Cleanup] wiped #{count} journal entr(ies) for account #{account_id}")
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/journal/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/journal/cleanup.ex test/kith/journal/cleanup_test.exs
git commit -m "feat: add Kith.Journal.Cleanup for account-scoped journal wipe"
```

---

## Task 7: `Kith.Tasks.Cleanup`

**Files:**
- Create: `lib/kith/tasks/cleanup.ex`
- Create: `test/kith/tasks/cleanup_test.exs`

Wipes `tasks`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/tasks/cleanup_test.exs`:

```elixir
defmodule Kith.Tasks.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Repo
  alias Kith.Tasks
  alias Kith.Tasks.{Cleanup, Task}

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "wipes tasks for target account only", ctx do
    {:ok, _} = Tasks.create_task(ctx.target_account, ctx.target_user, %{"title" => "target task"})
    {:ok, _} = Tasks.create_task(ctx.other_account, ctx.other_user, %{"title" => "other task"})

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Task, ctx.target_account) == 0
    assert count_for(Task, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/tasks/cleanup_test.exs
```

Expected: compile error — `Kith.Tasks.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/tasks/cleanup.ex`:

```elixir
defmodule Kith.Tasks.Cleanup do
  @moduledoc """
  Wipes all tasks for a single account.
  """

  alias Kith.Repo
  alias Kith.Tasks.Task

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(t in Task, where: t.account_id == ^account_id))

    Logger.info("[Tasks.Cleanup] wiped #{count} task(s) for account #{account_id}")
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/tasks/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/tasks/cleanup.ex test/kith/tasks/cleanup_test.exs
git commit -m "feat: add Kith.Tasks.Cleanup for account-scoped task wipe"
```

---

## Task 8: `Kith.Reminders.Cleanup`

**Files:**
- Create: `lib/kith/reminders/cleanup.ex`
- Create: `test/kith/reminders/cleanup_test.exs`

Cancels Oban jobs tracked in `reminders.enqueued_oban_job_ids` (matching the existing `cancel_reminder_jobs/1` pattern from the current worker), then deletes reminders; CASCADE removes `reminder_rules` and `reminder_instances`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/reminders/cleanup_test.exs`:

```elixir
defmodule Kith.Reminders.CleanupTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Reminders.{Cleanup, Reminder, ReminderInstance, ReminderRule}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.RemindersFixtures

  setup do
    target = user_fixture()
    other = user_fixture()
    target_contact = contact_fixture(target.account_id)
    other_contact = contact_fixture(other.account_id)

    %{
      target_account: target.account_id,
      target_user: target.id,
      target_contact: target_contact,
      other_account: other.account_id,
      other_user: other.id,
      other_contact: other_contact
    }
  end

  test "wipes reminders + CASCADE rules/instances for target only", ctx do
    target_reminder = reminder_fixture(ctx.target_account, ctx.target_contact.id, ctx.target_user)
    other_reminder = reminder_fixture(ctx.other_account, ctx.other_contact.id, ctx.other_user)

    _target_instance = reminder_instance_fixture(target_reminder)
    _other_instance = reminder_instance_fixture(other_reminder)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Reminder, ctx.target_account) == 0
    # rules + instances reference reminder_id, so we count them via the join:
    assert count_orphans(ReminderRule, [target_reminder.id]) == 0
    assert count_orphans(ReminderInstance, [target_reminder.id]) == 0

    assert count_for(Reminder, ctx.other_account) == 1
  end

  test "cancels Oban jobs tracked on the target's reminders", ctx do
    # Insert a real Oban job and attach its id to a reminder
    {:ok, job} =
      Oban.insert(Kith.Workers.ReminderNotificationWorker.new(%{"reminder_instance_id" => 0}))

    target_reminder = reminder_fixture(ctx.target_account, ctx.target_contact.id, ctx.target_user)

    target_reminder
    |> Ecto.Changeset.change(enqueued_oban_job_ids: [job.id])
    |> Repo.update!()

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end

  defp count_orphans(schema, reminder_ids) do
    Repo.aggregate(from(s in schema, where: s.reminder_id in ^reminder_ids), :count)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/reminders/cleanup_test.exs
```

Expected: compile error — `Kith.Reminders.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/reminders/cleanup.ex`:

```elixir
defmodule Kith.Reminders.Cleanup do
  @moduledoc """
  Cancels all Oban jobs tracked on the account's reminders, then deletes
  the reminders. FK CASCADE removes `reminder_rules` and `reminder_instances`.
  """

  alias Kith.Reminders.Reminder
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    cancel_oban_jobs_for_account(account_id)

    {count, _} =
      Repo.delete_all(from(r in Reminder, where: r.account_id == ^account_id))

    Logger.info("[Reminders.Cleanup] wiped #{count} reminder(s) for account #{account_id}")
    :ok
  end

  defp cancel_oban_jobs_for_account(account_id) do
    job_ids =
      Repo.all(
        from(r in Reminder,
          where: r.account_id == ^account_id,
          select: r.enqueued_oban_job_ids
        )
      )
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Enum.each(job_ids, &Oban.cancel_job/1)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/reminders/cleanup_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/reminders/cleanup.ex test/kith/reminders/cleanup_test.exs
git commit -m "feat: add Kith.Reminders.Cleanup for account-scoped reminder wipe"
```

---

## Task 9: `Kith.Activities.Cleanup`

**Files:**
- Create: `lib/kith/activities/cleanup.ex`
- Create: `test/kith/activities/cleanup_test.exs`

Wipes `activities` (account-scoped). No contact FK, so this isn't cleared by `Contacts.Cleanup`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/activities/cleanup_test.exs`:

```elixir
defmodule Kith.Activities.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Activities.{Activity, Cleanup}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      other_account: other.account_id
    }
  end

  test "wipes activities for target account only", ctx do
    Repo.insert!(%Activity{
      account_id: ctx.target_account,
      summary: "target activity",
      happened_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%Activity{
      account_id: ctx.other_account,
      summary: "other activity",
      happened_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Activity, ctx.target_account) == 0
    assert count_for(Activity, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

NOTE: If the `Activity` schema requires different fields (read `lib/kith/activities/activity.ex` if the insert fails), adjust the test setup.

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/activities/cleanup_test.exs
```

Expected: compile error — `Kith.Activities.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/activities/cleanup.ex`:

```elixir
defmodule Kith.Activities.Cleanup do
  @moduledoc """
  Wipes all account-scoped activities for a single account. Activities have
  no contact FK so they are not cleared by `Kith.Contacts.Cleanup`'s CASCADE.
  """

  alias Kith.Activities.Activity
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(a in Activity, where: a.account_id == ^account_id))

    Logger.info("[Activities.Cleanup] wiped #{count} activit(ies) for account #{account_id}")
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/activities/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/activities/cleanup.ex test/kith/activities/cleanup_test.exs
git commit -m "feat: add Kith.Activities.Cleanup for account-scoped activity wipe"
```

---

## Task 10: `Kith.AuditLogs.Cleanup`

**Files:**
- Create: `lib/kith/audit_logs/cleanup.ex`
- Create: `test/kith/audit_logs/cleanup_test.exs`

Wipes `audit_logs`. Runs LAST in the worker pipeline so the "account_data_reset" audit log written at start lives until cleanup is done.

- [ ] **Step 1: Write the failing test**

Create `test/kith/audit_logs/cleanup_test.exs`:

```elixir
defmodule Kith.AuditLogs.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.AuditLogs
  alias Kith.AuditLogs.{AuditLog, Cleanup}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      other_account: other.account_id
    }
  end

  test "wipes audit logs for target account only", ctx do
    {:ok, _} =
      AuditLogs.create_audit_log(ctx.target_account, %{
        user_id: nil,
        user_name: "system",
        event: "account_data_reset",
        metadata: %{}
      })

    {:ok, _} =
      AuditLogs.create_audit_log(ctx.other_account, %{
        user_id: nil,
        user_name: "system",
        event: "account_data_reset",
        metadata: %{}
      })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(AuditLog, ctx.target_account) == 0
    assert count_for(AuditLog, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/kith/audit_logs/cleanup_test.exs
```

Expected: compile error — `Kith.AuditLogs.Cleanup` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/kith/audit_logs/cleanup.ex`:

```elixir
defmodule Kith.AuditLogs.Cleanup do
  @moduledoc """
  Wipes all audit logs for a single account. Runs LAST in the reset pipeline
  so the "account_data_reset" log written at the start of the worker lives
  until the rest of cleanup completes.
  """

  alias Kith.AuditLogs.AuditLog
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(a in AuditLog, where: a.account_id == ^account_id))

    Logger.info("[AuditLogs.Cleanup] wiped #{count} audit log(s) for account #{account_id}")
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mix test test/kith/audit_logs/cleanup_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/audit_logs/cleanup.ex test/kith/audit_logs/cleanup_test.exs
git commit -m "feat: add Kith.AuditLogs.Cleanup for account-scoped audit-log wipe"
```

---

## Task 11: Refactor `AccountResetWorker` to orchestrator

**Files:**
- Modify: `lib/kith/workers/account_reset_worker.ex` (full rewrite of the worker body)

Replace all per-domain private helpers with the ordered `@cleaners` list. Worker becomes ~40 LoC.

- [ ] **Step 1: Replace the entire worker file content**

Open `lib/kith/workers/account_reset_worker.ex` and replace the full content with:

```elixir
defmodule Kith.Workers.AccountResetWorker do
  @moduledoc """
  Resets a single account's data by orchestrating per-domain cleanup modules.

  Wipes everything the account owns except reference data (genders,
  relationship_types, contact_field_types, etc.) and account_invitations.
  Operations are scoped to the target account; no other account is affected.

  Each `@cleaners` module exposes `wipe_for_account(account_id) :: :ok`.
  Order is load-bearing — see `docs/superpowers/specs/2026-05-15-account-reset-completeness-design.md`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:account_id]]

  alias Kith.{Activities, AuditLogs, Contacts, Conversations, Imports, Journal,
              Reminders, Storage, Tasks}

  require Logger

  @cleaners [
    Imports.JobCancellation,
    Storage.AccountCleanup,
    Contacts.Cleanup,
    Imports.Cleanup,
    Conversations.Cleanup,
    Reminders.Cleanup,
    Tasks.Cleanup,
    Journal.Cleanup,
    Activities.Cleanup,
    AuditLogs.Cleanup
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Logger.metadata(account_id: account_id, worker: "AccountReset")
    Logger.info("[AccountReset] starting reset for account #{account_id}")
    write_initiated_audit_log(account_id)

    Enum.each(@cleaners, fn cleaner ->
      Logger.info("[AccountReset] running #{inspect(cleaner)}")
      :ok = cleaner.wipe_for_account(account_id)
    end)

    Logger.info("[AccountReset] completed reset for account #{account_id}")
    :ok
  end

  defp write_initiated_audit_log(account_id) do
    AuditLogs.create_audit_log(account_id, %{
      user_id: nil,
      user_name: "system",
      event: "account_data_reset",
      metadata: %{reason: "Account data reset initiated"}
    })
  end
end
```

- [ ] **Step 2: Run the existing worker test to ensure no regression**

```bash
mix test test/kith_web/live/settings_live/account_live_test.exs
```

The existing test only asserts that the job is enqueued (no behavior assertions on cleanup). Expected: 0 failures.

- [ ] **Step 3: Run the full test suite to catch incidental breakage**

```bash
mix test
```

Expected: all tests pass. The 9 new cleanup modules + the worker are now exercised together.

- [ ] **Step 4: Run `mix format` to normalize the new file**

```bash
mix format
```

- [ ] **Step 5: Commit**

```bash
git add lib/kith/workers/account_reset_worker.ex
git commit -m "refactor: AccountResetWorker becomes orchestrator over per-domain Cleanup modules"
```

---

## Task 12: Regression + cross-account isolation tests on the worker

**Files:**
- Modify: `test/kith/workers/account_reset_worker_test.exs` (create if doesn't exist; the existing coverage is in `account_live_test.exs`)

Adds the user-reported scenario (re-import-after-reset succeeds) and a snapshot-based cross-account isolation test.

- [ ] **Step 1: Check whether the test file already exists**

```bash
ls test/kith/workers/account_reset_worker_test.exs 2>/dev/null && echo "exists" || echo "missing"
```

If "missing", create it from scratch with the content below. If "exists", open the file and add the two new tests inside the existing `describe "perform/1"` block, preserving any existing tests.

- [ ] **Step 2: Write the file (or append the tests)**

Full file content (use this if creating, or merge the tests if appending):

```elixir
defmodule Kith.Workers.AccountResetWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Activities.Activity
  alias Kith.AuditLogs.AuditLog
  alias Kith.Contacts.{Contact, Tag}
  alias Kith.Conversations.Conversation
  alias Kith.Imports
  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Journal.Entry
  alias Kith.Reminders.Reminder
  alias Kith.Repo
  alias Kith.Tasks.Task, as: TaskSchema
  alias Kith.Workers.AccountResetWorker

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures
  import Kith.RemindersFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  describe "perform/1 — regression: re-import after reset" do
    test "re-import for same Monica contact id resolves to new local contact (no stale import_records)",
         ctx do
      # Initial import: contact + import_record for Monica id 964
      import_a =
        import_fixture(ctx.target_account, ctx.target_user, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "k"
        })

      contact_a = contact_fixture(ctx.target_account)

      {:ok, _} =
        Imports.record_imported_entity(import_a, "contact", "964", "contact", contact_a.id)

      # Run reset
      assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})

      # Target account fully wiped
      assert count(Contact, ctx.target_account) == 0
      assert count(Import, ctx.target_account) == 0
      assert count(ImportRecord, ctx.target_account) == 0

      # Re-import: new contact + new import_record for the same Monica id
      import_b =
        import_fixture(ctx.target_account, ctx.target_user, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "k"
        })

      contact_b = contact_fixture(ctx.target_account)

      {:ok, _} =
        Imports.record_imported_entity(import_b, "contact", "964", "contact", contact_b.id)

      # The photo-sync lookup that previously found stale data now resolves correctly
      assert %{local_entity_id: local_id} =
               Imports.find_import_record(ctx.target_account, "monica_api", "contact", "964")

      assert local_id == contact_b.id
    end
  end

  describe "perform/1 — cross-account isolation" do
    test "resetting account A does not touch any data in account B", ctx do
      target_contact = populate_data!(ctx.target_account, ctx.target_user)
      _other_contact = populate_data!(ctx.other_account, ctx.other_user)

      before_other = snapshot(ctx.other_account)

      assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})

      # Target wiped across every domain
      assert empty?(ctx.target_account)

      # Other account is bit-identical to before
      assert snapshot(ctx.other_account) == before_other

      # Sanity: target_contact is gone, other account still has its contact
      refute Repo.get(Contact, target_contact.id)
    end
  end

  defp populate_data!(account_id, user_id) do
    contact = contact_fixture(account_id)

    {:ok, _} =
      import_fixture(account_id, user_id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })
      |> then(&Imports.record_imported_entity(&1, "contact", "1", "contact", contact.id))

    Repo.insert!(%Tag{account_id: account_id, name: "t"})

    Repo.insert!(%Activity{
      account_id: account_id,
      summary: "a",
      happened_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%TaskSchema{
      account_id: account_id,
      creator_id: user_id,
      title: "x"
    })

    Repo.insert!(%Entry{
      account_id: account_id,
      author_id: user_id,
      content: "c",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%Conversation{
      account_id: account_id,
      creator_id: user_id,
      contact_id: contact.id,
      subject: "s",
      platform: "other",
      status: "active",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    _reminder = reminder_fixture(account_id, contact.id, user_id)

    {:ok, _} =
      Kith.AuditLogs.create_audit_log(account_id, %{
        user_id: nil,
        user_name: "test",
        event: "account_data_reset",
        metadata: %{}
      })

    contact
  end

  defp snapshot(account_id) do
    %{
      contacts: count(Contact, account_id),
      imports: count(Import, account_id),
      import_records: count(ImportRecord, account_id),
      conversations: count(Conversation, account_id),
      tasks: count(TaskSchema, account_id),
      journal_entries: count(Entry, account_id),
      reminders: count(Reminder, account_id),
      tags: count(Tag, account_id),
      activities: count(Activity, account_id),
      audit_logs: count(AuditLog, account_id)
    }
  end

  defp empty?(account_id) do
    snapshot(account_id) ==
      %{
        contacts: 0,
        imports: 0,
        import_records: 0,
        conversations: 0,
        tasks: 0,
        journal_entries: 0,
        reminders: 0,
        tags: 0,
        activities: 0,
        audit_logs: 0
      }
  end

  defp count(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
```

NOTE: If `populate_data!` fails to insert any record due to schema mismatch (e.g. an `Activity` requires `kind` or `actor_id`), read the schema file (`lib/kith/activities/activity.ex` etc.) and add the missing required fields. The shape above is based on the moduledoc reading — adjust as needed.

- [ ] **Step 3: Run the new tests**

```bash
mix test test/kith/workers/account_reset_worker_test.exs
```

Expected: 2 tests, 0 failures. If a schema insert fails, fix the populate_data! helper and re-run.

- [ ] **Step 4: Run the FULL test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/kith/workers/account_reset_worker_test.exs
git commit -m "test: add regression + cross-account isolation tests for AccountResetWorker"
```

---

## Task 13: Final verification + push

- [ ] **Step 1: Verify the full quality pipeline**

```bash
mix quality
```

Expected: compile + format + credo + sobelow + dialyzer all clean. The pre-commit hook will have caught most issues already, but run once explicitly.

- [ ] **Step 2: Confirm no stale references to deleted private helpers in the worker**

```bash
grep -n "delete_contacts_in_batches\|delete_tags\|delete_activities\|delete_audit_logs\|delete_stored_files\|cancel_reminder_jobs" lib/kith/workers/account_reset_worker.ex
```

Expected: no matches (all moved into cleanup modules).

- [ ] **Step 3: Push the branch**

```bash
git push
```

- [ ] **Step 4: Manual verification on dev (operator step)**

The implementing engineer should report this step to the operator:

> On the dev environment:
> 1. Run a Monica API import with the "Import photos" option checked.
> 2. Trigger account reset via Settings → Account.
> 3. Re-run the same Monica API import with photos.
> 4. Confirm `MonicaPhotoSyncWorker` completes successfully (no "contact is deleted" errors).
> 5. Tail `log/dev.log | grep -E '\[AccountReset|Cleanup|JobCancellation\]'` — should show the structured per-step progress.

If the manual test surfaces an issue, file it as a follow-up — the spec's automated tests (regression + isolation) should have caught any structural breakage.

---

## Spec coverage check (skill-required self-review)

Each spec requirement → corresponding task:

| Spec requirement | Tasks |
|---|---|
| Wipe `imports` + `import_records` | Task 1 |
| Cancel in-flight Oban jobs (import_id + account_id scoped) | Task 2 |
| Wipe stored files (photos, documents, import uploads) | Task 3 |
| Wipe contacts (CASCADE) + tags | Task 4 |
| Wipe conversations (CASCADE → messages) | Task 5 |
| Wipe journal_entries | Task 6 |
| Wipe tasks | Task 7 |
| Wipe reminders + cancel their Oban jobs (CASCADE → rules, instances) | Task 8 |
| Wipe activities | Task 9 |
| Wipe audit_logs (last) | Task 10 |
| Worker becomes orchestrator; old helpers removed | Task 11 |
| Regression test for user-reported bug | Task 12 |
| Cross-account isolation test on worker | Task 12 |
| Every cleanup module has a "control account untouched" assertion | Tasks 1–10 |
| Idempotency assertion in every cleanup module | Tasks 1–10 |
| Order: jobs → files → contacts → imports → conversations → reminders → tasks → journal → activities → audit | Task 11 (`@cleaners` list) |
| `safe_delete_file/1` warn-and-continue (no raise on storage errors) | Task 3 |

All requirements covered.
