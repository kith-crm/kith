# Monica 4.1.2 Reminder Import Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Parallel execution:** tasks are grouped into lanes (A-core, A-import, A-ui). Lanes run as separate agents in separate worktrees, in the waves defined by [the orchestration plan](2026-10-15-pr44-followups-orchestration.md). Read it first.

**Goal:** Import Monica 4.1.2 reminders faithfully (no duplicate birthdays, original dates and intervals kept, past one-time reminders inactive, stay-in-touch and descriptions imported), and add the Kith features that requires: a `day` interval unit, a reminder `description`, an opt-in derived `first_met` reminder, a custom-interval form control, and the 29 February crash fix.

**Architecture:** A pure `Kith.Imports.Monica.ReminderMapper` turns one Monica reminder plus the Kith contact into a decision; `MonicaMiscDataWorker` only carries the decision out. Derived reminders (`birthday`, `first_met`) share one sync path in `Kith.Reminders`. Kith's own schedule maths (`Occurrences`) computes every next date; nothing copies Monica's scheduler.

**Tech Stack:** Elixir 1.19.5 / OTP 28.5 (mise), Phoenix LiveView 1.1, Ecto/PostgreSQL, Oban, Req.Test stubs, Playwright (`test/playwright`).

**Spec:** [`docs/superpowers/specs/2026-10-14-monica-reminder-import-design.md`](../specs/2026-10-14-monica-reminder-import-design.md). Rule ids (R1–R6), decisions (D1–D10) and facts (M1–M13) below refer to it.

## Global Constraints

- Toolchain: plain `mix` resolves to the mise Elixir 1.19.5 / OTP 28.5; the winget 1.18.4 must not be used. Check with `mix --version`.
- Tests run on the host against a Postgres you own: `DB_PORT=<port> MIX_TEST_PARTITION=<lane> mix test`. In every command below, `$DB_PORT` and `$LANE` are your lane's values from the orchestration plan's table (e.g. `export DB_PORT=5444 LANE=_acore`). `config/test.exs` hard-codes `hostname: "localhost"`, so tests can't run inside the dev container.
- `mix test` must show 0 failures before **every** commit (CLAUDE.md). Run `mix format` and `mix credo --strict` too; the husky pre-commit hook does not run in worktrees.
- Any test that calls `Application.put_env` must be `async: false`.
- No `Co-Authored-By`, `Claude-Session` or other assistant-attribution trailers in commits.
- Never force-push. Never write to the main checkout `C:/Users/ME/projects/kith`.
- New reminder type string: `"first_met"`. New interval unit string: `"day"`. New contact field: `first_met_reminder` (boolean). New reminder field: `description` (text).
- First-met email subject, verbatim: `Anniversary of meeting {name}`. API 422 detail, verbatim: `First-met reminders are managed from the contact's first-met date.`
- "Today" for any import or schedule decision is the account's local date: `Kith.Reminders.account_today(account_id)` (made public in Task A1).

## Review Focus

1. **A Monica birthday whose month-day is 29 Feb, matched against a Kith contact born 29 Feb** — must map to the birthday reminder, not create a generic one. Pinned in Task A6 (fixture id 2).
2. **Re-importing after the user deleted the mapped Kith reminder** — the import record points at a missing row; the importer must create a fresh row and re-point the mapping, not crash. Pinned in Task A7.
3. **A Monica reminder whose `initial_date` is the import day** — must import as due today, active (D6), not inactive. Pinned in Task A6 (fixture id 17, `today = ~D[2026-10-14]`).
4. **Unchecking "Remind me every year" in the About form** — the checkbox must send `false` (hidden input) so the reminder is deleted, not left behind. Pinned in Task A10.
5. **Saving the reminder form with "Custom…" and a non-numeric or zero count** — must keep the form open with an error flash, not crash or save a broken interval. Pinned in Task A9.

---

## Lane A-core (wave 1)

### Task A1: `day` unit, `description`, `first_met` type — schema and maths

**Files:**
- Create: `priv/repo/migrations/20261015120000_reminder_import_rework.exs`
- Modify: `lib/kith/reminders/occurrences.ex`
- Modify: `lib/kith/reminders/reminder.ex`
- Modify: `lib/kith/reminders.ex` (make `account_today/1` public)
- Test: `test/kith/reminders/occurrences_test.exs`, `test/kith/reminders_test.exs`

**Interfaces:**
- Produces: `Reminder.types/0` includes `"first_met"`; `Reminder.units/0` includes `"day"`; `Reminder` has `field :description, :string` cast by `create_changeset/3` and `update_changeset/3`; `Reminder.interval_label/1` returns `"Daily"` / `"Every N days"`; `Occurrences.nth/2`, `next_on_or_after/2`, `advance_after/2` handle `"day"`; `Kith.Reminders.account_today(account_id) :: Date.t()`; DB columns `reminders.description`, `contacts.first_met_reminder`; index `reminders_first_met_unique_idx`.

- [ ] **Step 1: Write the failing Occurrences tests**

Add to `test/kith/reminders/occurrences_test.exs` inside `describe "next_on_or_after/2"`:

```elixir
    test "day intervals count whole days from the anchor" do
      assert Occurrences.next_on_or_after(s(~D[2026-10-28], "day", 14), ~D[2026-10-14]) ==
               ~D[2026-10-28]

      assert Occurrences.next_on_or_after(s(~D[2026-01-01], "day", 10), ~D[2026-01-15]) ==
               ~D[2026-01-21]

      assert Occurrences.next_on_or_after(s(~D[2026-01-01], "day", 1), ~D[2026-03-01]) ==
               ~D[2026-03-01]
    end

    test "advance_after/2 with a day interval moves strictly past the date" do
      assert Occurrences.advance_after(s(~D[2026-01-01], "day", 10), ~D[2026-01-21]) ==
               ~D[2026-01-31]
    end
```

- [ ] **Step 2: Write the failing Reminder changeset tests**

Add to `test/kith/reminders_test.exs` (it already has `account_id`, a contact and a user in its setup; reuse them — check the setup block names before pasting and rename `ctx.*` accordingly):

```elixir
  describe "day interval and description" do
    test "a recurring reminder accepts a day interval and stores a description", ctx do
      {:ok, r} =
        Kith.Reminders.create_reminder(ctx.account_id, ctx.user.id, %{
          "type" => "recurring",
          "title" => "Water plants",
          "anchor_date" => ~D[2026-01-01],
          "interval_unit" => "day",
          "interval_count" => 10,
          "description" => "The ferns too",
          "contact_id" => ctx.contact.id
        })

      assert r.interval_unit == "day"
      assert r.description == "The ferns too"
      assert Kith.Reminders.Reminder.interval_label(r) == "Every 10 days"
    end

    test "interval_label/1 says Daily for one day" do
      assert Kith.Reminders.Reminder.interval_label(%{interval_unit: "day", interval_count: 1}) ==
               "Daily"
    end

    test "first_met is a valid type" do
      assert "first_met" in Kith.Reminders.Reminder.types()
    end

    test "update_changeset casts description", ctx do
      {:ok, r} =
        Kith.Reminders.create_reminder(ctx.account_id, ctx.user.id, %{
          "type" => "one_time",
          "title" => "X",
          "anchor_date" => Date.add(Date.utc_today(), 3),
          "contact_id" => ctx.contact.id
        })

      {:ok, r} = Kith.Reminders.update_reminder(r, %{"description" => "Bring the cake"})
      assert r.description == "Bring the cake"
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/occurrences_test.exs test/kith/reminders_test.exs`
Expected: FAIL (`FunctionClauseError` in `Occurrences.nth/2` for `"day"`; `unknown field :description`).

- [ ] **Step 4: Write the migration**

`priv/repo/migrations/20261015120000_reminder_import_rework.exs`:

```elixir
defmodule Kith.Repo.Migrations.ReminderImportRework do
  use Ecto.Migration

  def up do
    alter table(:reminders) do
      add :description, :text
    end

    drop constraint(:reminders, :reminders_interval_unit_values)

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('day', 'week', 'month', 'year') OR interval_unit IS NULL"
           )

    alter table(:contacts) do
      add :first_met_reminder, :boolean, null: false, default: false
    end

    create unique_index(:reminders, [:contact_id],
             where: "type = 'first_met'",
             name: :reminders_first_met_unique_idx
           )
  end

  def down do
    drop index(:reminders, [:contact_id], name: :reminders_first_met_unique_idx)

    alter table(:contacts) do
      remove :first_met_reminder
    end

    # Day-interval rows cannot satisfy the old constraint.
    execute "DELETE FROM reminders WHERE interval_unit = 'day'"
    drop constraint(:reminders, :reminders_interval_unit_values)

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('week', 'month', 'year') OR interval_unit IS NULL"
           )

    alter table(:reminders) do
      remove :description
    end
  end
end
```

- [ ] **Step 5: Add the `day` clauses to `Occurrences`**

In `lib/kith/reminders/occurrences.ex`, add before the `"week"` clause of `nth/2`:

```elixir
  def nth(%{anchor_date: anchor, interval_unit: "day", interval_count: count}, n),
    do: Date.add(anchor, count * n)
```

and before the `"week"` clause of `lower_bound_index/2`:

```elixir
  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "day", interval_count: c}, date),
    do: div(Date.diff(date, anchor), c)
```

- [ ] **Step 6: Update `Reminder`**

In `lib/kith/reminders/reminder.ex`:
- Change `@types ~w(birthday stay_in_touch one_time recurring)` to `@types ~w(birthday first_met stay_in_touch one_time recurring)`.
- Change `@units ~w(week month year)` to `@units ~w(day week month year)`.
- Add `field :description, :string` after `field :title, :string`.
- Add `:description` to the `cast/3` list in both `create_changeset/3` and `update_changeset/3`.
- Add `|> unique_constraint(:contact_id, name: :reminders_first_met_unique_idx)` after the existing birthday `unique_constraint` in `create_changeset/3`.
- Add a clause above `interval_label(%{interval_unit: "week", interval_count: 1})`:

```elixir
  def interval_label(%{interval_unit: "day", interval_count: 1}), do: "Daily"
```

- Update the moduledoc type list with: `` - `first_met` — derived from the contact's first-met date when the contact opts in (`Kith.Reminders.sync_first_met/1`) ``.

- [ ] **Step 7: Make `account_today/1` public**

In `lib/kith/reminders.ex`, replace `defp account_today(account_id) do` with:

```elixir
  @doc "Today's date in the account's timezone."
  @spec account_today(integer()) :: Date.t()
  def account_today(account_id) do
```

- [ ] **Step 8: Migrate and run the tests**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/occurrences_test.exs test/kith/reminders_test.exs`
Expected: PASS (`mix test` migrates the test DB itself).

- [ ] **Step 9: Full suite, format, credo, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add priv/repo/migrations/20261015120000_reminder_import_rework.exs lib/kith/reminders/occurrences.ex lib/kith/reminders/reminder.ex lib/kith/reminders.ex test/kith/reminders/occurrences_test.exs test/kith/reminders_test.exs
git commit -m "feat(reminders): day interval unit, reminder description, first_met type"
```

### Task A2: Opt-in derived `first_met` reminder

**Files:**
- Modify: `lib/kith/contacts/contact.ex`
- Modify: `lib/kith/reminders.ex`
- Modify: `lib/kith/contacts.ex:285-316`
- Test: `test/kith/reminders/first_met_sync_test.exs` (create)

**Interfaces:**
- Consumes: Task A1 (`first_met` type, `contacts.first_met_reminder` column, unique index).
- Produces: `Contact` field `first_met_reminder :: boolean` (cast in create/update changesets); `Kith.Reminders.sync_first_met(%Contact{}) :: {:ok, %Reminder{} | :none} | {:error, term}`; `Kith.Reminders.get_first_met_reminder(contact_id, account_id) :: %Reminder{} | nil`. `create_contact/2` and `update_contact/2` call `sync_first_met/1` whenever `first_met_at` or `first_met_reminder` changes.

- [ ] **Step 1: Write the failing tests**

`test/kith/reminders/first_met_sync_test.exs`:

```elixir
defmodule Kith.Reminders.FirstMetSyncTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Reminders}

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  test "no reminder unless the contact opts in", ctx do
    contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
  end

  test "opting in creates a yearly first_met reminder owned by the account owner", ctx do
    contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})
    {:ok, contact} = Contacts.update_contact(contact, %{first_met_reminder: true})

    r = Reminders.get_first_met_reminder(contact.id, ctx.account_id)

    assert %{type: "first_met", anchor_date: ~D[2012-09-01], interval_unit: "year",
             interval_count: 1, title: nil} = r

    assert r.creator_id == ctx.user.id
  end

  test "creating a contact already opted in creates the reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    assert %{type: "first_met"} = Reminders.get_first_met_reminder(contact.id, ctx.account_id)
  end

  test "changing the first-met date re-anchors the same reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    before = Reminders.get_first_met_reminder(contact.id, ctx.account_id)
    {:ok, contact} = Contacts.update_contact(contact, %{first_met_at: ~D[2013-03-03]})
    after_change = Reminders.get_first_met_reminder(contact.id, ctx.account_id)

    assert after_change.id == before.id
    assert after_change.anchor_date == ~D[2013-03-03]
  end

  test "opting out deletes the reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, contact} = Contacts.update_contact(contact, %{first_met_reminder: false})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
  end

  test "clearing the first-met date deletes the reminder but keeps the opt-in", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, contact} = Contacts.update_contact(contact, %{first_met_at: nil})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
    assert contact.first_met_reminder
  end

  test "sync_first_met/1 is idempotent", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, r1} = Reminders.sync_first_met(contact)
    {:ok, r2} = Reminders.sync_first_met(contact)
    assert r1.id == r2.id
  end

  test "birthday sync still works after the shared refactor", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})
    assert %{type: "birthday"} = Reminders.get_birthday_reminder(contact.id, ctx.account_id)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/first_met_sync_test.exs`
Expected: FAIL (`unknown field :first_met_reminder`, `undefined function get_first_met_reminder/2`).

- [ ] **Step 3: Add the contact field**

In `lib/kith/contacts/contact.ex`, add `field :first_met_reminder, :boolean, default: false` after `field :first_met_additional_info, :string`, and add `:first_met_reminder` to both `cast/3` lists (after `:first_met_additional_info`).

- [ ] **Step 4: Share the derived-reminder sync in `Kith.Reminders`**

Replace `sync_birthday/1` and `get_birthday_reminder/2` in `lib/kith/reminders.ex` (lines 81–137) with:

```elixir
  # ── Derived Reminders (birthday, first_met) ─────────────────────────────

  @doc """
  Makes the contact's birthday reminder match its birthdate: creates it when a
  birthdate is set, re-anchors it when the birthdate changes, deletes it when
  the birthdate is removed. The reminder belongs to the account owner (design
  spec §6). An existing reminder's `active` flag is left as it is.
  """
  def sync_birthday(%Kith.Contacts.Contact{} = contact),
    do: sync_derived(contact, "birthday", contact.birthdate)

  @doc """
  Makes the contact's first-met anniversary reminder match its first-met date,
  when the contact has opted in (`first_met_reminder`). Same rules as
  `sync_birthday/1`; opting out or clearing the date deletes the reminder.
  """
  def sync_first_met(%Kith.Contacts.Contact{} = contact) do
    date = if contact.first_met_reminder, do: contact.first_met_at
    sync_derived(contact, "first_met", date)
  end

  defp sync_derived(contact, type, date) do
    case {date, get_derived_reminder(contact.id, contact.account_id, type)} do
      {nil, nil} ->
        {:ok, :none}

      {nil, %Reminder{} = reminder} ->
        with {:ok, _} <- delete_reminder(reminder), do: {:ok, :none}

      {%Date{} = date, nil} ->
        case account_owner_id(contact.account_id) do
          nil ->
            {:error, :no_account_owner}

          owner_id ->
            create_reminder(contact.account_id, owner_id, %{
              type: type,
              title: nil,
              anchor_date: date,
              interval_unit: "year",
              interval_count: 1,
              contact_id: contact.id
            })
        end

      {%Date{} = date, %Reminder{} = reminder} ->
        update_reminder(reminder, %{anchor_date: date})
    end
  end

  # The account's owner: its earliest admin user (today, the only user).
  defp account_owner_id(account_id) do
    from(u in Kith.Accounts.User,
      where: u.account_id == ^account_id and u.role == "admin",
      order_by: [asc: u.inserted_at, asc: u.id],
      select: u.id,
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Returns the birthday reminder for a contact, or nil."
  def get_birthday_reminder(contact_id, account_id),
    do: get_derived_reminder(contact_id, account_id, "birthday")

  @doc "Returns the first-met anniversary reminder for a contact, or nil."
  def get_first_met_reminder(contact_id, account_id),
    do: get_derived_reminder(contact_id, account_id, "first_met")

  defp get_derived_reminder(contact_id, account_id, type) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id and r.type == ^type)
    |> Repo.one()
  end
```

- [ ] **Step 5: Call both syncs from `Contacts`**

Replace `lib/kith/contacts.ex` lines 285–316 (`create_contact/2` through the fallback `sync_birthday_if_changed/2` clause) with:

```elixir
  def create_contact(account_id, attrs) do
    %Contact{account_id: account_id}
    |> Contact.create_changeset(attrs)
    |> Repo.insert()
    |> sync_derived_reminders(%Contact{})
  end

  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.update_changeset(attrs)
    |> Repo.update()
    |> sync_derived_reminders(contact)
  end

  # Every path that sets or clears a birthdate or first-met date (UI, REST API,
  # CardDAV, the Monica importer) goes through create_contact/2 or
  # update_contact/2. `old` is the contact before the write (`%Contact{}` on
  # create, whose dates are nil and whose opt-in is false).
  defp sync_derived_reminders({:ok, %Contact{} = new} = result, %Contact{} = old) do
    if new.birthdate != old.birthdate,
      do: log_sync_failure(:birthday, new, Kith.Reminders.sync_birthday(new))

    if {new.first_met_at, new.first_met_reminder} != {old.first_met_at, old.first_met_reminder},
      do: log_sync_failure(:first_met, new, Kith.Reminders.sync_first_met(new))

    result
  end

  defp sync_derived_reminders(result, _old), do: result

  defp log_sync_failure(_kind, _contact, {:ok, _}), do: :ok

  defp log_sync_failure(kind, contact, {:error, reason}) do
    Logger.warning(
      "[Contacts] #{kind} reminder sync failed for contact #{contact.id}: #{inspect(reason)}"
    )
  end
```

- [ ] **Step 6: Run the tests**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/ test/kith/contacts_test.exs`
Expected: PASS (existing `birthday_sync_test.exs` must stay green).

- [ ] **Step 7: Full suite, format, credo, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/contacts/contact.ex lib/kith/reminders.ex lib/kith/contacts.ex test/kith/reminders/first_met_sync_test.exs
git commit -m "feat(reminders): opt-in first-met anniversary reminder derived from the contact"
```

### Task A3: Merge keeps one first-met reminder

**Files:**
- Modify: `lib/kith/contacts/merge.ex:205-207` (Multi) and add a step after `remap_birthday_reminders_step/4`
- Test: `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: Task A2 (`sync_first_met/1`, `first_met_reminder`, `reminders_first_met_unique_idx`).
- Produces: after a merge, the survivor has `first_met_reminder == true` if any merged contact had it, and at most one `first_met` reminder, anchored on the survivor's merged `first_met_at`.

- [ ] **Step 1: Write the failing test**

Look at the top of `test/kith/contacts_merge_test.exs` for the helper that performs a merge (it calls `Kith.Contacts.Merge` with a scope and a resolution) and reuse it. Add:

```elixir
  describe "first-met reminders" do
    test "two opted-in contacts merge into one first_met reminder", ctx do
      a = contact_fixture(ctx.account_id, %{first_name: "A", first_met_at: ~D[2012-09-01], first_met_reminder: true})
      b = contact_fixture(ctx.account_id, %{first_name: "A", first_met_at: ~D[2014-02-02], first_met_reminder: true})

      survivor = merge!(ctx, a, [b])

      assert [r] =
               Repo.all(from r in Kith.Reminders.Reminder,
                 where: r.type == "first_met" and r.contact_id == ^survivor.id)

      assert r.anchor_date == survivor.first_met_at
    end

    test "the survivor opts in when only a merged-away contact had opted in", ctx do
      a = contact_fixture(ctx.account_id, %{first_name: "A", first_met_at: ~D[2012-09-01]})
      b = contact_fixture(ctx.account_id, %{first_name: "A", first_met_at: ~D[2012-09-01], first_met_reminder: true})

      survivor = merge!(ctx, a, [b])

      assert Repo.get!(Kith.Contacts.Contact, survivor.id).first_met_reminder
      assert Kith.Reminders.get_first_met_reminder(survivor.id, ctx.account_id)
    end
  end
```

(If the file's merge helper has a different name or arity, use it and keep the assertions.)

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/contacts_merge_test.exs`
Expected: FAIL — the first test raises `Ecto.ConstraintError` on `reminders_first_met_unique_idx` during `:remap_owned`; the second finds `first_met_reminder == false`.

- [ ] **Step 3: Add the Multi step**

In `lib/kith/contacts/merge.ex`, after the `:remap_birthday_reminders` step (line 205–207), add:

```elixir
    |> Multi.run(:remap_first_met_reminders, fn repo, %{survivor: survivor} ->
      remap_first_met_reminders_step(repo, survivor, loser_ids)
    end)
```

and after `remap_birthday_reminders_step/4` add:

```elixir
  # Same collision as birthdays (`reminders_first_met_unique_idx`), plus the
  # opt-in flag: the survivor keeps the anniversary reminder if any merged
  # contact had asked for one. The kept row is then synced to the merged
  # first-met date via Reminders.sync_first_met/1.
  defp remap_first_met_reminders_step(repo, survivor, loser_ids) do
    all_ids = [survivor.id | loser_ids]

    %{rows: rows} =
      repo.query!(
        "SELECT id, contact_id FROM reminders WHERE type = 'first_met' AND contact_id = ANY($1)",
        [all_ids]
      )

    if rows != [] do
      keep_id = reminder_keep_id(rows, survivor.id)
      delete_ids = for [id, _contact_id] <- rows, id != keep_id, do: id

      if delete_ids != [],
        do: repo.query!("DELETE FROM reminders WHERE id = ANY($1)", [delete_ids])

      repo.update_all(from(r in Kith.Reminders.Reminder, where: r.id == ^keep_id),
        set: [contact_id: survivor.id]
      )
    end

    opted_in? =
      repo.exists?(from c in Contact, where: c.id in ^all_ids and c.first_met_reminder == true)

    survivor =
      if opted_in? and not survivor.first_met_reminder,
        do: survivor |> Ecto.Changeset.change(first_met_reminder: true) |> repo.update!(),
        else: survivor

    case Kith.Reminders.sync_first_met(survivor) do
      {:ok, _} -> {:ok, :done}
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 4: Run the tests, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/contacts_merge_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/contacts/merge.ex test/kith/contacts_merge_test.exs
git commit -m "fix(merge): keep one first-met reminder and carry the opt-in to the survivor"
```

### Task A4: Dispatcher and email for `first_met` and `description`

**Files:**
- Modify: `lib/kith/reminders/dispatcher.ex:30`
- Modify: `lib/kith/workers/reminder_email_worker.ex:69-94`
- Test: `test/kith/reminders/dispatcher_test.exs`, `test/kith/workers/reminder_email_worker_test.exs`

**Interfaces:**
- Consumes: Task A1.
- Produces: `first_met` reminders send on the day only and advance one year; email subject `Anniversary of meeting {name}`; any reminder's `description` is appended to the email body.

- [ ] **Step 1: Write the failing dispatcher test**

Add to `test/kith/reminders/dispatcher_test.exs`:

```elixir
  test "a first-met anniversary sends on the day only and advances a year", ctx do
    r =
      create!(ctx, %{
        type: "first_met",
        title: nil,
        interval_unit: "year",
        interval_count: 1,
        anchor_date: Date.shift(ctx.today, year: -5)
      })

    set_next!(r, Date.add(ctx.today, 5))
    assert :ok = Dispatcher.run(ctx.after_send)
    assert instances(r) == []

    set_next!(r, ctx.today)
    assert :ok = Dispatcher.run(ctx.after_send)
    assert [%{kind: "on_day", days_before: 0}] = instances(r)

    assert Repo.get!(Reminder, r.id).next_reminder_date ==
             Kith.Reminders.Occurrences.advance_after(Reminder.schedule(r), ctx.today)
  end
```

- [ ] **Step 2: Write the failing email tests**

Add to `test/kith/workers/reminder_email_worker_test.exs`:

```elixir
  describe "subjects and bodies" do
    defp fire!(user, contact, attrs) do
      {:ok, r} =
        Reminders.create_reminder(
          user.account_id,
          user.id,
          Map.merge(%{anchor_date: Date.utc_today(), contact_id: contact.id}, attrs)
        )

      :ok = Dispatcher.run(DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"))
      [i] = Repo.all(from i in ReminderInstance, where: i.reminder_id == ^r.id)
      perform_job(ReminderEmailWorker, %{instance_id: i.id})
    end

    test "a first-met anniversary has its own subject", %{user: user, contact: contact} do
      fire!(user, contact, %{type: "first_met", title: nil, interval_unit: "year", interval_count: 1})
      assert_email_sent(subject: "Anniversary of meeting Mona Vale")
    end

    test "the description is included in the body", %{user: user, contact: contact} do
      fire!(user, contact, %{type: "one_time", title: "Party", description: "Bring the cake"})
      assert_email_sent(fn email -> email.text_body =~ "Bring the cake" end)
    end
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/dispatcher_test.exs test/kith/workers/reminder_email_worker_test.exs`
Expected: FAIL (the first-met reminder does not advance; subject is `Reminder: Untitled`; body lacks the description).

- [ ] **Step 4: Implement**

In `lib/kith/reminders/dispatcher.ex` change line 30 to:

```elixir
  @advancing_types ~w(birthday first_met recurring)
```

(`@advance_types` stays `~w(birthday one_time)` — D8.)

In `lib/kith/workers/reminder_email_worker.ex`, change the body line in `build_email/2`:

```elixir
    |> Swoosh.Email.text_body(body(subject, name, reminder.description))
```

and add, above the `subject/5` clauses:

```elixir
  defp body(subject, name, nil), do: "#{subject}\n\nContact: #{name}"
  defp body(subject, name, ""), do: body(subject, name, nil)
  defp body(subject, name, description), do: "#{subject}\n\n#{description}\n\nContact: #{name}"
```

and a subject clause above the `"stay_in_touch"` one:

```elixir
  defp subject("first_met", _kind, _days, name, _title), do: "Anniversary of meeting #{name}"
```

- [ ] **Step 5: Run the tests, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders/dispatcher_test.exs test/kith/workers/reminder_email_worker_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/reminders/dispatcher.ex lib/kith/workers/reminder_email_worker.ex test/kith/reminders/dispatcher_test.exs test/kith/workers/reminder_email_worker_test.exs
git commit -m "feat(reminders): send first-met anniversaries and include descriptions in emails"
```

### Task A5: REST API

**Files:**
- Modify: `lib/kith_web/controllers/api/reminder_controller.ex:78,112,131,203-207,217-231`
- Modify: `lib/kith_web/controllers/api/contact_json.ex` (`data/1`, `reminder/1`)
- Test: `test/kith_web/controllers/api/reminder_controller_test.exs`, `test/kith_web/controllers/api/contact_controller_test.exs`

**Interfaces:**
- Consumes: Tasks A1, A2.
- Produces: 422 for create/update/delete of `first_met`; `description` in reminder JSON (both controllers); `first_met_reminder` in contact JSON; `interval_unit: "day"` accepted.

- [ ] **Step 1: Write the failing tests**

Follow the existing birthday 422 tests in `reminder_controller_test.exs` (search for `"Birthday reminders are managed"`) and add the same three for `first_met`:

```elixir
  describe "first_met reminders are read-only" do
    setup ctx do
      {:ok, contact} =
        Kith.Contacts.update_contact(ctx.contact, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

      %{first_met: Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)}
    end

    test "create is rejected", ctx do
      conn = post(ctx.conn, ~p"/api/contacts/#{ctx.contact.id}/reminders", %{"reminder" => %{"type" => "first_met", "anchor_date" => "2012-09-01"}})
      assert json_response(conn, 422)["detail"] == "First-met reminders are managed from the contact's first-met date."
    end

    test "update is rejected", ctx do
      conn = patch(ctx.conn, ~p"/api/reminders/#{ctx.first_met.id}", %{"reminder" => %{"title" => "x"}})
      assert json_response(conn, 422)
    end

    test "delete is rejected", ctx do
      conn = delete(ctx.conn, ~p"/api/reminders/#{ctx.first_met.id}")
      assert json_response(conn, 422)
    end
  end

  test "description and day intervals round-trip", ctx do
    conn =
      post(ctx.conn, ~p"/api/contacts/#{ctx.contact.id}/reminders", %{
        "reminder" => %{"type" => "recurring", "title" => "Water", "anchor_date" => "2026-01-01",
                        "interval_unit" => "day", "interval_count" => 10, "description" => "Ferns"}
      })

    data = json_response(conn, 201)["data"]
    assert data["interval_unit"] == "day"
    assert data["description"] == "Ferns"
  end
```

(Match `ctx.conn` / `ctx.contact` to the names the file's setup uses.) In `contact_controller_test.exs` add:

```elixir
  test "first_met_reminder is exposed and updatable", ctx do
    conn = patch(ctx.conn, ~p"/api/contacts/#{ctx.contact.id}", %{"contact" => %{"first_met_at" => "2012-09-01", "first_met_reminder" => true}})
    assert json_response(conn, 200)["data"]["first_met_reminder"] == true
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/controllers/api/`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `reminder_controller.ex`, rename all three `reject_birthday(` calls to `reject_derived(` and replace the helper (lines 203–207) with:

```elixir
  # Birthday and first-met reminders are derived from the contact.
  defp reject_derived("birthday"),
    do: {:error, 422, "Birthday reminders are managed from the contact's birthdate."}

  defp reject_derived("first_met"),
    do: {:error, 422, "First-met reminders are managed from the contact's first-met date."}

  defp reject_derived(_type), do: :ok
```

Add `description: r.description,` after `title: r.title,` in `reminder_json/1` here and in `ContactJSON.reminder/1`. In `ContactJSON.data/1` add `first_met_reminder: contact.first_met_reminder,` after `first_met_additional_info:`.

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/controllers/api/
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/controllers/api/reminder_controller.ex lib/kith_web/controllers/api/contact_json.ex test/kith_web/controllers/api/
git commit -m "feat(api): read-only first-met reminders, reminder description, first_met_reminder flag"
```

---

## Lane A-import (wave 1: A6; wave 2: A7, A8)

### Task A6: `ReminderMapper` (pure) with real Monica fixtures

**Files:**
- Create: `lib/kith/imports/monica/reminder_mapper.ex`
- Create: `test/support/fixtures/monica/4.1.2/reminders.json` (copied, see Step 1)
- Test: `test/kith/imports/monica/reminder_mapper_test.exs`

**Interfaces:**
- Consumes: nothing from other tasks (pure; produces attribute maps with the string keys Task A1 casts). Can start in wave 1.
- Produces:
  - `ReminderMapper.map(reminder :: map, contact :: %{birthdate: Date.t() | nil, first_met_at: Date.t() | nil}, today :: Date.t()) :: :birthday | :first_met | {:create, attrs :: map, notes :: [atom]} | {:skip, :unknown_frequency | :unparseable_date}`
  - `ReminderMapper.stay_in_touch(api_contact :: map, today :: Date.t()) :: :none | {:create, attrs :: map, []}`
  - `ReminderMapper.parse_date(term) :: Date.t() | nil`
  - `attrs` keys (strings): `"type"`, `"title"`, `"description"`, `"anchor_date"`, `"interval_unit"`, `"interval_count"`, `"active"`. Notes: `[:non_positive_interval]` or `[]`.
  - The spec writes the decisions as `{:birthday}` / `{:first_met}`; this plan uses the bare atoms `:birthday` / `:first_met` (idiomatic, same meaning).

- [ ] **Step 1: Add the real-payload fixture**

```bash
mkdir -p test/support/fixtures/monica/4.1.2
cp /c/Users/ME/monica-review/monica-4.1.2-reminders-fixture.json test/support/fixtures/monica/4.1.2/reminders.json
```

It holds 9 contacts and 23 reminders exactly as Monica 4.1.2 returned them on 2026-10-14 (trimmed to the fields Kith reads). Do not hand-edit it.

- [ ] **Step 2: Write the failing test**

`test/kith/imports/monica/reminder_mapper_test.exs`:

```elixir
defmodule Kith.Imports.Monica.ReminderMapperTest do
  use ExUnit.Case, async: true

  alias Kith.Imports.Monica.ReminderMapper

  @today ~D[2026-10-14]
  @fixture Path.expand("../../../support/fixtures/monica/4.1.2/reminders.json", __DIR__)

  setup_all do
    data = @fixture |> File.read!() |> Jason.decode!()

    contacts =
      Map.new(data["contacts"], fn c ->
        {c["id"],
         %{
           birthdate: ReminderMapper.parse_date(get_in(c, ["information", "dates", "birthdate", "date"])),
           first_met_at:
             ReminderMapper.parse_date(get_in(c, ["information", "how_you_met", "first_met_date", "date"]))
         }}
      end)

    %{reminders: Map.new(data["reminders"], &{&1["id"], &1}), contacts: contacts, raw: data}
  end

  defp decide(ctx, id) do
    r = ctx.reminders[id]
    ReminderMapper.map(r, ctx.contacts[r["contact_id"]], @today)
  end

  defp recurring(unit, count, anchor),
    do: %{"type" => "recurring", "interval_unit" => unit, "interval_count" => count,
          "anchor_date" => anchor, "active" => true}

  defp one_time(anchor, active),
    do: %{"type" => "one_time", "interval_unit" => nil, "interval_count" => nil,
          "anchor_date" => anchor, "active" => active}

  # Monica reminder id => expected decision (spec §4 R1–R6, §8)
  @expected %{
    1 => :birthday,                                   # API-edited, delible: true (M3)
    2 => :birthday,                                   # 29 Feb
    3 => {:recurring, "year", 1, ~D[2015-03-09]},
    4 => {:recurring, "week", 2, ~D[2026-01-05]},
    5 => {:recurring, "month", 1, ~D[2024-02-01]},
    6 => {:one_time, ~D[2020-01-01], false},
    7 => {:one_time, ~D[2027-01-10], true},
    8 => :birthday,                                   # year-unknown (M6)
    9 => :birthday,                                   # deceased title (M5)
    10 => {:recurring, "year", 1, ~D[2020-08-01]},    # death anniversary
    11 => :birthday,
    12 => :first_met,
    13 => {:recurring, "week", 2, ~D[2026-01-05]},
    14 => {:recurring, "month", 1, ~D[2025-01-31]},
    15 => {:recurring, "month", 3, ~D[2025-11-30]},
    16 => {:recurring, "year", 2, ~D[2016-02-29]},
    17 => {:one_time, ~D[2026-10-14], true},          # today counts as due (D6)
    18 => {:one_time, ~D[2025-03-01], false},
    19 => {:one_time, ~D[2026-10-12], false},         # already sent in Monica (M10)
    20 => {:one_time, ~D[2027-02-14], true},
    21 => {:one_time, ~D[2027-06-01], true},          # frequency_number 0 (D7)
    22 => :birthday,                                   # "Fiona birthday party" (D1 cost)
    23 => {:recurring, "year", 1, ~D[2019-05-10]}     # life event
  }

  test "every captured Monica 4.1.2 reminder maps as the spec says", ctx do
    for {id, expected} <- @expected do
      got = decide(ctx, id)

      case expected do
        atom when is_atom(atom) ->
          assert got == atom, "reminder #{id}: #{inspect(got)}"

        {:recurring, unit, count, anchor} ->
          assert {:create, attrs, []} = got, "reminder #{id}: #{inspect(got)}"
          assert Map.take(attrs, Map.keys(recurring(unit, count, anchor))) == recurring(unit, count, anchor)

        {:one_time, anchor, active} ->
          assert {:create, attrs, _notes} = got, "reminder #{id}: #{inspect(got)}"
          assert Map.take(attrs, Map.keys(one_time(anchor, active))) == one_time(anchor, active)
      end
    end
  end

  test "titles and descriptions are copied", ctx do
    assert {:create, %{"title" => "One-time future", "description" => "Has a description"}, _} =
             decide(ctx, 20)
  end

  test "frequency_number 0 is noted", ctx do
    assert {:create, _, [:non_positive_interval]} = decide(ctx, 21)
  end

  test "unknown frequency types and unparseable dates are skipped" do
    contact = %{birthdate: nil, first_met_at: nil}
    assert {:skip, :unknown_frequency} =
             ReminderMapper.map(%{"frequency_type" => "fortnight", "initial_date" => "2026-01-01T00:00:00Z"}, contact, @today)

    assert {:skip, :unparseable_date} =
             ReminderMapper.map(%{"frequency_type" => "week", "frequency_number" => 1, "initial_date" => "soon"}, contact, @today)
  end

  test "a blank title falls back to Imported reminder" do
    contact = %{birthdate: nil, first_met_at: nil}
    assert {:create, %{"title" => "Imported reminder"}, _} =
             ReminderMapper.map(%{"frequency_type" => "one_time", "frequency_number" => 1, "title" => " ", "initial_date" => "2027-01-01T00:00:00Z"}, contact, @today)
  end

  test "stay_in_touch/2 maps Monica's days onto a day interval", ctx do
    gina = Enum.find(ctx.raw["contacts"], &(&1["first_name"] == "Gina"))

    assert {:create, %{"type" => "stay_in_touch", "interval_unit" => "day", "interval_count" => 14,
                       "anchor_date" => ~D[2026-10-28], "active" => true}, []} =
             ReminderMapper.stay_in_touch(gina, @today)

    assert ReminderMapper.stay_in_touch(%{"stay_in_touch_frequency" => nil}, @today) == :none
    assert ReminderMapper.stay_in_touch(%{"stay_in_touch_frequency" => 0}, @today) == :none

    assert {:create, %{"anchor_date" => ~D[2026-10-21]}, []} =
             ReminderMapper.stay_in_touch(%{"stay_in_touch_frequency" => 7, "stay_in_touch_trigger_date" => nil}, @today)
  end

  test "parse_date/1 accepts every shape Monica has sent" do
    assert ReminderMapper.parse_date("2026-07-04T00:00:00Z") == ~D[2026-07-04]
    assert ReminderMapper.parse_date("2026-07-04") == ~D[2026-07-04]
    assert ReminderMapper.parse_date("2026-07-04 00:00:00") == ~D[2026-07-04]
    assert ReminderMapper.parse_date(%{"date" => "2026-07-04 00:00:00", "timezone" => "UTC"}) == ~D[2026-07-04]
    assert ReminderMapper.parse_date(nil) == nil
    assert ReminderMapper.parse_date("soon") == nil
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `MIX_TEST_PARTITION=$LANE mix test test/kith/imports/monica/reminder_mapper_test.exs` (no DB needed, but the alias is harmless)
Expected: FAIL (`ReminderMapper` undefined).

- [ ] **Step 4: Implement the mapper**

`lib/kith/imports/monica/reminder_mapper.ex`:

```elixir
defmodule Kith.Imports.Monica.ReminderMapper do
  @moduledoc """
  Decides what a Monica 4.1.2 reminder becomes in Kith. Pure: no Repo access.

  Rules (design spec 2026-10-14 §4), checked in order:

    * unknown `frequency_type` or unparseable `initial_date` → `{:skip, reason}`
    * yearly, every 1 year, on the contact's birthday (month-day) → `:birthday`
    * yearly, every 1 year, on the contact's first-met day → `:first_met`
    * week/month/year every N ≥ 1 → a `recurring` reminder anchored on `initial_date`
    * one-time, or N ≤ 0 → a `one_time` reminder on `initial_date`, inactive when
      that date is before `today`

  Monica 4.1.2 sends no `next_expected_date` and no birthday flag, so the
  schedule is rebuilt from `initial_date` and Kith's own calendar maths.
  """

  @frequency_types ~w(one_time week month year)

  @type decision ::
          :birthday
          | :first_met
          | {:create, map(), [atom()]}
          | {:skip, :unknown_frequency | :unparseable_date}

  @spec map(map(), map(), Date.t()) :: decision()
  def map(reminder, contact, %Date{} = today) do
    type = reminder["frequency_type"]
    count = to_int(reminder["frequency_number"])
    date = parse_date(reminder["initial_date"])

    cond do
      type not in @frequency_types -> {:skip, :unknown_frequency}
      is_nil(date) -> {:skip, :unparseable_date}
      yearly_on?(type, count, date, contact[:birthdate]) -> :birthday
      yearly_on?(type, count, date, contact[:first_met_at]) -> :first_met
      type != "one_time" and is_integer(count) and count >= 1 -> recurring(reminder, type, count, date)
      true -> one_time(reminder, type, date, today)
    end
  end

  @doc "Monica's per-contact stay-in-touch setting (days) as a Kith reminder."
  @spec stay_in_touch(map(), Date.t()) :: :none | {:create, map(), []}
  def stay_in_touch(api_contact, %Date{} = today) do
    case to_int(api_contact["stay_in_touch_frequency"]) do
      days when is_integer(days) and days > 0 ->
        anchor = parse_date(api_contact["stay_in_touch_trigger_date"]) || Date.add(today, days)

        {:create,
         %{
           "type" => "stay_in_touch",
           "title" => nil,
           "description" => nil,
           "anchor_date" => anchor,
           "interval_unit" => "day",
           "interval_count" => days,
           "active" => true
         }, []}

      _ ->
        :none
    end
  end

  @doc "Parses every date shape Monica has been seen to send; nil otherwise."
  @spec parse_date(term()) :: Date.t() | nil
  def parse_date(%{"date" => d}), do: parse_date(d)

  def parse_date(str) when is_binary(str) do
    with :error <- from_iso_date(str),
         :error <- from_iso_datetime(str),
         :error <- from_naive_datetime(str),
         do: nil
  end

  def parse_date(_), do: nil

  defp from_iso_date(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> :error
    end
  end

  defp from_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> :error
    end
  end

  defp from_naive_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> NaiveDateTime.to_date(ndt)
      _ -> :error
    end
  end

  defp yearly_on?("year", 1, %Date{} = date, %Date{} = target),
    do: {date.month, date.day} == {target.month, target.day}

  defp yearly_on?(_type, _count, _date, _target), do: false

  defp recurring(reminder, unit, count, date) do
    {:create,
     base(reminder, date)
     |> Map.merge(%{
       "type" => "recurring",
       "interval_unit" => unit,
       "interval_count" => count,
       "active" => true
     }), []}
  end

  defp one_time(reminder, type, date, today) do
    notes = if type == "one_time", do: [], else: [:non_positive_interval]

    {:create,
     base(reminder, date)
     |> Map.merge(%{
       "type" => "one_time",
       "interval_unit" => nil,
       "interval_count" => nil,
       "active" => Date.compare(date, today) != :lt
     }), notes}
  end

  defp base(reminder, date) do
    %{
      "title" => title(reminder["title"]),
      "description" => blank_to_nil(reminder["description"]),
      "anchor_date" => date
    }
  end

  defp title(t) when is_binary(t), do: if(String.trim(t) == "", do: "Imported reminder", else: t)
  defp title(_), do: "Imported reminder"

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
```

- [ ] **Step 5: Run the tests**

Run: `MIX_TEST_PARTITION=$LANE mix test test/kith/imports/monica/reminder_mapper_test.exs`
Expected: PASS.

- [ ] **Step 6: Format, credo, full suite, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/imports/monica/reminder_mapper.ex test/support/fixtures/monica/4.1.2/reminders.json test/kith/imports/monica/reminder_mapper_test.exs
git commit -m "feat(imports): pure Monica 4.1.2 reminder mapper tested against real payloads"
```

### Task A7 (wave 2): Worker carries out the mapper's decisions

**Files:**
- Modify: `lib/kith/workers/monica_misc_data_worker.ex:467-672`
- Test: `test/kith/workers/monica_misc_data_worker_test.exs:197-469` (replace the `describe "reminders import — date handling (issue #5)"` block)

**Interfaces:**
- Consumes: A1 (`description`, `day`, `Reminders.account_today/1`), A2 (`sync_first_met/1`, `get_first_met_reminder/2`, `first_met_reminder`), A6 (`ReminderMapper.map/3`).
- Produces: per Monica reminder, exactly one mapped Kith reminder; re-imports update in place.

- [ ] **Step 1: Replace the old reminder tests with failing ones**

Delete lines 197–469 (the whole `describe "reminders import — date handling (issue #5)"` block; keep the private helpers below it). Insert:

```elixir
  describe "reminders import (Monica 4.1.2)" do
    setup %{user: user, account_id: account_id} do
      %{import_job: api_import(account_id, user.id), today: Kith.Reminders.account_today(account_id)}
    end

    defp monica(id, attrs),
      do: Map.merge(%{"id" => id, "title" => "R#{id}", "description" => nil, "frequency_number" => 1, "delible" => true}, attrs)

    test "a titled Monica birthday reminder maps onto the derived birthday reminder", ctx do
      contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

      assert :ok =
               import_reminders(ctx.import_job, contact, [
                 monica(1, %{"title" => "Wish happy birthday to Mona", "frequency_type" => "year",
                             "initial_date" => "1990-06-15T00:00:00Z", "delible" => false})
               ])

      assert [%{type: "birthday"} = r] = contact_reminders(ctx.account_id, contact.id)
      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "1").local_entity_id == r.id
    end

    test "an API-edited birthday reminder (delible: true, custom title) still maps", ctx do
      contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

      import_reminders(ctx.import_job, contact, [
        monica(1, %{"title" => "Wish happy birthday to Mona!", "frequency_type" => "year",
                    "initial_date" => "1990-06-15T00:00:00Z"})
      ])

      assert [%{type: "birthday"}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "a first-met anniversary opts the contact in and maps onto first_met", ctx do
      contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})

      import_reminders(ctx.import_job, contact, [
        monica(12, %{"title" => "Anniversary of the day you first met", "frequency_type" => "year",
                     "initial_date" => "2012-09-01T00:00:00Z", "delible" => false})
      ])

      assert Repo.get!(Kith.Contacts.Contact, contact.id).first_met_reminder
      assert [%{type: "first_met", anchor_date: ~D[2012-09-01]} = r] = contact_reminders(ctx.account_id, contact.id)
      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "12").local_entity_id == r.id
    end

    test "a recurring reminder keeps Monica's anchor and interval", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(4, %{"frequency_type" => "week", "frequency_number" => 2, "initial_date" => "2026-01-05T00:00:00Z"})
      ])

      assert [r] = contact_reminders(ctx.account_id, contact.id)
      assert %{type: "recurring", interval_unit: "week", interval_count: 2, anchor_date: ~D[2026-01-05], active: true} = r
      assert r.next_reminder_date == Kith.Reminders.Occurrences.next_on_or_after(Reminder.schedule(r), ctx.today)
    end

    test "a past one-time reminder is imported inactive with its own date", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(6, %{"frequency_type" => "one_time", "initial_date" => "2020-01-01T00:00:00Z"})
      ])

      assert [%{type: "one_time", anchor_date: ~D[2020-01-01], active: false}] =
               contact_reminders(ctx.account_id, contact.id)
    end

    test "frequency_number 0 imports as one-time and logs a warning", ctx do
      contact = contact_fixture(ctx.account_id)
      future = ctx.today |> Date.add(60) |> Date.to_iso8601()

      log =
        capture_log(fn ->
          import_reminders(ctx.import_job, contact, [
            monica(21, %{"frequency_type" => "month", "frequency_number" => 0, "initial_date" => "#{future}T00:00:00Z"})
          ])
        end)

      assert log =~ "non_positive_interval"
      assert [%{type: "one_time", active: true}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "the description is imported", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(20, %{"frequency_type" => "one_time", "initial_date" => "2099-02-14T00:00:00Z", "description" => "Has a description"})
      ])

      assert [%{description: "Has a description"}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "re-importing updates the mapped reminder in place", ctx do
      contact = contact_fixture(ctx.account_id)
      payload = fn title -> [monica(3, %{"title" => title, "frequency_type" => "year", "initial_date" => "2015-03-09T00:00:00Z"})] end

      import_reminders(ctx.import_job, contact, payload.("Wedding"))
      [first] = contact_reminders(ctx.account_id, contact.id)

      import_reminders(ctx.import_job, contact, payload.("Wedding anniversary"))
      assert [again] = contact_reminders(ctx.account_id, contact.id)
      assert again.id == first.id
      assert again.title == "Wedding anniversary"
    end

    test "a changed frequency type replaces the row and re-points the mapping", ctx do
      contact = contact_fixture(ctx.account_id)
      import_reminders(ctx.import_job, contact, [monica(5, %{"frequency_type" => "one_time", "initial_date" => "2099-01-01T00:00:00Z"})])
      [old] = contact_reminders(ctx.account_id, contact.id)

      import_reminders(ctx.import_job, contact, [monica(5, %{"frequency_type" => "month", "initial_date" => "2099-01-01T00:00:00Z"})])

      assert [%{type: "recurring"} = new] = contact_reminders(ctx.account_id, contact.id)
      refute new.id == old.id
      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "5").local_entity_id == new.id
    end

    test "re-importing after the user deleted the mapped reminder recreates it", ctx do
      contact = contact_fixture(ctx.account_id)
      payload = [monica(7, %{"frequency_type" => "one_time", "initial_date" => "2099-01-10T00:00:00Z"})]

      import_reminders(ctx.import_job, contact, payload)
      [r] = contact_reminders(ctx.account_id, contact.id)
      {:ok, _} = Kith.Reminders.delete_reminder(r)

      assert :ok = import_reminders(ctx.import_job, contact, payload)
      assert [new] = contact_reminders(ctx.account_id, contact.id)
      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "7").local_entity_id == new.id
    end

    test "an unknown frequency type is skipped with a warning", ctx do
      contact = contact_fixture(ctx.account_id)

      log =
        capture_log(fn ->
          import_reminders(ctx.import_job, contact, [monica(99, %{"frequency_type" => "fortnight", "initial_date" => "2026-01-01T00:00:00Z"})])
        end)

      assert log =~ "unknown_frequency"
      assert contact_reminders(ctx.account_id, contact.id) == []
    end

    test "a generic row from an earlier import is replaced once the contact has a birthdate", ctx do
      contact = contact_fixture(ctx.account_id)
      payload = [monica(9, %{"title" => "Wish happy birthday to Mona", "frequency_type" => "year", "initial_date" => "1990-06-15T00:00:00Z"})]

      import_reminders(ctx.import_job, contact, payload)
      assert [%{type: "recurring"} = generic] = contact_reminders(ctx.account_id, contact.id)

      {:ok, contact} = Kith.Contacts.update_contact(contact, %{birthdate: ~D[1990-06-15]})
      import_reminders(ctx.import_job, contact, payload)

      assert [%{type: "birthday"} = r] = contact_reminders(ctx.account_id, contact.id)
      refute r.id == generic.id
      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "9").local_entity_id == r.id
    end
  end
```

Remove the now-unused `generic_reminders/2` helper and the `TimeHelper` alias if the compiler reports them unused.

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/workers/monica_misc_data_worker_test.exs`
Expected: FAIL (birthday duplicated as recurring; past dates clamped to today; frequency_number ignored).

- [ ] **Step 3: Replace the worker's reminder code**

In `lib/kith/workers/monica_misc_data_worker.ex`, add `alias Kith.Imports.Monica.ReminderMapper` and `alias Kith.Reminders` next to the other aliases. Replace lines 467–672 (`import_contact_reminders/5` through `reminder_title/1`) with:

```elixir
  defp import_contact_reminders(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/reminders"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => reminders}} when is_list(reminders) ->
        today = Reminders.account_today(contact.account_id)

        Enum.count(reminders, fn reminder ->
          match?(:ok, import_single_reminder(user_id, contact, reminder, import_job, today))
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch reminders for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  # Carries out `ReminderMapper`'s decision (design spec 2026-10-14 §4).
  defp import_single_reminder(user_id, contact, data, import_job, today) do
    case ReminderMapper.map(data, contact, today) do
      :birthday ->
        import_derived(contact, data, import_job, fn -> Reminders.sync_birthday(contact) end)

      :first_met ->
        import_derived(contact, data, import_job, fn -> opt_in_first_met(contact) end)

      {:create, attrs, notes} ->
        Enum.each(notes, fn note ->
          Logger.warning("[MonicaMiscData] reminder #{data["id"]}: #{note}; imported as one-time")
        end)

        upsert_reminder(user_id, contact, data, attrs, import_job)

      {:skip, reason} ->
        Logger.warning("[MonicaMiscData] reminder #{data["id"]} skipped: #{reason}")
        {:error, reason}
    end
  end

  defp opt_in_first_met(contact) do
    with {:ok, contact} <- Contacts.update_contact(contact, %{first_met_reminder: true}) do
      Reminders.sync_first_met(contact)
    end
  end

  # A derived reminder (birthday / first_met) is owned by the contact, not the
  # import. A mapping left over from an earlier import that made a generic row
  # (before the contact had the date) is dropped and re-pointed here.
  defp import_derived(contact, data, import_job, sync) do
    with :ok <- drop_stale_generic(mapped_local_reminder(import_job, data["id"])),
         {:ok, %Reminders.Reminder{} = reminder} <- sync.() do
      maybe_record_entity(import_job, "reminder", data["id"], "reminder", reminder.id)
      :ok
    else
      {:ok, :none} -> log_reminder_error({:no_derived_reminder, contact.id})
      {:error, reason} -> log_reminder_error(reason)
    end
  end

  defp drop_stale_generic(%Reminders.Reminder{type: type} = mapped)
       when type not in ["birthday", "first_met"] do
    case Reminders.delete_reminder(mapped) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_stale_generic(_mapped), do: :ok

  defp upsert_reminder(user_id, contact, data, attrs, import_job) do
    new_type = attrs["type"]

    result =
      case mapped_local_reminder(import_job, data["id"]) do
        %Reminders.Reminder{type: ^new_type} = mapped ->
          Reminders.update_reminder(mapped, Map.delete(attrs, "type"))

        %Reminders.Reminder{type: type} = mapped when type not in ["birthday", "first_met"] ->
          with {:ok, _} <- Reminders.delete_reminder(mapped), do: create(user_id, contact, attrs)

        _derived_or_missing ->
          create(user_id, contact, attrs)
      end

    case result do
      {:ok, reminder} ->
        maybe_record_entity(import_job, "reminder", data["id"], "reminder", reminder.id)
        :ok

      {:error, reason} ->
        log_reminder_error(reason)
    end
  end

  defp create(user_id, contact, attrs),
    do: Reminders.create_reminder(contact.account_id, user_id, Map.put(attrs, "contact_id", contact.id))

  defp mapped_local_reminder(nil, _source_id), do: nil
  defp mapped_local_reminder(_import_job, nil), do: nil

  defp mapped_local_reminder(import_job, source_id) do
    case Imports.find_import_record(
           import_job.account_id,
           import_job.source,
           "reminder",
           to_string(source_id)
         ) do
      %{local_entity_id: id} when is_integer(id) -> Reminders.get_reminder(import_job.account_id, id)
      _ -> nil
    end
  end

  defp log_reminder_error(reason) do
    Logger.warning("[MonicaMiscData] reminder error: #{inspect_errors(reason)}")
    {:error, reason}
  end
```

Notes for the implementer: `Reminders.get_reminder/2` returns nil for a deleted row, so a mapping to a deleted reminder falls through to `create` (Review Focus 2). `update_changeset/3` does not cast `type`, hence the type check before updating. Keep `parse_date_string/1` and friends — other endpoints still use them; run `mix compile --warnings-as-errors` to catch any now-unused private helper (e.g. `blank?/1`) and delete it.

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/workers/monica_misc_data_worker_test.exs
mix compile --warnings-as-errors && mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/workers/monica_misc_data_worker.ex test/kith/workers/monica_misc_data_worker_test.exs
git commit -m "fix(imports): import Monica 4.1.2 reminders through ReminderMapper"
```

### Task A8 (wave 2): Stay-in-touch from the contact crawl

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex:629-647` (`import_api_contact_children/7`)
- Modify: `test/support/fixtures/monica_api_fixtures.ex` (`contact_json/1`)
- Test: `test/kith/imports/sources/monica_api_test.exs`

**Interfaces:**
- Consumes: A1 (`day`, `account_today/1`), A6 (`ReminderMapper.stay_in_touch/2`).
- Produces: one `stay_in_touch` reminder per Monica contact with a frequency; import record (`"reminder"`, `"stay_in_touch:<monica contact id>"`).

- [ ] **Step 1: Extend the fixture**

In `contact_json/1`, add to `base` (next to `"is_dead"`):

```elixir
      "stay_in_touch_frequency" => overrides[:stay_in_touch_frequency],
      "stay_in_touch_trigger_date" => overrides[:stay_in_touch_trigger_date],
```

- [ ] **Step 2: Write the failing test**

Add to `monica_api_test.exs`:

```elixir
  describe "crawl/5 — stay in touch" do
    test "imports Monica's stay-in-touch days as a day-interval reminder, once", %{user: user, account_id: account_id} do
      contacts = [
        contact_json(id: 9, first_name: "Gina", stay_in_touch_frequency: 14,
                     stay_in_touch_trigger_date: "2026-10-28T19:28:39Z")
      ]

      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1)) end)
      import_job = api_import_fixture(account_id, user.id)

      for _ <- 1..2 do
        assert {:ok, _} = MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})
      end

      assert [r] =
               Repo.all(from r in Kith.Reminders.Reminder,
                 where: r.account_id == ^account_id and r.type == "stay_in_touch")

      assert %{interval_unit: "day", interval_count: 14, anchor_date: ~D[2026-10-28]} = r

      assert Imports.find_import_record(account_id, "monica_api", "reminder", "stay_in_touch:9").local_entity_id ==
               r.id
    end

    test "is skipped when the reminders option is off", %{user: user, account_id: account_id} do
      contacts = [contact_json(id: 9, first_name: "Gina", stay_in_touch_frequency: 14)]
      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1)) end)
      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, _} = MonicaApi.crawl(account_id, user.id, credential(), import_job, %{"reminders" => false})
      assert Repo.all(from r in Kith.Reminders.Reminder, where: r.account_id == ^account_id and r.type == "stay_in_touch") == []
    end
  end
```

(Add `import Ecto.Query` at the top of the test module if it isn't there.)

- [ ] **Step 3: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/imports/sources/monica_api_test.exs`
Expected: FAIL (no stay-in-touch reminder).

- [ ] **Step 4: Implement**

In `import_api_contact_children/7`, after `import_api_tags(contact, api_contact, ref_data)` add:

```elixir
    # Stay-in-touch (design spec 2026-10-14 §4), gated like the reminders endpoint.
    if ctx.opts["reminders"] != false, do: import_api_stay_in_touch(ctx, contact, api_contact, source_id)
```

and add the function (with `alias Kith.Imports.Monica.ReminderMapper` and `alias Kith.Reminders` at the top of the module):

```elixir
  defp import_api_stay_in_touch(ctx, contact, api_contact, source_id) do
    key = "stay_in_touch:#{source_id}"

    case ReminderMapper.stay_in_touch(api_contact, Reminders.account_today(ctx.account_id)) do
      :none ->
        :ok

      {:create, attrs, _notes} ->
        existing =
          case Imports.find_import_record(ctx.account_id, "monica_api", "reminder", key) do
            %{local_entity_id: id} when is_integer(id) -> Reminders.get_reminder(ctx.account_id, id)
            _ -> nil
          end

        result =
          case existing do
            %Reminders.Reminder{type: "stay_in_touch"} = r ->
              Reminders.update_reminder(r, Map.delete(attrs, "type"))

            _ ->
              Reminders.create_reminder(ctx.account_id, ctx.user_id, Map.put(attrs, "contact_id", contact.id))
          end

        case result do
          {:ok, r} ->
            Imports.record_imported_entity(ctx.import_job, "reminder", key, "reminder", r.id)

          {:error, reason} ->
            Logger.warning("[MonicaApi] stay-in-touch for #{source_id}: #{inspect_errors(reason)}")
        end
    end
  end
```

- [ ] **Step 5: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/imports/sources/monica_api_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/imports/sources/monica_api.ex test/support/fixtures/monica_api_fixtures.ex test/kith/imports/sources/monica_api_test.exs
git commit -m "feat(imports): import Monica stay-in-touch as a day-interval reminder"
```

---

## Lane A-ui (wave 1: A11; wave 2: A9, A10)

### Task A11 (wave 1): 29 February no longer crashes the contact page

**Files:**
- Modify: `lib/kith/time_helper.ex` (add `anniversary_in_year/2`)
- Modify: `lib/kith_web/live/contact_live/show.ex:241-284`
- Modify: `lib/kith_web/live/contact_live/pets_component.ex:88-100`
- Test: `test/kith/time_helper_test.exs`, `test/kith_web/live/contact_live/show_test.exs`

**Interfaces:**
- Consumes: nothing (independent; touches no file the other lanes touch).
- Produces: `Kith.TimeHelper.anniversary_in_year(Date.t(), integer()) :: Date.t()` — same month-day in `year`, 29 Feb → 28 Feb in common years.

- [ ] **Step 1: Write the failing tests**

`test/kith/time_helper_test.exs`:

```elixir
  describe "anniversary_in_year/2" do
    test "keeps month and day" do
      assert Kith.TimeHelper.anniversary_in_year(~D[1990-06-15], 2027) == ~D[2027-06-15]
    end

    test "29 February falls back to 28 February in a common year" do
      assert Kith.TimeHelper.anniversary_in_year(~D[1992-02-29], 2027) == ~D[2027-02-28]
      assert Kith.TimeHelper.anniversary_in_year(~D[1992-02-29], 2028) == ~D[2028-02-29]
    end
  end
```

`test/kith_web/live/contact_live/show_test.exs`, inside `describe "birthday badge"`:

```elixir
    test "a 29 February birthday renders (no crash in common years)", %{conn: conn, account_id: account_id} do
      leap = contact_fixture(account_id, %{birthdate: ~D[1992-02-29]})
      {:ok, _view, html} = live(conn, ~p"/contacts/#{leap.id}")
      assert html =~ "Birthday"
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/time_helper_test.exs test/kith_web/live/contact_live/show_test.exs`
Expected: FAIL (`anniversary_in_year/2` undefined; in 2026 the LiveView test raises `ArgumentError :invalid_date`).

- [ ] **Step 3: Implement**

`lib/kith/time_helper.ex`:

```elixir
  @doc """
  The same month and day as `date` in `year`. 29 February becomes 28 February
  in common years (the same clamping reminders use).
  """
  @spec anniversary_in_year(Date.t(), integer()) :: Date.t()
  def anniversary_in_year(%Date{} = date, year), do: Date.shift(date, year: year - date.year)
```

In `show.ex`, replace every `Date.new!(today.year, birthdate.month, birthdate.day)` with `Kith.TimeHelper.anniversary_in_year(birthdate, today.year)` and `Date.new!(today.year + 1, birthdate.month, birthdate.day)` with `Kith.TimeHelper.anniversary_in_year(birthdate, today.year + 1)` (lines 246, 266, 271). In `pets_component.ex:93` replace `Date.new!(today.year, date_of_birth.month, date_of_birth.day)` with `Kith.TimeHelper.anniversary_in_year(date_of_birth, today.year)`. Then confirm none are left:

Run: `grep -rn "Date.new!(.*\.month, .*\.day)" lib`
Expected: no output.

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/time_helper_test.exs test/kith_web/live/contact_live/show_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/time_helper.ex lib/kith_web/live/contact_live/show.ex lib/kith_web/live/contact_live/pets_component.ex test/kith/time_helper_test.exs test/kith_web/live/contact_live/show_test.exs
git commit -m "fix(contacts): 29 February birthdays no longer crash the contact page"
```

### Task A9 (wave 2): Reminders section — inactive history, descriptions, first-met, Custom… interval

**Files:**
- Modify: `lib/kith/reminders.ex` (add `list_contact_reminders/2`)
- Modify: `lib/kith_web/live/contact_live/reminders_component.ex`
- Modify: `lib/kith_web/live/reminder_live/upcoming.ex:230-240`
- Modify: `lib/kith_web/components/kith_ui.ex:106-111` (`reminder_icon_name/1` only — Lane B edits `avatar/1` in the same file; keep this edit to these lines)
- Test: `test/kith_web/live/contact_live/reminders_component_test.exs` (create), `test/kith/reminders_test.exs`

**Interfaces:**
- Consumes: A1, A2.
- Produces: `Kith.Reminders.list_contact_reminders(account_id, contact_id) :: [%Reminder{}]` (active and inactive; active first, then by `next_reminder_date`); component root `<div id={@id}>`; form param `reminder[frequency] = "custom"` with `reminder[interval_count]`, `reminder[interval_unit]`, `reminder[description]`.

- [ ] **Step 1: Write the failing tests**

`test/kith/reminders_test.exs`:

```elixir
  test "list_contact_reminders/2 includes inactive reminders, active first", ctx do
    {:ok, past} = Kith.Reminders.create_reminder(ctx.account_id, ctx.user.id, %{"type" => "one_time", "title" => "Old", "anchor_date" => ~D[2020-01-01], "active" => false, "contact_id" => ctx.contact.id})
    {:ok, live} = Kith.Reminders.create_reminder(ctx.account_id, ctx.user.id, %{"type" => "one_time", "title" => "New", "anchor_date" => Date.add(Date.utc_today(), 5), "contact_id" => ctx.contact.id})

    assert Enum.map(Kith.Reminders.list_contact_reminders(ctx.account_id, ctx.contact.id), & &1.id) == [live.id, past.id]
  end
```

`test/kith_web/live/contact_live/reminders_component_test.exs`:

```elixir
defmodule KithWeb.ContactLive.RemindersComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{account_id: user.account_id, contact: contact_fixture(user.account_id)}
  end

  defp open_form(conn, contact) do
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    view |> element("button[phx-click='toggle-more-drawer']") |> render_click()
    view |> element("#reminders-#{contact.id} button", "Add") |> render_click()
    view
  end

  defp form(view, contact), do: element(view, "#reminders-#{contact.id} form")

  test "Custom… shows the count and unit fields; a preset hides them", %{conn: conn, contact: contact} do
    view = open_form(conn, contact)
    html = view |> form(contact) |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})
    assert html =~ ~s(name="reminder[interval_count]")

    html = view |> form(contact) |> render_change(%{reminder: %{type: "recurring", frequency: "weekly"}})
    refute html =~ ~s(name="reminder[interval_count]")
  end

  test "saving Every 10 days creates a day-interval reminder", %{conn: conn, contact: contact, account_id: account_id} do
    view = open_form(conn, contact)
    view |> form(contact) |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})

    html =
      view
      |> form(contact)
      |> render_submit(%{reminder: %{type: "recurring", title: "Water", frequency: "custom",
                                     interval_count: "10", interval_unit: "day",
                                     anchor_date: Date.to_iso8601(Date.add(Date.utc_today(), 1)),
                                     description: "The ferns"}})

    assert html =~ "Every 10 days"
    assert html =~ "The ferns"
    assert [%{interval_unit: "day", interval_count: 10}] = Kith.Reminders.list_contact_reminders(account_id, contact.id)
  end

  test "a preset still saves", %{conn: conn, contact: contact, account_id: account_id} do
    view = open_form(conn, contact)
    view |> form(contact) |> render_change(%{reminder: %{type: "recurring", frequency: "monthly"}})
    view |> form(contact) |> render_submit(%{reminder: %{type: "recurring", title: "Rent", frequency: "monthly", anchor_date: Date.to_iso8601(Date.add(Date.utc_today(), 1))}})
    assert [%{interval_unit: "month", interval_count: 1}] = Kith.Reminders.list_contact_reminders(account_id, contact.id)
  end

  test "a zero or non-numeric count is rejected and nothing is saved", %{conn: conn, contact: contact, account_id: account_id} do
    view = open_form(conn, contact)
    view |> form(contact) |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})

    for bad <- ["0", "abc"] do
      view |> form(contact) |> render_submit(%{reminder: %{type: "recurring", title: "X", frequency: "custom", interval_count: bad, interval_unit: "day", anchor_date: Date.to_iso8601(Date.add(Date.utc_today(), 1))}})
      # The error path keeps the form open (flash is shown by the layout).
      assert has_element?(view, "#reminders-#{contact.id} form")
    end

    assert Kith.Reminders.list_contact_reminders(account_id, contact.id) == []
  end

  test "an inactive reminder is shown; first_met has no delete button", %{conn: conn, contact: contact, user: user} do
    {:ok, _} = Kith.Reminders.create_reminder(user.account_id, user.id, %{"type" => "one_time", "title" => "Renew passport", "anchor_date" => ~D[2020-01-01], "active" => false, "contact_id" => contact.id})
    {:ok, contact} = Kith.Contacts.update_contact(contact, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    html = view |> element("button[phx-click='toggle-more-drawer']") |> render_click()

    assert html =~ "Renew passport"
    assert html =~ "First met"
    first_met = Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
    refute has_element?(view, "#reminders-#{contact.id} button[phx-click='delete'][phx-value-id='#{first_met.id}']")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders_test.exs test/kith_web/live/contact_live/reminders_component_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add `list_contact_reminders/2`**

In `lib/kith/reminders.ex`, after `list_reminders/2`:

```elixir
  @doc """
  All of a contact's reminders for its page, inactive ones included (an
  imported past one-time reminder is history, not noise): active first, then
  by next date.
  """
  def list_contact_reminders(account_id, contact_id) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id)
    |> order_by([r], desc: r.active, asc: r.next_reminder_date, asc: r.id)
    |> Repo.all()
  end
```

- [ ] **Step 4: Update the component**

In `reminders_component.ex`:
- Replace the three `Reminders.list_reminders(` calls with `Reminders.list_contact_reminders(`.
- Append `{"Custom…", "custom"}` to `@frequency_options`.
- In `mount/1` and in the `"show-form"` handler add `|> assign(:form_frequency, "weekly")`.
- Replace the `"type-changed"` handler with:

```elixir
  def handle_event("type-changed", %{"reminder" => params}, socket) do
    {:noreply,
     socket
     |> assign(:form_type, params["type"] || socket.assigns.form_type)
     |> assign(:form_frequency, params["frequency"] || socket.assigns.form_frequency)}
  end
```

- In `"save"`, build attrs from `normalize_schedule(params)` instead of `params`, and add:

```elixir
  # "Custom…" sends unit + count; a preset sends only its name.
  defp normalize_schedule(%{"frequency" => "custom"} = params), do: Map.delete(params, "frequency")
  defp normalize_schedule(params), do: Map.drop(params, ["interval_unit", "interval_count"])
```

- Add `defp type_label("first_met"), do: "First met"` above the fallback clause.
- In `render/1`: give the root `<div>` an `id={@id}`; change the delete button's condition to `:if={@can_edit && reminder.type not in ["birthday", "first_met"]}`; add `selected={value == @form_frequency}` to the frequency `<option>`; after the Frequency `<div>` add:

```heex
              <div
                :if={needs_frequency?(@form_type) and @form_frequency == "custom"}
                class="flex items-center gap-2"
              >
                <span class="text-xs text-[var(--color-text-secondary)]">Every</span>
                <input
                  type="number"
                  name="reminder[interval_count]"
                  min="1"
                  required
                  class="w-16 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                />
                <select
                  name="reminder[interval_unit]"
                  class="rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                >
                  <option value="day" selected>days</option>
                  <option value="week">weeks</option>
                  <option value="month">months</option>
                  <option value="year">years</option>
                </select>
              </div>
```

  and after the First date `<div>`:

```heex
              <div>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  Description (optional)
                </label>
                <textarea
                  name="reminder[description]"
                  rows="2"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                ></textarea>
              </div>
```

  and in the list item, after the title `<div>`:

```heex
                <div
                  :if={reminder.description}
                  class="text-xs text-[var(--color-text-secondary)] whitespace-pre-line"
                >
                  {reminder.description}
                </div>
```

- In `upcoming.ex` add `defp type_icon("first_met"), do: "hero-sparkles"` and `defp type_label("first_met"), do: "First met"` above the fallbacks; in `kith_ui.ex` add `defp reminder_icon_name(%{type: "first_met"}), do: "hero-sparkles"` above the fallback.

A non-numeric count reaches the changeset as a cast error on `interval_count` ("is invalid"), and 0 fails `validate_number`; both surface through the existing `format_errors/1` flash (Review Focus 5).

- [ ] **Step 5: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/reminders_test.exs test/kith_web/live/contact_live/reminders_component_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/reminders.ex lib/kith_web/live/contact_live/reminders_component.ex lib/kith_web/live/reminder_live/upcoming.ex lib/kith_web/components/kith_ui.ex test/kith/reminders_test.exs test/kith_web/live/contact_live/reminders_component_test.exs
git commit -m "feat(reminders): custom intervals, descriptions and inactive history on the contact page"
```

### Task A10 (wave 2): "Remind me every year" in the About form

**Files:**
- Modify: `lib/kith_web/live/contact_live/about_component.ex` (root `id`, first-met section of the edit form)
- Test: `test/kith_web/live/contact_live/about_component_test.exs` (create)

Note: `KithWeb.ContactLive.FirstMetComponent` is not rendered anywhere (dead code); the live first-met UI is `AboutComponent`. Leave `FirstMetComponent` untouched.

**Interfaces:**
- Consumes: A2 (`first_met_reminder`, `sync_first_met/1` via `update_contact/2`).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule KithWeb.ContactLive.AboutComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{contact: contact_fixture(user.account_id)}
  end

  defp edit(conn, contact) do
    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    view |> element("#about-#{contact.id} button", "Edit") |> render_click()
    view
  end

  test "checking the box creates the anniversary reminder; unchecking deletes it", %{conn: conn, contact: contact} do
    view = edit(conn, contact)
    view |> element("#about-#{contact.id} form") |> render_submit(%{contact: %{first_met_at: "2012-09-01", first_met_reminder: "true"}})
    assert Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)

    view = edit(conn, contact)
    # Unchecked: only the hidden input's "false" is sent.
    view |> element("#about-#{contact.id} form") |> render_submit(%{contact: %{first_met_at: "2012-09-01", first_met_reminder: "false"}})
    refute Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/about_component_test.exs`
Expected: FAIL (no `#about-…` element / unknown form field `first_met_reminder`).

- [ ] **Step 3: Implement**

Give `render/1`'s root `<div>` an `id={@id}`. Below the "When" `<div>` (the `contact[first_met_at]` date input), add:

```heex
          <label class="flex items-center gap-2 text-xs text-[var(--color-text-secondary)] cursor-pointer">
            <input type="hidden" name="contact[first_met_reminder]" value="false" />
            <input
              type="checkbox"
              name="contact[first_met_reminder]"
              value="true"
              checked={@contact.first_met_reminder}
              class="rounded border-[var(--color-border)]"
            /> Remind me every year
          </label>
```

The save handler already passes `params` straight to `Contacts.update_contact/2`, which casts the field and syncs the reminder.

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/about_component_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/live/contact_live/about_component.ex test/kith_web/live/contact_live/about_component_test.exs
git commit -m "feat(contacts): opt in to a yearly first-met reminder from the About form"
```

---

## Wave 3 (integration, single agent on the integration branch)

### Task A12: Repeatable end-to-end check against a real Monica 4.1.2

**Files:**
- Create: `test/playwright/fixtures/monica/README.md`, `test/playwright/fixtures/monica/mon.py`, `test/playwright/fixtures/monica/seed.py`, `test/playwright/fixtures/monica/state.php`, `test/playwright/fixtures/monica/docker-compose.yml`
- Create: `test/playwright/monica-reminders.spec.ts`

**Interfaces:**
- Consumes: every task above, merged.

- [ ] **Step 1: Commit the Monica harness**

Copy from `C:/Users/ME/monica-review/`: `docker-compose.yml` (rename the project to `kith-monica-e2e`, keep `127.0.0.1:8089`), `mon.py` (change `TOK = open(...)` to `TOK = os.environ["MONICA_API_KEY"]` and `BASE` to `os.environ.get("MONICA_URL", "http://localhost:8089") + "/api"`), `seed.py` + `seed2.py` merged into one `seed.py`, and `state.php`. Make the seed date-relative so the expectations hold on any run day: "One-time today" → `date.today()`, "One-time past (sent)" → `today - 2 days`, "One-time future" and "Zero frequency (future)" → `today + 120 days`. In `state.php`, find the "sent" reminder by title (`Reminder::where('title', 'One-time past (sent)')->first()`) instead of id 19, and the contacts by `first_name` + `last_name = 'E2E'` instead of ids 8 and 9. README: how to start Monica, register `review@example.com`, create an API token (Settings → API), run `python seed.py` then `docker exec … php /tmp/state.php`, and the env vars the spec needs.

- [ ] **Step 2: Write the spec**

`test/playwright/monica-reminders.spec.ts` (skips unless configured; Kith must be able to reach `MONICA_URL_FROM_KITH`, e.g. `http://host.docker.internal:8089` when Kith runs in Docker):

```ts
import { test, expect, type Page } from "@playwright/test";
import { registerUser, ensureOnDashboard } from "./helpers/auth";

const MONICA_URL = process.env.MONICA_URL_FROM_KITH ?? process.env.MONICA_URL;
const MONICA_KEY = process.env.MONICA_API_KEY;

test.skip(!MONICA_URL || !MONICA_KEY, "MONICA_URL and MONICA_API_KEY are not set");

async function waitConnected(page: Page) {
  await page.waitForSelector("[data-phx-main].phx-connected");
}

async function reminderLines(page: Page, contactId: string): Promise<string[]> {
  await page.goto(`/contacts/${contactId}`);
  await waitConnected(page);
  await page.getByRole("button", { name: /Reminders, Pets, Debts/ }).click();
  const items = page.locator(`#reminders-${contactId} div.group`);
  await expect(items.first()).toBeVisible();
  return (await items.allInnerTexts()).map((t) => t.replace(/\s*\n\s*/g, " | "));
}

test("Monica 4.1.2 reminders import faithfully", async ({ page }) => {
  test.setTimeout(300_000);
  await registerUser(page);
  await ensureOnDashboard(page);

  await page.goto("/settings/import");
  await waitConnected(page);
  await page.getByRole("radio", { name: /Monica CRM \(API\)/ }).check();
  const url = page.getByPlaceholder("https://your-monica-instance.com");
  await url.fill(MONICA_URL!);
  await url.blur();
  const key = page.getByPlaceholder("Your Monica API key");
  await key.fill(MONICA_KEY!);
  await key.blur();
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("button", { name: "Start import" }).click();
  await expect(page.getByText(/Import complete/i)).toBeVisible({ timeout: 240_000 });

  await page.goto("/contacts");
  await waitConnected(page);
  const ids = new Map<string, string>();
  for (const a of await page.locator('a[href^="/contacts/"]').all()) {
    const href = (await a.getAttribute("href")) ?? "";
    const m = href.match(/^\/contacts\/(\d+)$/);
    const name = (await a.innerText()).trim();
    if (m && name) ids.set(name.split("\n")[0], m[1]);
  }
  const id = (name: string): string => {
    const v = ids.get(name);
    expect(v, `contact ${name} imported`).toBeTruthy();
    return v!;
  };

  // Birthdays: exactly one Birthday line, no generic duplicate (spec §8).
  for (const name of ["Mona Vale", "Yara E2E", "Dora E2E", "Fiona E2E"]) {
    const lines = await reminderLines(page, id(name) as string);
    expect(lines.filter((l) => /Birthday · Annually/.test(l))).toHaveLength(1);
    expect(lines.some((l) => /Wish happy birthday|would have celebrated/.test(l))).toBe(false);
  }

  // 29 Feb contact page loads.
  await page.goto(`/contacts/${id("Paul Stone")}`);
  await expect(page.getByText(/Birthday in/)).toBeVisible();

  const gina = await reminderLines(page, id("Gina E2E") as string);
  expect(gina.some((l) => /Water plants .*Every 2 weeks/.test(l))).toBe(true);
  expect(gina.some((l) => /Quarterly review .*Every 3 months/.test(l))).toBe(true);
  expect(gina.some((l) => /Leap-day thing .*Every 2 years/.test(l))).toBe(true);
  expect(gina.some((l) => /Zero frequency .*One-time/.test(l))).toBe(true);
  expect(gina.some((l) => /Stay in touch .*Every 14 days/.test(l))).toBe(true);
  expect(gina.some((l) => /One-time future .*Has a description/.test(l))).toBe(true);

  const fiona = await reminderLines(page, id("Fiona E2E") as string);
  expect(fiona.some((l) => /First met/.test(l))).toBe(true);
  expect(fiona.some((l) => /Fiona birthday party/.test(l))).toBe(false);

  // Exact next dates are pinned by ExUnit with a fixed `today` (Task A6/A7);
  // here only the "no date clamped to today" invariant is checked.
  const solo = await reminderLines(page, id("Solo One") as string);
  const wedding = solo.find((l) => /Wedding anniversary/.test(l))!;
  expect(wedding).toMatch(/Next: Mar 9, \d{4}/);
});
```

- [ ] **Step 3: Run it headless against Docker Monica + Kith**

Follow the orchestration plan's "E2E environment" section: Monica 4.1.2 on :8089, freshly seeded, and Kith from the integration worktree **on port 4000** (`APP_PORT=4000`), because `playwright.config.ts` hard-codes `baseURL: "http://127.0.0.1:4000"`. Run:

```bash
MONICA_URL=http://localhost:8089 MONICA_URL_FROM_KITH=http://host.docker.internal:8089 MONICA_API_KEY="$(cat /c/Users/ME/monica-review/token.txt)" \
  npx playwright test --project=e2e test/playwright/monica-reminders.spec.ts
```

Expected: 1 passed. Also confirm the spec skips cleanly without the env vars: `npx playwright test --project=e2e test/playwright/monica-reminders.spec.ts` → 1 skipped.

- [ ] **Step 4: Commit**

```bash
git add test/playwright/fixtures/monica test/playwright/monica-reminders.spec.ts
git commit -m "test(e2e): Monica 4.1.2 reminder import against a real Monica"
```
