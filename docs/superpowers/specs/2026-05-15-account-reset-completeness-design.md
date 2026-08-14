# Account Reset Completeness

**Date:** 2026-05-15
**Status:** Approved
**Scope:** Personal CRM (`kith`)

## Context

On dev, a Monica re-import after an account reset failed photo sync. The Monica
photo sync worker (`Kith.Workers.MonicaPhotoSyncWorker`) reported "contact is
deleted" for photos whose `contact.id` matched contacts that should no longer
exist. Root cause: the current `Kith.Workers.AccountResetWorker` hard-deletes
contacts (via CASCADE) but does **not** delete the polymorphic mapping rows in
`import_records`, nor the parent `imports` rows. On re-import:

1. `MonicaApi.crawl/5` looks up `find_import_record(account, "monica_api", "contact", source_id)`
2. Finds a stale row from the prior import, pointing at a now-deleted `local_entity_id`
3. `handle_existing_contact` calls `Repo.get(Contacts.Contact, local_id)` → `nil` →
   the function falls through to `do_create_api_contact` which creates a new contact
   and inserts a second `import_record` for the same `(account_id, source, source_entity_type, source_entity_id)` tuple
4. The unique constraint on that tuple raises, OR the photo sync subsequently calls
   `Repo.one` against the same lookup and crashes on `Ecto.MultipleResultsError`

The bug surfaced as photo sync silently failing, but the underlying issue is
that the reset is incomplete in multiple dimensions, not just imports.

### Other tables left orphaned by the current reset

| Table | Today's behavior | Should be |
|---|---|---|
| `imports` | Untouched | Wiped |
| `import_records` | Untouched | Wiped |
| `conversations` | Untouched | Wiped (CASCADE → `messages`) |
| `journal_entries` | Untouched | Wiped |
| `tasks` | Untouched | Wiped |
| `reminders` (records) | Oban jobs cancelled; records remain | Wiped (CASCADE → `reminder_rules`, `reminder_instances`) |
| Reference data (genders, types) | Preserved | Preserved (no change) |
| `account_invitations` | Preserved | Preserved (no change) |

### In-flight Oban jobs are also a hazard

If a `MonicaApiCrawlWorker` or `MonicaPhotoSyncWorker` is running when reset
starts, it keeps inserting rows after the wipe. The current reset only cancels
reminder jobs (`cancel_reminder_jobs/1`). It must also cancel pending/scheduled
import-related jobs — but **only those belonging to the resetting account**, so
no other account's work is touched.

## Goals

1. After `AccountResetWorker` completes, no account-scoped data for the target
   account remains beyond reference data (genders, relationship_types,
   contact_field_types, etc.) and `account_invitations`.
2. A subsequent re-import (Monica API or vCard) for the same account succeeds
   without seeing stale `import_records` from prior runs.
3. The reset cancels all in-flight import-related Oban jobs for the target
   account before wiping data, eliminating the mid-flight write race.
4. Every cleanup operation is account-scoped. Running reset on account A does
   not affect any row, file, or Oban job belonging to account B.
5. The fix does not turn `AccountResetWorker` into a god-module. Each domain's
   cleanup lives next to that domain.

## Non-goals

- Preserving import history after reset. "Completely wipe" means the `imports`
  rows go too. The Oban job record (state, completed_at) is the audit trail.
- Reference data preservation changes. Genders, relationship_types, etc.
  continue to be preserved (current behavior).
- Hardening the photo sync worker against stale state as a belt-and-suspenders
  defense. With reset cancelling jobs and wiping `import_records`, the worker
  cannot see stale references. If a future bug bypasses reset, that's a
  separate fix.
- Multi-tenant data-isolation review across the rest of the codebase. This
  spec only addresses the reset path.

## Out of scope

- Soft-delete of accounts themselves (the `accounts` row stays).
- User accounts (`users` table). Reset clears data, not auth.
- Custom contact_field_types or other reference data the user has added —
  preserved per the recommendation in the brainstorming session.
- Adding a DB-level FK to `import_records.local_entity_id`. The polymorphic
  mapping pattern is intentional.

## Design

### Module decomposition

The worker becomes pure orchestration. Each domain's cleanup module lives in
that domain's namespace. No `@behaviour` ceremony — a function-naming
convention (`wipe_for_account/1` returning `:ok`) is sufficient for one
consumer.

```
lib/kith/
├── activities/cleanup.ex            # NEW   — wipe account-scoped activities
├── audit_logs/cleanup.ex            # NEW   — wipe audit_logs
├── contacts/cleanup.ex              # NEW   — hard-delete contacts (CASCADE) + tags
├── conversations/cleanup.ex         # NEW   — wipe conversations (CASCADE → messages)
├── imports/cleanup.ex               # NEW   — wipe imports + import_records
├── imports/job_cancellation.ex      # NEW   — cancel pending Oban jobs for THIS account's imports
├── journal/cleanup.ex               # NEW   — wipe journal_entries
├── reminders/cleanup.ex             # NEW   — cancel reminder Oban jobs + wipe reminders (CASCADE)
├── storage/account_cleanup.ex       # NEW   — delete photo + document + import-upload files
├── tasks/cleanup.ex                 # NEW   — wipe tasks
└── workers/account_reset_worker.ex  # REFACTOR — orchestrator only (~40 LoC)
```

(Note: `tags` is wiped inside `Contacts.Cleanup` because it shares the
contacts axis-of-change. `activities` is its own context and gets its own
module per SOLID-elixir's SRP-module guidance.)

Each cleanup module exposes a single function:

```elixir
defmodule Kith.Imports.Cleanup do
  @moduledoc "Wipes all import history for a single account."

  alias Kith.{Imports.Import, Imports.ImportRecord, Repo}
  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {records, _} = Repo.delete_all(from(r in ImportRecord, where: r.account_id == ^account_id))
    {imports, _} = Repo.delete_all(from(i in Import, where: i.account_id == ^account_id))
    Logger.info("[Imports.Cleanup] wiped #{records} records + #{imports} imports for account #{account_id}")
    :ok
  end
end
```

The worker:

```elixir
defmodule Kith.Workers.AccountResetWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:account_id]]

  require Logger

  alias Kith.{AuditLogs, Contacts, Conversations, Imports, Journal, Reminders, Storage, Tasks}

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
    Kith.AuditLogs.create_audit_log(account_id, %{
      user_id: nil,
      user_name: "system",
      event: "account_data_reset",
      metadata: %{reason: "Account data reset initiated"}
    })
  end
end
```

### Data flow & order-of-operations

The ordering is load-bearing:

1. **`Imports.JobCancellation`** — must run FIRST. Otherwise a running
   `MonicaApiCrawlWorker` keeps inserting rows after the wipe.
2. **`Storage.AccountCleanup`** — must run BEFORE `Contacts.Cleanup`. Contact
   CASCADE deletes the `photos` and `documents` rows; once those rows are gone,
   we can no longer iterate their `storage_key` values to delete files. Also
   sweeps `imports.file_storage_key` for uploaded vCards.
3. **`Contacts.Cleanup`** — hard-deletes contacts; CASCADE removes addresses,
   contact_fields, photos rows, documents rows, notes, debts, gifts, pets,
   emotions, relationships, calls, life_events, duplicate_candidates,
   immich_candidates.
4. **`Imports.Cleanup`** — wipes `import_records` then `imports`. Runs AFTER
   contacts so `local_entity_id` references are already dangling — we just
   sweep the whole table for this account, no coordination needed.
5. **`Conversations.Cleanup`** — wipes conversations; CASCADE removes messages.
6. **`Reminders.Cleanup`** — first cancels reminder Oban jobs (matching the
   existing pattern, scoped to this account), then deletes reminders; CASCADE
   removes reminder_rules, reminder_instances.
7. **`Tasks.Cleanup`** — wipes tasks.
8. **`Journal.Cleanup`** — wipes journal_entries.
9. **`Activities.Cleanup`** — wipes account-scoped `activities` (no contact FK).
   (Note: `tags` is wiped inside `Contacts.Cleanup` at step 3.)
10. **`AuditLogs.Cleanup`** — runs LAST. The "account_data_reset" audit log
    written at start needs to live until the reset completes; wiping it earlier
    would erase the audit trail of the reset itself.

### Account-scoped Oban job cancellation

`Kith.Imports.JobCancellation.wipe_for_account/1` cancels jobs by querying
`Oban.Job` directly with account-scoped filters:

```elixir
defmodule Kith.Imports.JobCancellation do
  @moduledoc """
  Cancels all pending/scheduled Oban jobs for a single account's imports.
  Scoping rule: only this account's import_ids and account_id are matched.
  No other account's jobs are touched.
  """

  alias Kith.{Imports.Import, Repo}
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

Two key properties:
- **Account-scoped**: every WHERE clause filters by `account_id` (directly or
  transitively via `import_id IN account's imports`).
- **State filter**: only jobs in cancellable states are touched. Completed and
  cancelled jobs are left alone.

### Error handling

- Each cleanup module returns `:ok` on success, raises on unexpected failure.
- The worker's `Enum.each` propagates the raise. Oban catches, marks the job
  `:retryable`, and retries per backoff (`max_attempts: 3`).
- After 3 attempts, the job moves to `:discarded`. The Oban Web dashboard
  surfaces this to admins. The audit log written at the start is still present
  (since `AuditLogs.Cleanup` is last) → user/admin can see the reset was
  attempted.
- Bulk deletes are NOT wrapped in `Ecto.Multi`. Each `Repo.delete_all` is its
  own transaction; large accounts don't fight for a single long-held lock.
- Cleanup operations are inherently idempotent (deleting from an empty table
  succeeds with `{0, nil}`). Retries are safe.

### Storage delete: the one warn-and-continue path

Storage operations can fail benignly (S3 already deleted, network blip). The
existing pattern is preserved:

```elixir
defp safe_delete_file(nil), do: :ok

defp safe_delete_file(key) do
  case Kith.Storage.delete(key) do
    :ok -> :ok

    {:error, reason} ->
      Logger.warning("[Storage.AccountCleanup] failed to delete #{key}: #{inspect(reason)}")
      :ok
  end
end
```

This is `:ok` because storage objects are recoverable separately (S3 lifecycle,
manual sweep) and don't affect data integrity.

### Observability

Logger metadata: every cleanup logs with `account_id` and `worker` in
`Logger.metadata`, plus a `[Module.Name]` prefix in the message body. Sample:

```
[AccountReset] starting reset for account 42
[AccountReset] running Kith.Imports.JobCancellation
[Imports.JobCancellation] cancelled 3 import job(s) + 1 account-scoped job(s) for account 42
[AccountReset] running Kith.Storage.AccountCleanup
[Storage.AccountCleanup] deleted 47 photo files + 12 document files + 2 import uploads for account 42
[AccountReset] running Kith.Contacts.Cleanup
[Contacts.Cleanup] hard-deleted 423 contacts (CASCADE) for account 42
...
[AccountReset] completed reset for account 42
```

The structured `account_id` metadata reaches log search and Sentry as a tag,
not just a substring in the message.

## Testing

### Per-module unit tests

Every Cleanup module gets `test/kith/<context>/cleanup_test.exs` with the same
shape:

- Fixture data for the target account AND a control account
- Call `wipe_for_account(target_account_id)`
- Assert: target rows are zero; control rows are unchanged

The **control-account untouched assertion is mandatory** in every test — it's
the contract that protects against cross-account leakage.

### `Imports.JobCancellation` test

Uses `Oban.Testing`. Inserts pending jobs for both accounts (matching all four
`@import_workers` plus `DuplicateDetectionWorker`). After
`wipe_for_account(target)`:

- Target's jobs: state `"cancelled"`
- Other account's jobs: state `"available"` (unchanged)
- Completed jobs (state `"completed"`) for the target: also unchanged (we only
  cancel still-cancellable states)

### Regression test for the user-reported bug

`test/kith/workers/account_reset_worker_test.exs` gets the actual scenario
that broke on dev:

```elixir
test "re-import after reset can sync photos without finding stale import_records", ctx do
  # Initial import: creates contact + import_record for Monica id 964
  import_a = import_fixture(ctx.account, ctx.user_id, %{source: "monica_api"})
  contact_a = contact_fixture(ctx.account)
  {:ok, _} = Imports.record_imported_entity(import_a, "contact", "964", "contact", contact_a.id)

  # Full reset
  assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.account})

  # Target account fully wiped
  assert count_for(Contacts.Contact, ctx.account) == 0
  assert count_for(Imports.Import, ctx.account) == 0
  assert count_for(Imports.ImportRecord, ctx.account) == 0

  # Re-import: new contact + new import_record for the same Monica id 964
  import_b = import_fixture(ctx.account, ctx.user_id, %{source: "monica_api"})
  contact_b = contact_fixture(ctx.account)
  {:ok, _} = Imports.record_imported_entity(import_b, "contact", "964", "contact", contact_b.id)

  # The photo sync lookup that previously found stale data now resolves to the new contact
  assert %{local_entity_id: local_id} =
           Imports.find_import_record(ctx.account, "monica_api", "contact", "964")

  assert local_id == contact_b.id
end
```

### Cross-account isolation test on the worker

Snapshot-based: populate two accounts with data across every wiped domain,
reset one, assert the other's snapshot is bit-identical.

```elixir
defp data_snapshot(account_id) do
  %{
    contacts: count_for(Contacts.Contact, account_id),
    imports: count_for(Imports.Import, account_id),
    import_records: count_for(Imports.ImportRecord, account_id),
    conversations: count_for(Conversations.Conversation, account_id),
    tasks: count_for(Tasks.Task, account_id),
    journal_entries: count_for(Journal.Entry, account_id),
    reminders: count_for(Reminders.Reminder, account_id),
    tags: count_for(Contacts.Tag, account_id),
    activities: count_for(Activities.Activity, account_id),
    audit_logs: count_for(AuditLogs.AuditLog, account_id)
  }
end
```

Every new domain we wipe in the future adds one line to `data_snapshot/1` —
forgetting will cause the isolation test to fail loudly.

### Idempotency tests

Every Cleanup module: call `wipe_for_account/1` twice in a row; assert second
call returns `:ok` with zero counts (or whatever the second-call shape is).
Cheap, catches any assumption that the table has data.

### What's NOT tested

- Oban retry semantics — rely on the library's own coverage.
- Storage backend internals — `Kith.Storage.Local` and `Kith.Storage.S3` have
  their own tests; `safe_delete_file/1`'s warn-on-error path is small enough
  to verify by reading.

## Migration / backwards compatibility

No DB migrations required. All changes are at the Elixir module layer.

Existing accounts in any state work with the new worker — including accounts
that already have orphaned `import_records` from prior resets. The next reset
will sweep them.

## Files changed

| File | Change |
|---|---|
| `lib/kith/activities/cleanup.ex` | NEW |
| `lib/kith/audit_logs/cleanup.ex` | NEW |
| `lib/kith/contacts/cleanup.ex` | NEW (handles contacts + tags) |
| `lib/kith/conversations/cleanup.ex` | NEW |
| `lib/kith/imports/cleanup.ex` | NEW |
| `lib/kith/imports/job_cancellation.ex` | NEW |
| `lib/kith/journal/cleanup.ex` | NEW |
| `lib/kith/reminders/cleanup.ex` | NEW |
| `lib/kith/storage/account_cleanup.ex` | NEW |
| `lib/kith/tasks/cleanup.ex` | NEW |
| `lib/kith/workers/account_reset_worker.ex` | REFACTOR — orchestrator only |
| `test/kith/activities/cleanup_test.exs` | NEW |
| `test/kith/audit_logs/cleanup_test.exs` | NEW |
| `test/kith/contacts/cleanup_test.exs` | NEW |
| `test/kith/conversations/cleanup_test.exs` | NEW |
| `test/kith/imports/cleanup_test.exs` | NEW |
| `test/kith/imports/job_cancellation_test.exs` | NEW |
| `test/kith/journal/cleanup_test.exs` | NEW |
| `test/kith/reminders/cleanup_test.exs` | NEW |
| `test/kith/storage/account_cleanup_test.exs` | NEW |
| `test/kith/tasks/cleanup_test.exs` | NEW |
| `test/kith/workers/account_reset_worker_test.exs` | EXTEND — add regression + isolation tests |

## Verification

1. `mix test` — 0 failures.
2. `mix quality` — clean (format + credo + sobelow + dialyzer).
3. Manual on dev: import Monica account, trigger reset via Settings → Account,
   re-import the same Monica account, confirm photo sync now succeeds.
4. `tail -f log/dev.log | grep '\[AccountReset\|Cleanup\|JobCancellation\]'`
   shows the structured per-step progress.

## References

- SOLID for Elixir standards: `07-Documentation/Standards/solid-principles-elixir.md`
  (vault). Specifically §SRP-module ("god module" anti-pattern) and §OCP-decision-tree
  for the function-naming-convention vs. behaviour trade-off.
- The bug surfaced in Monica re-import photo sync; root cause is the
  `import_records.local_entity_id` polymorphic mapping with no DB-level FK.
