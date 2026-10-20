# Reminder Dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-reminder Oban jobs with one hourly dispatcher so recurring and birthday reminders fire every period on the right calendar date, snooze notifies again, birthdays are derived from contacts, and default reminder rules exist.

**Architecture:** A reminder stores its schedule (`anchor_date` + optional `interval_unit` × `interval_count`) and a cached `next_reminder_date`. The pure module `Kith.Reminders.Occurrences` does the calendar math. An hourly Oban cron (`Kith.Workers.ReminderDispatcher` → `Kith.Reminders.Dispatcher.run/1`) records each due notice as a `ReminderInstance`; a unique index makes that idempotent, and a small `ReminderEmailWorker` job sends the email to the reminder's creator.

**Tech Stack:** Elixir 1.19.5 / OTP 28.5 (via mise), Phoenix LiveView, Ecto/PostgreSQL, Oban (`testing: :manual` in tests), Swoosh (`Swoosh.Adapters.Test` in tests), ExUnit.

**Spec:** `docs/superpowers/specs/2026-09-26-reminder-dispatcher-design.md` (read it before starting; this plan argues from it).

## Global Constraints

- Work **only** in `C:/Users/ME/projects/kith/worktrees/reminder-dispatcher` on branch `feat/reminder-dispatcher`. Never check out, stash, reset, clean or write files in the main checkout `C:/Users/ME/projects/kith`. No bare `git stash`.
- Toolchain: run `elixir --version` first. It must print `Elixir 1.19.5 (compiled with Erlang/OTP 28)`. If it doesn't, prefix every command with `mise exec --`.
- Tests run with `MIX_TEST_PARTITION=_rd` (an isolated test DB). CLAUDE.md: `mix test` must pass with **0 failures before every commit**.
- The husky pre-commit hook runs `mix quality` (compile, format, credo, sobelow, dialyzer). The first dialyzer run in this worktree takes 5–12 minutes. **Never use `--no-verify`.**
- Commits: authored by the git user. **No `Co-Authored-By`, `Claude-Session` or any assistant-attribution trailer.**
- Migration: **schema only. It assumes a fresh, empty database: no backfill, no data deletion.**
- Frequency presets (verbatim): `weekly` = week/1, `biweekly` = week/2, `monthly` = month/1, `3months` = month/3, `6months` = month/6, `annually` = year/1.
- Units: `week`, `month`, `year`. `interval_count >= 1`. Both are null for `one_time`.
- Dispatcher cron: `"0 * * * *"`. Nothing is due for an account until its **local** hour (from `account.timezone`, falling back to UTC) is `>= account.send_hour`.
- Emails go to the reminder's **creator only**.
- Advance notices apply to `birthday` and `one_time` only. The on-day notice applies to every type.
- Birthday reminders: one per contact with a birthdate, `anchor_date` = birthdate, `year`/1, creator = the account owner (earliest admin user). They can't be created, edited or deleted through the REST API.
- Do **not** push the branch or open a PR. Hand back to the user when Task 7 is done.
- Out of scope (do not touch): per-user contact ownership, the Monica importer (`lib/kith/workers/monica_misc_data_worker.ex` keeps compiling unchanged), `ImportWizardLive`.

## Review Focus

1. **A one-time reminder dated in the past** (typed in, or imported) → sent **once** on the next dispatch, never again. Test in Task 3.
2. **Missed periods** (server down for three weeks of a weekly reminder) → **one** on-day notice, then `next_reminder_date` jumps to the first *future* occurrence (no backlog of emails). Test in Task 3.
3. **An account timezone ahead of UTC** (e.g. `Pacific/Kiritimati`, UTC+14), where the local date is already tomorrow → uses the local date and hour. Test in Task 3.
4. **A reminder edited after today's notice was sent** (title change) → no second notice for the same occurrence. Test in Task 3.
5. **A deceased contact's birthday** → instance recorded as `dismissed`, no email, next birthday scheduled. Test in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/kith/reminders/occurrences.ex` (new) | Pure schedule math: `next_on_or_after/2`, `advance_after/2`, `nth/2` |
| `lib/kith/time_helper.ex` | + `local_date_hour/2`, `local_today/1`; − `advance_by_frequency/2` |
| `priv/repo/migrations/20260926120000_reminder_dispatcher.exs` (new) | Schema change for reminders and instances |
| `lib/kith/reminders/reminder.ex` | Schedule fields, virtual `frequency` preset input, changesets that compute `next_reminder_date` |
| `lib/kith/reminders/reminder_instance.ex` | + `occurrence_date`, `kind`, `days_before`, unique constraint |
| `lib/kith/reminders.ex` | Plain-write CRUD, stay-in-touch re-arm, `sync_birthday/1` (Task 4); no job code |
| `lib/kith/reminders/dispatcher.ex` (new) | Finds and records due notices; enqueues emails |
| `lib/kith/workers/reminder_dispatcher.ex` (new) | Hourly cron entry point |
| `lib/kith/workers/reminder_email_worker.ex` (new) | Sends one instance's email to the creator |
| `lib/kith/workers/reminder_scheduler_worker.ex`, `reminder_notification_worker.ex` | **Deleted** |
| `lib/kith/contacts.ex`, `lib/kith/contacts/merge.ex` | Birthday sync hooks; job-cancel code removed |
| `lib/kith/accounts.ex` | Seed default reminder rules at signup (both paths) |
| `lib/kith_web/controllers/api/reminder_controller.ex`, `contact_json.ex`, `live/contact_live/reminders_component.ex` | API/UI compatibility |

---

### Task 1: Occurrence math and local-time helpers

**Files:**
- Create: `lib/kith/reminders/occurrences.ex`
- Create: `test/kith/reminders/occurrences_test.exs`
- Modify: `lib/kith/time_helper.ex` (add two functions; leave everything else for now)
- Modify: `test/kith/time_helper_test.exs` (add a describe block)

**Interfaces:**
- Produces: `Kith.Reminders.Occurrences.schedule` type = `%{anchor_date: Date.t(), interval_unit: "week" | "month" | "year" | nil, interval_count: pos_integer() | nil}`; `next_on_or_after(schedule, Date.t()) :: Date.t() | nil`; `advance_after(schedule, Date.t()) :: Date.t() | nil`; `nth(schedule, non_neg_integer) :: Date.t()`.
- Produces: `Kith.TimeHelper.local_date_hour(DateTime.t(), String.t() | nil) :: {Date.t(), 0..23}`; `Kith.TimeHelper.local_today(String.t() | nil) :: Date.t()`.

- [ ] **Step 1: Verify the toolchain and baseline**

Run: `elixir --version && mix deps.get && MIX_TEST_PARTITION=_rd mix test`
Expected: `Elixir 1.19.5 (compiled with Erlang/OTP 28)` and `1474 tests, 0 failures (2 excluded)` (the count may differ slightly; 0 failures is what matters).

- [ ] **Step 2: Write the failing Occurrences tests**

Create `test/kith/reminders/occurrences_test.exs`:

```elixir
defmodule Kith.Reminders.OccurrencesTest do
  use ExUnit.Case, async: true

  alias Kith.Reminders.Occurrences

  defp s(anchor, unit \\ nil, count \\ nil),
    do: %{anchor_date: anchor, interval_unit: unit, interval_count: count}

  describe "next_on_or_after/2" do
    test "one-time: the anchor when on or after the date, else nil" do
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-04-01]) == ~D[2026-05-01]
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-05-01]) == ~D[2026-05-01]
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-05-02]) == nil
    end

    test "a repeating schedule returns its anchor while the anchor is still ahead" do
      assert Occurrences.next_on_or_after(s(~D[2026-05-01], "month", 1), ~D[2026-01-01]) ==
               ~D[2026-05-01]
    end

    test "repeating schedules land on the calendar occurrence (table)" do
      for {unit, count, anchor, date, expected} <- [
            {"week", 1, ~D[2026-01-05], ~D[2026-01-05], ~D[2026-01-05]},
            {"week", 1, ~D[2026-01-05], ~D[2026-01-06], ~D[2026-01-12]},
            {"week", 2, ~D[2026-01-05], ~D[2026-09-26], ~D[2026-09-28]},
            {"week", 3, ~D[2026-01-05], ~D[2026-01-27], ~D[2026-02-16]},
            {"month", 1, ~D[2024-02-01], ~D[2026-09-26], ~D[2026-10-01]},
            {"month", 3, ~D[2026-01-15], ~D[2026-04-16], ~D[2026-07-15]},
            {"month", 6, ~D[2025-03-31], ~D[2026-09-01], ~D[2026-09-30]},
            {"year", 1, ~D[2015-03-09], ~D[2026-09-26], ~D[2027-03-09]},
            {"year", 2, ~D[2020-06-01], ~D[2026-09-26], ~D[2028-06-01]},
            {"year", 1, ~D[1990-06-15], ~D[2026-06-15], ~D[2026-06-15]}
          ] do
        assert Occurrences.next_on_or_after(s(anchor, unit, count), date) == expected,
               "#{unit}×#{count} from #{anchor} on/after #{date}"
      end
    end

    test "a 31st anchor falls back in short months and returns to the 31st (no drift)" do
      sched = s(~D[2026-01-31], "month", 1)
      assert Occurrences.next_on_or_after(sched, ~D[2026-02-01]) == ~D[2026-02-28]
      assert Occurrences.next_on_or_after(sched, ~D[2026-03-01]) == ~D[2026-03-31]
    end

    test "a Feb 29 anchor falls back to Feb 28 in non-leap years and returns to Feb 29" do
      sched = s(~D[1992-02-29], "year", 1)
      assert Occurrences.next_on_or_after(sched, ~D[2027-01-01]) == ~D[2027-02-28]
      assert Occurrences.next_on_or_after(sched, ~D[2028-01-01]) == ~D[2028-02-29]
    end

    test "an anchor far in the past resolves directly" do
      assert Occurrences.next_on_or_after(s(~D[1900-01-01], "week", 1), ~D[2026-09-26]) ==
               ~D[2026-09-28]
    end
  end

  describe "advance_after/2" do
    test "returns the occurrence strictly after the given date" do
      sched = s(~D[2026-01-05], "week", 1)
      assert Occurrences.advance_after(sched, ~D[2026-01-05]) == ~D[2026-01-12]
      assert Occurrences.advance_after(sched, ~D[2026-01-07]) == ~D[2026-01-12]
    end

    test "is nil for one-time schedules" do
      assert Occurrences.advance_after(s(~D[2026-01-05]), ~D[2026-01-05]) == nil
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/occurrences_test.exs`
Expected: FAIL, `module Kith.Reminders.Occurrences is not available`.

- [ ] **Step 4: Implement Occurrences**

Create `lib/kith/reminders/occurrences.ex`:

```elixir
defmodule Kith.Reminders.Occurrences do
  @moduledoc """
  Pure date arithmetic for reminder schedules.

  A schedule is an anchor date (the first occurrence) plus an optional
  interval of `interval_unit` × `interval_count`. Occurrence *n* is always
  derived from the anchor, never from the previous occurrence, so month-end
  and Feb 29 anchors fall back in short months/years without drifting.
  """

  @type schedule :: %{
          required(:anchor_date) => Date.t(),
          required(:interval_unit) => String.t() | nil,
          required(:interval_count) => pos_integer() | nil
        }

  @doc "The first occurrence on or after `date`, or nil (a one-time schedule whose date has passed)."
  @spec next_on_or_after(schedule(), Date.t()) :: Date.t() | nil
  def next_on_or_after(%{anchor_date: anchor, interval_unit: nil}, %Date{} = date) do
    if Date.compare(anchor, date) == :lt, do: nil, else: anchor
  end

  def next_on_or_after(%{anchor_date: anchor} = schedule, %Date{} = date) do
    if Date.compare(anchor, date) == :lt do
      schedule
      |> lower_bound_index(date)
      |> first_on_or_after(schedule, date)
    else
      anchor
    end
  end

  @doc "The occurrence strictly after `date`; nil for one-time schedules."
  @spec advance_after(schedule(), Date.t()) :: Date.t() | nil
  def advance_after(%{interval_unit: nil}, _date), do: nil
  def advance_after(schedule, %Date{} = date), do: next_on_or_after(schedule, Date.add(date, 1))

  @doc "Occurrence number `n` (0 = the anchor)."
  @spec nth(schedule(), non_neg_integer()) :: Date.t()
  def nth(%{anchor_date: anchor, interval_unit: "week", interval_count: count}, n),
    do: Date.add(anchor, 7 * count * n)

  def nth(%{anchor_date: anchor, interval_unit: "month", interval_count: count}, n),
    do: Date.shift(anchor, month: count * n)

  def nth(%{anchor_date: anchor, interval_unit: "year", interval_count: count}, n),
    do: Date.shift(anchor, year: count * n)

  # An index whose occurrence is not after `date`; month/year clamping can
  # leave it a few days short, so `first_on_or_after/3` steps forward.
  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "week", interval_count: c}, date),
    do: div(Date.diff(date, anchor), 7 * c)

  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "month", interval_count: c}, date) do
    months = (date.year - anchor.year) * 12 + (date.month - anchor.month)
    max(div(months, c) - 1, 0)
  end

  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "year", interval_count: c}, date),
    do: max(div(date.year - anchor.year, c) - 1, 0)

  defp first_on_or_after(n, schedule, date) do
    candidate = nth(schedule, n)

    if Date.compare(candidate, date) == :lt,
      do: first_on_or_after(n + 1, schedule, date),
      else: candidate
  end
end
```

- [ ] **Step 5: Run the Occurrences tests**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/occurrences_test.exs`
Expected: `8 tests, 0 failures`.

- [ ] **Step 6: Write failing TimeHelper tests**

Append this `describe` block inside `Kith.TimeHelperTest` in `test/kith/time_helper_test.exs` (before the final `end`):

```elixir
  describe "local_date_hour/2" do
    test "converts UTC to the timezone's local date and hour" do
      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], "Asia/Tokyo") ==
               {~D[2026-09-27], 5}

      assert TimeHelper.local_date_hour(~U[2026-01-15 03:00:00Z], "America/New_York") ==
               {~D[2026-01-14], 22}
    end

    test "falls back to UTC for an invalid or missing timezone" do
      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], "Mars/Olympus") ==
               {~D[2026-09-26], 20}

      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], nil) == {~D[2026-09-26], 20}
    end
  end

  describe "local_today/1" do
    test "returns a date" do
      assert %Date{} = TimeHelper.local_today("Etc/UTC")
    end
  end
```

- [ ] **Step 7: Run to verify they fail**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/time_helper_test.exs`
Expected: FAIL, `undefined function local_date_hour/2`.

- [ ] **Step 8: Implement the helpers**

In `lib/kith/time_helper.ex`, add `require Logger` after the `alias Kith.Reminders.Reminder` line, and add these functions before `advance_by_frequency/2`:

```elixir
  @doc """
  The local date and hour of `now` in `timezone`. An invalid or missing
  timezone falls back to UTC (logged) so one bad account setting can't stop
  reminder dispatch.
  """
  @spec local_date_hour(DateTime.t(), String.t() | nil) :: {Date.t(), 0..23}
  def local_date_hour(%DateTime{} = now, timezone) do
    local =
      case DateTime.shift_zone(now, timezone || "Etc/UTC") do
        {:ok, shifted} ->
          shifted

        {:error, _reason} ->
          Logger.warning("[TimeHelper] invalid timezone #{inspect(timezone)}; using UTC")
          now
      end

    {DateTime.to_date(local), local.hour}
  end

  @doc "Today's date in `timezone` (UTC fallback as in `local_date_hour/2`)."
  @spec local_today(String.t() | nil) :: Date.t()
  def local_today(timezone) do
    {date, _hour} = local_date_hour(DateTime.utc_now(), timezone)
    date
  end
```

- [ ] **Step 9: Run the TimeHelper tests, then the full suite**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/time_helper_test.exs` → 0 failures.
Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/kith/reminders/occurrences.ex test/kith/reminders/occurrences_test.exs lib/kith/time_helper.ex test/kith/time_helper_test.exs
git commit -m "feat(reminders): calendar occurrence math and local-time helpers"
```

---

### Task 2: Schedule model; remove per-reminder Oban jobs

This task changes the schema, so everything that touches the removed columns changes with it. Between this task and Task 3 **no notifications are sent** (the old workers are deleted). That's expected on this branch.

**Files:**
- Create: `priv/repo/migrations/20260926120000_reminder_dispatcher.exs`
- Replace: `lib/kith/reminders/reminder.ex`
- Modify: `lib/kith/reminders/reminder_instance.ex`
- Replace: `lib/kith/reminders.ex`
- Modify: `lib/kith/time_helper.ex` (remove `advance_by_frequency/2` and the `Reminder` alias)
- Modify: `lib/kith/reminders/cleanup.ex`, `lib/kith/workers/account_deletion_worker.ex`, `lib/kith/workers/contact_purge_worker.ex`, `lib/kith/contacts.ex`, `lib/kith/contacts/merge.ex`
- Delete: `lib/kith/workers/reminder_scheduler_worker.ex`, `lib/kith/workers/reminder_notification_worker.ex`, `test/kith/workers/reminder_scheduler_worker_test.exs`
- Modify: `config/config.exs`, `config/runtime.exs` (remove the scheduler cron line)
- Modify tests: `test/support/fixtures/reminders_fixtures.ex`, `test/support/factory.ex`, `test/kith/reminders_test.exs`, `test/kith/time_helper_test.exs`, `test/kith/reminders/cleanup_test.exs`, `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: `Occurrences.next_on_or_after/2`, `Occurrences.advance_after/2`, `TimeHelper.local_today/1` (Task 1).
- Produces: `Reminder.create_changeset(reminder, attrs, today \\ Date.utc_today())`, `Reminder.update_changeset(reminder, attrs, today \\ Date.utc_today())`, `Reminder.rearm_changeset(reminder, today)`, `Reminder.advance_changeset(reminder, next_date)`, `Reminder.schedule(reminder) :: Occurrences.schedule()`, `Reminder.frequency_preset(reminder) :: String.t() | nil`, `Reminder.interval_label(reminder) :: String.t() | nil`, `Reminder.frequencies/0`, `Reminder.units/0`.
- Produces: `ReminderInstance` fields `occurrence_date :: Date`, `kind :: "on_day" | "advance"`, `days_before :: integer`; unique constraint name `:reminder_instances_occurrence_idx`.
- Produces: `Kith.Reminders.create_reminder/3`, `update_reminder/2`, `delete_reminder/1` (plain writes, same signatures as today); `Kith.Reminders.cancel_all_for_contact/2`, `cancel_jobs/1` and `enqueue_jobs_for_reminder/2` no longer exist.

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260926120000_reminder_dispatcher.exs`:

```elixir
defmodule Kith.Repo.Migrations.ReminderDispatcher do
  use Ecto.Migration

  # Runs on a fresh, empty database (production is reset for this release):
  # no backfill, and the new NOT NULL columns need no defaults.
  def change do
    alter table(:reminders) do
      remove :frequency, :string
      remove :enqueued_oban_job_ids, :jsonb, null: false, default: "[]"
      add :anchor_date, :date, null: false
      add :interval_unit, :string
      add :interval_count, :integer
    end

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('week', 'month', 'year') OR interval_unit IS NULL"
           )

    create constraint(:reminders, :reminders_interval_count_positive,
             check: "interval_count IS NULL OR interval_count >= 1"
           )

    alter table(:reminder_instances) do
      add :occurrence_date, :date, null: false
      add :kind, :string, null: false
      add :days_before, :integer, null: false
    end

    create constraint(:reminder_instances, :reminder_instances_kind_values,
             check: "kind IN ('on_day', 'advance')"
           )

    create unique_index(:reminder_instances, [:reminder_id, :occurrence_date, :days_before],
             name: :reminder_instances_occurrence_idx
           )
  end
end
```

- [ ] **Step 2: Replace the Reminder schema**

Replace the whole of `lib/kith/reminders/reminder.ex` with:

```elixir
defmodule Kith.Reminders.Reminder do
  @moduledoc """
  A reminder associated with a contact.

  The schedule is `anchor_date` (the first occurrence) plus an optional
  interval (`interval_unit` × `interval_count`). `next_reminder_date` caches
  the next occurrence; it is computed here and advanced by
  `Kith.Reminders.Dispatcher`, never set by clients.

  Types:
  - `birthday` — derived from the contact's birthdate (`Kith.Reminders.sync_birthday/1`)
  - `stay_in_touch` — re-armed one interval after it is resolved or dismissed
  - `one_time` — a single date, no interval
  - `recurring` — repeats every interval
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kith.Reminders.Occurrences

  @types ~w(birthday stay_in_touch one_time recurring)
  @units ~w(week month year)
  @frequencies ~w(weekly biweekly monthly 3months 6months annually)
  @presets %{
    "weekly" => {"week", 1},
    "biweekly" => {"week", 2},
    "monthly" => {"month", 1},
    "3months" => {"month", 3},
    "6months" => {"month", 6},
    "annually" => {"year", 1}
  }

  schema "reminders" do
    field :type, :string
    field :title, :string
    field :anchor_date, :date
    field :interval_unit, :string
    field :interval_count, :integer
    field :next_reminder_date, :date
    field :active, :boolean, default: true
    # Preset name ("weekly", …) accepted on input and mapped to unit + count.
    field :frequency, :string, virtual: true

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :creator, Kith.Accounts.User

    has_many :reminder_instances, Kith.Reminders.ReminderInstance

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def units, do: @units
  def frequencies, do: @frequencies

  @doc "The reminder's schedule, in the shape `Kith.Reminders.Occurrences` takes."
  @spec schedule(%__MODULE__{}) :: Occurrences.schedule()
  def schedule(%__MODULE__{} = reminder),
    do: Map.take(reminder, [:anchor_date, :interval_unit, :interval_count])

  @doc "The preset name for this interval, or nil when it matches no preset."
  @spec frequency_preset(map()) :: String.t() | nil
  def frequency_preset(%{interval_unit: unit, interval_count: count}) do
    Enum.find_value(@presets, fn {name, pair} -> if pair == {unit, count}, do: name end)
  end

  @doc "Human label for the interval (\"Weekly\", \"Every 3 weeks\"), or nil for one-time."
  @spec interval_label(map()) :: String.t() | nil
  def interval_label(%{interval_unit: nil}), do: nil
  def interval_label(%{interval_unit: "week", interval_count: 1}), do: "Weekly"
  def interval_label(%{interval_unit: "month", interval_count: 1}), do: "Monthly"
  def interval_label(%{interval_unit: "year", interval_count: 1}), do: "Annually"
  def interval_label(%{interval_unit: unit, interval_count: n}), do: "Every #{n} #{unit}s"

  def create_changeset(reminder, attrs, %Date{} = today \\ Date.utc_today()) do
    reminder
    |> cast(attrs, [
      :type,
      :title,
      :frequency,
      :anchor_date,
      :interval_unit,
      :interval_count,
      :next_reminder_date,
      :active,
      :contact_id,
      :account_id,
      :creator_id
    ])
    |> anchor_from_legacy_next_date()
    |> apply_frequency_preset()
    |> validate_required([:type, :anchor_date, :contact_id, :account_id, :creator_id])
    |> validate_inclusion(:type, @types)
    |> validate_schedule()
    |> put_next_reminder_date(today)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:contact_id, name: :reminders_birthday_unique_idx)
  end

  @doc "Updates title/schedule/active. `next_reminder_date` in attrs is ignored."
  def update_changeset(reminder, attrs, %Date{} = today \\ Date.utc_today()) do
    reminder
    |> cast(attrs, [:title, :frequency, :anchor_date, :interval_unit, :interval_count, :active])
    |> apply_frequency_preset()
    |> validate_required([:anchor_date])
    |> validate_schedule()
    |> recompute_next_if_schedule_changed(today)
  end

  @doc "Stay-in-touch: next date is one interval after `today` (from the last contact)."
  def rearm_changeset(%__MODULE__{} = reminder, %Date{} = today) do
    next = Occurrences.advance_after(%{schedule(reminder) | anchor_date: today}, today)
    change(reminder, next_reminder_date: next)
  end

  @doc "Sets the cached next occurrence (used by the dispatcher)."
  def advance_changeset(%__MODULE__{} = reminder, %Date{} = next_date),
    do: change(reminder, next_reminder_date: next_date)

  # A create request naming `next_reminder_date` but no `anchor_date` (older
  # API clients, fixtures) means "first occurrence on this date".
  defp anchor_from_legacy_next_date(changeset) do
    case {get_field(changeset, :anchor_date), get_change(changeset, :next_reminder_date)} do
      {nil, %Date{} = date} -> put_change(changeset, :anchor_date, date)
      _ -> changeset
    end
  end

  defp apply_frequency_preset(changeset) do
    case get_change(changeset, :frequency) do
      nil ->
        changeset

      name ->
        case Map.fetch(@presets, name) do
          {:ok, {unit, count}} ->
            changeset |> put_change(:interval_unit, unit) |> put_change(:interval_count, count)

          :error ->
            add_error(changeset, :frequency, "is invalid",
              validation: :inclusion,
              enum: @frequencies
            )
        end
    end
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :type) do
      "one_time" ->
        cond do
          get_change(changeset, :frequency) ->
            add_error(changeset, :frequency, "must be nil for one-time reminders")

          get_field(changeset, :interval_unit) || get_field(changeset, :interval_count) ->
            add_error(changeset, :interval_unit, "must be empty for one-time reminders")

          true ->
            changeset
        end

      _repeating ->
        if is_nil(get_field(changeset, :interval_unit)) and
             is_nil(get_change(changeset, :frequency)) do
          add_error(changeset, :frequency, "can't be blank", validation: :required)
        else
          changeset
          |> validate_required([:interval_unit, :interval_count])
          |> validate_inclusion(:interval_unit, @units)
          |> validate_number(:interval_count, greater_than_or_equal_to: 1)
        end
    end
  end

  defp put_next_reminder_date(%Ecto.Changeset{valid?: false} = changeset, _today), do: changeset

  defp put_next_reminder_date(changeset, today) do
    schedule = %{
      anchor_date: get_field(changeset, :anchor_date),
      interval_unit: get_field(changeset, :interval_unit),
      interval_count: get_field(changeset, :interval_count)
    }

    # A one-time reminder keeps its own date even when it is already past.
    next = Occurrences.next_on_or_after(schedule, today) || schedule.anchor_date
    put_change(changeset, :next_reminder_date, next)
  end

  defp recompute_next_if_schedule_changed(changeset, today) do
    if Enum.any?([:anchor_date, :interval_unit, :interval_count], &Map.has_key?(changeset.changes, &1)),
      do: put_next_reminder_date(changeset, today),
      else: changeset
  end
end
```

- [ ] **Step 3: Update ReminderInstance**

In `lib/kith/reminders/reminder_instance.ex`:

1. Replace the moduledoc's first sentence with: `A notice sent for one occurrence of a reminder. Created by \`Kith.Reminders.Dispatcher\`; the unique index on (reminder_id, occurrence_date, days_before) makes each notice send once.`
2. After `@statuses ...` add `@kinds ~w(on_day advance)`.
3. In the schema, after `field :snooze_count ...` add:

```elixir
    field :occurrence_date, :date
    field :kind, :string
    field :days_before, :integer
```

4. Replace `create_changeset/2` with:

```elixir
  def create_changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :status,
      :scheduled_for,
      :fired_at,
      :snoozed_until,
      :snooze_count,
      :occurrence_date,
      :kind,
      :days_before,
      :reminder_id,
      :account_id,
      :contact_id
    ])
    |> validate_required([
      :scheduled_for,
      :occurrence_date,
      :kind,
      :days_before,
      :reminder_id,
      :account_id,
      :contact_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:reminder_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:contact_id)
    |> unique_constraint([:reminder_id, :occurrence_date, :days_before],
      name: :reminder_instances_occurrence_idx
    )
  end
```

- [ ] **Step 4: Replace the Reminders context**

Replace the whole of `lib/kith/reminders.ex` with the following. The unchanged functions (`list_reminders`, `get_reminder!`, `get_birthday_reminder`, `delete_birthday_reminder`, `get_stay_in_touch_reminder`, `resolve_instance`, `snooze_instance`, `dismiss_instance`, `upcoming`, `upcoming_count`, `list_pending_instances`, all rule functions, `seed_default_rules`, `get_pending_instance`, `has_pending_instance?`) are copied verbatim from the current file. What changes is the moduledoc, CRUD, `create_birthday_reminder`, stay-in-touch advancement, `archive_contact_reminders`, and the removal of every job helper plus `cancel_all_for_contact/2`.

```elixir
defmodule Kith.Reminders do
  @moduledoc """
  The Reminders context — reminders, reminder rules, and reminder instances.

  A reminder stores its schedule (`anchor_date` + optional interval) and a
  cached `next_reminder_date`. Nothing is scheduled per reminder: the hourly
  `Kith.Reminders.Dispatcher` finds what is due and records each notice it
  sends as a `ReminderInstance`, so writing a reminder is a plain row write.
  """

  import Ecto.Query, warn: false
  import Kith.Scope

  alias Ecto.Multi
  alias Kith.Accounts
  alias Kith.Repo
  alias Kith.TimeHelper

  alias Kith.Reminders.{
    Reminder,
    ReminderInstance,
    ReminderRule
  }

  # ── Reminders CRUD ──────────────────────────────────────────────────────

  @doc """
  Lists active reminders for a contact, scoped to account.
  """
  def list_reminders(account_id, contact_id) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id and r.active == true)
    |> order_by([r], asc: r.next_reminder_date)
    |> Repo.all()
  end

  @doc """
  Fetches a reminder by ID, scoped to account. Raises if not found.
  """
  def get_reminder!(account_id, id) do
    Reminder
    |> scope_to_account(account_id)
    |> Repo.get!(id)
  end

  @doc """
  Creates a reminder. `next_reminder_date` is computed from the schedule
  using today's date in the account's timezone.
  """
  def create_reminder(account_id, creator_id, attrs) do
    %Reminder{account_id: account_id, creator_id: creator_id}
    |> Reminder.create_changeset(attrs, account_today(account_id))
    |> Repo.insert()
  end

  @doc """
  Updates a reminder's title, schedule or active flag. A schedule change
  recomputes `next_reminder_date`.
  """
  def update_reminder(%Reminder{} = reminder, attrs) do
    reminder
    |> Reminder.update_changeset(attrs, account_today(reminder.account_id))
    |> Repo.update()
  end

  @doc """
  Deletes a reminder (its instances cascade).
  """
  def delete_reminder(%Reminder{} = reminder), do: Repo.delete(reminder)

  # ── Birthday Reminders ──────────────────────────────────────────────────

  @doc """
  Creates a birthday reminder for a contact (yearly from the birthdate).
  Replaced by `sync_birthday/1` in the next change.
  """
  def create_birthday_reminder(
        %{id: contact_id, account_id: account_id, birthdate: birthdate},
        creator_id
      )
      when not is_nil(birthdate) do
    create_reminder(account_id, creator_id, %{
      type: "birthday",
      title: nil,
      anchor_date: birthdate,
      interval_unit: "year",
      interval_count: 1,
      contact_id: contact_id
    })
  end

  @doc """
  Deletes the birthday reminder for a contact. Called when birthdate is removed.
  """
  def delete_birthday_reminder(contact_id, account_id) do
    case get_birthday_reminder(contact_id, account_id) do
      nil -> {:ok, :no_birthday_reminder}
      reminder -> delete_reminder(reminder)
    end
  end

  @doc """
  Returns the birthday reminder for a contact, or nil.
  """
  def get_birthday_reminder(contact_id, account_id) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id and r.type == "birthday")
    |> Repo.one()
  end

  # ── Stay-in-Touch Resolution ────────────────────────────────────────────

  @doc """
  Resolves a pending stay-in-touch instance for a contact and re-arms the
  reminder one interval from today.

  Safe to call even if no stay-in-touch reminder exists for the contact.
  """
  def resolve_stay_in_touch_instance(contact_id) do
    with %Reminder{} = reminder <- get_stay_in_touch_reminder(contact_id),
         %ReminderInstance{} = instance <- get_pending_instance(reminder.id) do
      Multi.new()
      |> Multi.update(:instance, ReminderInstance.resolve_changeset(instance))
      |> Multi.update(
        :reminder,
        Reminder.rearm_changeset(reminder, account_today(reminder.account_id))
      )
      |> Repo.transaction()
      |> case do
        {:ok, _} -> {:ok, :resolved}
        {:error, _step, changeset, _} -> {:error, changeset}
      end
    else
      nil -> {:ok, :no_pending_instance}
    end
  end

  # `limit: 1` rather than a bare `Repo.one/1`: nothing in the schema enforces
  # one active stay-in-touch reminder per contact (the only partial unique
  # index on `reminders` covers birthdays), so any path that creates a second
  # one — a merge, the API, a restored contact — would otherwise turn this
  # into an `Ecto.MultipleResultsError` at the caller. `Kith.Contacts.Merge`
  # dedupes on merge; this keeps the read total regardless.
  defp get_stay_in_touch_reminder(contact_id) do
    from(r in Reminder,
      where: r.contact_id == ^contact_id and r.type == "stay_in_touch" and r.active == true,
      order_by: [asc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  # ── Contact Archival ────────────────────────────────────────────────────

  @doc """
  Handles stay-in-touch reminders when a contact is archived:
  dismisses pending instances and deactivates the reminder.
  """
  def archive_contact_reminders(contact_id, account_id) do
    reminders =
      Reminder
      |> scope_to_account(account_id)
      |> where(
        [r],
        r.contact_id == ^contact_id and r.type == "stay_in_touch" and r.active == true
      )
      |> Repo.all()

    Enum.each(reminders, fn reminder ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(i in ReminderInstance,
        where: i.reminder_id == ^reminder.id and i.status == "pending"
      )
      |> Repo.update_all(set: [status: "dismissed", resolved_at: now])

      reminder
      |> Ecto.Changeset.change(%{active: false})
      |> Repo.update()
    end)

    :ok
  end

  # ── Reminder Instance Management ────────────────────────────────────────

  @doc """
  Resolves a pending ReminderInstance. For stay-in-touch reminders,
  also re-arms next_reminder_date.
  """
  def resolve_instance(%ReminderInstance{} = instance) do
    instance = Repo.preload(instance, :reminder)

    Multi.new()
    |> Multi.update(:instance, ReminderInstance.resolve_changeset(instance))
    |> maybe_advance_stay_in_touch(:reminder, instance.reminder)
    |> Repo.transaction()
    |> case do
      {:ok, %{instance: instance}} -> {:ok, instance}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Snoozes a pending ReminderInstance for the given duration. The dispatcher
  sends it again once `snoozed_until` has passed.
  """
  def snooze_instance(%ReminderInstance{status: "pending"} = instance, duration) do
    instance
    |> ReminderInstance.snooze_changeset(duration)
    |> Repo.update()
  end

  def snooze_instance(%ReminderInstance{}, _duration) do
    {:error, :invalid_status}
  end

  @doc """
  Dismisses a pending ReminderInstance. Same scheduling effect as resolve.
  """
  def dismiss_instance(%ReminderInstance{} = instance) do
    instance = Repo.preload(instance, :reminder)

    Multi.new()
    |> Multi.update(:instance, ReminderInstance.dismiss_changeset(instance))
    |> maybe_advance_stay_in_touch(:reminder, instance.reminder)
    |> Repo.transaction()
    |> case do
      {:ok, %{instance: instance}} -> {:ok, instance}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  defp maybe_advance_stay_in_touch(multi, key, %Reminder{type: "stay_in_touch"} = reminder) do
    Multi.update(
      multi,
      key,
      Reminder.rearm_changeset(reminder, account_today(reminder.account_id))
    )
  end

  defp maybe_advance_stay_in_touch(multi, _key, _reminder), do: multi

  # (copy verbatim from the current file, unchanged:
  #  "Upcoming Reminders Query" section — upcoming/2, upcoming_count/1, list_pending_instances/1,
  #  "Reminder Rules" section — list_reminder_rules/1 … seed_default_rules/1)

  # ── Internal Helpers ────────────────────────────────────────────────────

  @doc false
  def get_pending_instance(reminder_id) do
    from(i in ReminderInstance,
      where: i.reminder_id == ^reminder_id and i.status == "pending",
      limit: 1
    )
    |> Repo.one()
  end

  @doc false
  def has_pending_instance?(reminder_id) do
    from(i in ReminderInstance,
      where: i.reminder_id == ^reminder_id and i.status == "pending"
    )
    |> Repo.exists?()
  end

  defp account_today(account_id) do
    account_id |> Accounts.get_account!() |> Map.get(:timezone) |> TimeHelper.local_today()
  end
end
```

> Replace the parenthesised comment block with the actual code of those two sections, copied from the current file (lines 325–467 of the pre-change `lib/kith/reminders.ex`: `upcoming/2` through `seed_default_rules/1`). Don't leave the comment in.

- [ ] **Step 5: Remove job code elsewhere**

1. `lib/kith/time_helper.ex`: delete `advance_by_frequency/2` with its `@doc` and `@spec`, and delete the line `alias Kith.Reminders.Reminder`.
2. `lib/kith/reminders/cleanup.ex`: delete `cancel_oban_jobs_for_account/1` and its call in `wipe_for_account/1`. Change the moduledoc's first sentence to `Deletes the account's reminders. FK CASCADE removes \`reminder_instances\`.`
3. `lib/kith/workers/account_deletion_worker.ex`: delete `defp cancel_reminder_jobs/1` and the line that calls it (`cancel_reminder_jobs(account_id)` inside `perform/1`); renumber that function's step comments if they're numbered.
4. `lib/kith/workers/contact_purge_worker.ex`: in `purge_contact/1` delete the comment `# Cancel any remaining Oban jobs for the contact's reminders` and the line `Reminders.cancel_all_for_contact(contact.id, contact.account_id)`. Remove `Reminders` from its aliases if it's now unused.
5. `lib/kith/contacts.ex` `empty_trash/1`: delete the `Enum.each(trashed, fn contact -> Kith.Reminders.cancel_all_for_contact(...) end)` block; change its `@doc` first line to `Bulk-deletes all trashed contacts in the given account and returns \`{:ok, count}\`.` If `trashed` becomes unused, delete the `trashed = list_trashed_contacts(account_id)` line too.
6. `lib/kith/contacts/merge.ex`:
   - Delete `defp cancel_reminder_jobs/2` and its preceding comment block (the one starting `# Design spec §2 step 7:`).
   - In `delete_extra_birthday_reminders/3` and `remap_stay_in_touch_reminders_step/3`, delete the `cancel_reminder_jobs(repo, delete_ids)` lines.
   - Replace `resync_birthday_reminder/4`'s second clause (the one with the `cond`) with:

```elixir
  defp resync_birthday_reminder(repo, rows, survivor, _account_id) do
    keep_id = reminder_keep_id(rows, survivor.id)

    repo.get!(Kith.Reminders.Reminder, keep_id)
    |> Kith.Reminders.Reminder.update_changeset(%{anchor_date: survivor.birthdate})
    |> repo.update!()

    {:ok, :done}
  end
```

7. Delete `lib/kith/workers/reminder_scheduler_worker.ex`, `lib/kith/workers/reminder_notification_worker.ex` and `test/kith/workers/reminder_scheduler_worker_test.exs` (`git rm`).
8. `config/config.exs` and `config/runtime.exs`: delete the line `{"0 2 * * *", Kith.Workers.ReminderSchedulerWorker},` from both crontabs.

- [ ] **Step 6: Update test support**

`test/support/fixtures/reminders_fixtures.ex`: in `reminder_instance_fixture/2`, add these keys to the defaults map (inside `Enum.into(attrs, %{ ... })`):

```elixir
        # Distinct per call so a test can insert several instances for one
        # reminder without hitting the (reminder, occurrence, days_before) index.
        occurrence_date: Date.add(Date.utc_today(), -System.unique_integer([:positive, :monotonic])),
        kind: "on_day",
        days_before: 0,
```

`test/support/factory.ex`:
- `reminder_factory`: replace `next_reminder_date: Date.add(Date.utc_today(), 7),` and `enqueued_oban_job_ids: [],` with:

```elixir
      anchor_date: Date.add(Date.utc_today(), 7),
      next_reminder_date: Date.add(Date.utc_today(), 7),
      interval_unit: nil,
      interval_count: nil,
```

- `birthday_reminder_factory`: replace `frequency: nil,` with `interval_unit: "year", interval_count: 1, anchor_date: Date.add(Date.utc_today(), 30),`
- `stay_in_touch_reminder_factory`: replace `frequency: "monthly",` with `interval_unit: "month", interval_count: 1, anchor_date: Date.add(Date.utc_today(), 30),`
- `recurring_reminder_factory`: replace `frequency: "weekly",` with `interval_unit: "week", interval_count: 1, anchor_date: Date.add(Date.utc_today(), 7),`
- `reminder_instance_factory`: add `occurrence_date: Date.utc_today(), kind: "on_day", days_before: 0,`

- [ ] **Step 7: Update existing tests for the removed APIs**

1. `test/kith/time_helper_test.exs`: delete the whole `describe "advance_by_frequency/2"` block.
2. `test/kith/reminders/cleanup_test.exs`: delete the test `"cancels Oban jobs tracked on the target's reminders"`.
3. `test/kith/reminders_test.exs`:
   - In `"resolves pending instance and advances next date"`, replace the two final assertions with:

```elixir
      updated = Repo.get!(Reminder, r.id)
      assert updated.next_reminder_date == Date.shift(Date.utc_today(), month: 1)
```

   - Delete the whole `describe "cancel_all_for_contact/2"` block.
4. `test/kith/contacts_merge_test.exs`:
   - Delete `defp notification_job!/1` (near the top of the module) and the test `"cancels the Oban jobs of the reminder it discards"`.
   - In `"keeps the survivor's own reminder, not the loser's"`, replace `assert kept.frequency == "monthly"` with `assert Kith.Reminders.Reminder.frequency_preset(kept) == "monthly"`.
   - In `describe "inactive birthday reminders"` setup, replace `set: [active: false, enqueued_oban_job_ids: []]` with `set: [active: false]`.
   - Replace the test `"does not enqueue jobs for a deactivated reminder"` with:

```elixir
    test "keeps a deactivated birthday reminder inactive", ctx do
      {:ok, _survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      kept = Repo.get!(Kith.Reminders.Reminder, ctx.reminder.id)

      assert kept.active == false
    end
```

- [ ] **Step 8: Add schedule-model tests**

Append inside `describe "Reminder changeset validations"` in `test/kith/reminders_test.exs`:

```elixir
    test "a preset maps to interval unit and count and computes the next date", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      {:ok, r} =
        Reminders.create_reminder(account_id, user.id, %{
          type: "recurring",
          title: "Pay rent",
          frequency: "monthly",
          anchor_date: ~D[2024-02-01],
          contact_id: contact.id
        })

      assert {r.interval_unit, r.interval_count} == {"month", 1}

      assert r.next_reminder_date ==
               Kith.Reminders.Occurrences.next_on_or_after(Reminder.schedule(r), Date.utc_today())

      assert Date.compare(r.next_reminder_date, Date.utc_today()) != :lt
    end

    test "explicit unit + count represents schedules no preset covers", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      {:ok, r} =
        Reminders.create_reminder(account_id, user.id, %{
          type: "recurring",
          title: "Every three weeks",
          interval_unit: "week",
          interval_count: 3,
          anchor_date: Date.utc_today(),
          contact_id: contact.id
        })

      assert Reminder.frequency_preset(r) == nil
      assert Reminder.interval_label(r) == "Every 3 weeks"
      assert r.next_reminder_date == Date.utc_today()
    end

    test "next_reminder_date in a create request is treated as the anchor", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      date = Date.add(Date.utc_today(), 12)

      {:ok, r} =
        Reminders.create_reminder(account_id, user.id, %{
          type: "one_time",
          title: "Legacy client",
          next_reminder_date: date,
          contact_id: contact.id
        })

      assert r.anchor_date == date
      assert r.next_reminder_date == date
    end

    test "a one-time reminder in the past keeps its own date", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      past = Date.add(Date.utc_today(), -30)

      {:ok, r} =
        Reminders.create_reminder(account_id, user.id, %{
          type: "one_time",
          title: "History",
          anchor_date: past,
          contact_id: contact.id
        })

      assert r.next_reminder_date == past
    end

    test "update recomputes next date only when the schedule changes", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      {:ok, r} =
        Reminders.create_reminder(account_id, user.id, %{
          type: "recurring",
          title: "Weekly",
          frequency: "weekly",
          anchor_date: Date.utc_today(),
          contact_id: contact.id
        })

      {:ok, renamed} = Reminders.update_reminder(r, %{title: "Renamed"})
      assert renamed.next_reminder_date == r.next_reminder_date

      later = Date.add(Date.utc_today(), 10)
      {:ok, moved} = Reminders.update_reminder(r, %{anchor_date: later})
      assert moved.next_reminder_date == later
    end
```

- [ ] **Step 9: Migrate and run the suite**

Run: `MIX_TEST_PARTITION=_rd mix test`
Expected: 0 failures. (The test alias runs migrations on the partition DB.) If any other test still references `frequency`, `enqueued_oban_job_ids`, `ReminderNotificationWorker` or `ReminderSchedulerWorker`, fix it the same way as Step 7 (use `Reminder.frequency_preset/1`, or delete job-only assertions) and note it in the commit message.

Also run: `mix compile --warnings-as-errors` → no warnings.

- [ ] **Step 10: Commit**

```bash
git add -A priv/repo/migrations lib test config
git commit -m "refactor(reminders): schedule model; drop per-reminder Oban jobs" -m "Reminders store anchor_date + interval_unit/interval_count and a computed next_reminder_date; the frequency preset is accepted as a virtual field. Removes enqueued_oban_job_ids and all job cancel/enqueue code, and deletes ReminderSchedulerWorker and ReminderNotificationWorker (replaced by the dispatcher in the next commit)."
```

---

### Task 3: Hourly dispatcher and email worker

**Files:**
- Create: `lib/kith/reminders/dispatcher.ex`
- Create: `lib/kith/workers/reminder_dispatcher.ex`
- Create: `lib/kith/workers/reminder_email_worker.ex`
- Create: `test/kith/reminders/dispatcher_test.exs`
- Create: `test/kith/workers/reminder_email_worker_test.exs`
- Modify: `config/config.exs`, `config/runtime.exs` (add the cron line)

**Interfaces:**
- Consumes: `Reminder.schedule/1`, `Reminder.advance_changeset/2`, `ReminderInstance.create_changeset/2` (Task 2); `Occurrences.advance_after/2`, `TimeHelper.local_date_hour/2` (Task 1); `Kith.Reminders.has_pending_instance?/1`, `dismiss_instance/1`.
- Produces: `Kith.Reminders.Dispatcher.run(DateTime.t()) :: :ok`; `Kith.Reminders.Dispatcher.advance_days_before(Date.t(), Date.t(), [pos_integer()]) :: pos_integer() | nil`; worker `Kith.Workers.ReminderEmailWorker` with args `%{"instance_id" => integer}`; cron worker `Kith.Workers.ReminderDispatcher`.

- [ ] **Step 1: Write the failing dispatcher tests**

Create `test/kith/reminders/dispatcher_test.exs`:

```elixir
defmodule Kith.Reminders.DispatcherTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, Reminder, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  setup do
    user = user_fixture()
    Reminders.seed_default_rules(user.account_id)
    contact = contact_fixture(user.account_id)
    today = Date.utc_today()

    %{
      user: user,
      account_id: user.account_id,
      contact: contact,
      today: today,
      # Accounts default to Etc/UTC with send_hour 9.
      after_send: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      before_send: DateTime.new!(today, ~T[08:00:00], "Etc/UTC")
    }
  end

  defp create!(ctx, attrs) do
    {:ok, r} =
      Reminders.create_reminder(
        ctx.account_id,
        ctx.user.id,
        Map.merge(%{title: "R", contact_id: ctx.contact.id}, attrs)
      )

    r
  end

  defp instances(reminder),
    do: Repo.all(from i in ReminderInstance, where: i.reminder_id == ^reminder.id, order_by: i.id)

  defp set_next!(reminder, date) do
    Repo.update_all(from(r in Reminder, where: r.id == ^reminder.id),
      set: [next_reminder_date: date]
    )
  end

  test "a recurring reminder due today is sent once and advances", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "weekly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "on_day", days_before: 0, status: "pending"} = i] = instances(r)
    assert i.occurrence_date == ctx.today
    assert_enqueued(worker: ReminderEmailWorker, args: %{instance_id: i.id})
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, 7)

    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 3600))
    assert length(instances(r)) == 1
  end

  test "nothing is sent before the account's send hour", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "weekly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.before_send)

    assert instances(r) == []
    refute_enqueued(worker: ReminderEmailWorker)
  end

  test "missed periods send one notice and jump to the next future occurrence", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "weekly", anchor_date: Date.add(ctx.today, -21)})
    set_next!(r, Date.add(ctx.today, -21))

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [_one] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, 7)
  end

  test "a one-time reminder in the past is sent once and never again", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, -10)})

    assert :ok = Dispatcher.run(ctx.after_send)
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 86_400))

    assert [%{kind: "on_day"}] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, -10)
  end

  test "only the nearest advance-notice window sends (5 days out → the 7-day notice)", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "advance", days_before: 7}] = instances(r)
  end

  test "20 days out sends the 30-day notice", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 20)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "advance", days_before: 30}] = instances(r)
  end

  test "recurring reminders get no advance notices", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "monthly", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(r) == []
  end

  test "a deactivated rule sends no advance notice", ctx do
    seven = Enum.find(Reminders.list_reminder_rules(ctx.account_id), &(&1.days_before == 7))
    {:ok, _} = Reminders.update_reminder_rule(seven, %{active: false})
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(r) == []
  end

  test "stay-in-touch waits while an instance is pending, and dismiss re-arms it", ctx do
    r = create!(ctx, %{type: "stay_in_touch", frequency: "monthly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)
    assert [pending] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == ctx.today

    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 86_400))
    assert length(instances(r)) == 1

    {:ok, _} = Reminders.dismiss_instance(pending)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.shift(ctx.today, month: 1)
  end

  test "a deceased contact's birthday is dismissed, not emailed, and advanced", ctx do
    {:ok, contact} = Kith.Contacts.update_contact(ctx.contact, %{deceased: true})
    r = create!(%{ctx | contact: contact}, %{type: "birthday", title: nil, frequency: "annually", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{status: "dismissed"}] = instances(r)
    refute_enqueued(worker: ReminderEmailWorker)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.shift(ctx.today, year: 1)
  end

  test "soft-deleted and archived contacts are skipped", ctx do
    archived = contact_fixture(ctx.account_id)
    {:ok, archived} = Kith.Contacts.archive_contact(archived)
    deleted = contact_fixture(ctx.account_id)
    {:ok, deleted} = Kith.Contacts.soft_delete_contact(deleted)

    a = create!(%{ctx | contact: archived}, %{type: "one_time", anchor_date: ctx.today})
    d = create!(%{ctx | contact: deleted}, %{type: "one_time", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(a) == []
    assert instances(d) == []
  end

  test "an ended snooze sends again and returns to pending", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: ctx.today})
    assert :ok = Dispatcher.run(ctx.after_send)
    [i] = instances(r)

    Repo.update_all(from(x in ReminderInstance, where: x.id == ^i.id),
      set: [status: "snoozed", snoozed_until: DateTime.add(ctx.after_send, 60)]
    )

    Repo.delete_all(Oban.Job)
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 120))

    assert %{status: "pending", snoozed_until: nil} = Repo.get!(ReminderInstance, i.id)
    assert_enqueued(worker: ReminderEmailWorker, args: %{instance_id: i.id})
  end

  test "uses the account's local date in a timezone ahead of UTC", ctx do
    Repo.update_all(from(a in Kith.Accounts.Account, where: a.id == ^ctx.account_id),
      set: [timezone: "Pacific/Kiritimati"]
    )

    tomorrow = Date.add(ctx.today, 1)
    r = create!(ctx, %{type: "one_time", anchor_date: tomorrow})

    # 20:00 UTC today is 10:00 tomorrow in Kiritimati (UTC+14): due there.
    assert :ok = Dispatcher.run(DateTime.new!(ctx.today, ~T[20:00:00], "Etc/UTC"))

    assert [%{occurrence_date: ^tomorrow, kind: "on_day"}] = instances(r)
  end

  test "editing a reminder after today's notice does not send it again", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: ctx.today})
    assert :ok = Dispatcher.run(ctx.after_send)

    {:ok, _} = Reminders.update_reminder(Repo.get!(Reminder, r.id), %{title: "Renamed"})
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 3600))

    assert length(instances(r)) == 1
  end

  describe "advance_days_before/3" do
    test "picks the rule whose window contains today" do
      next = ~D[2026-10-31]
      assert Dispatcher.advance_days_before(next, ~D[2026-10-26], [30, 7]) == 7
      assert Dispatcher.advance_days_before(next, ~D[2026-10-24], [30, 7]) == 7
      assert Dispatcher.advance_days_before(next, ~D[2026-10-23], [30, 7]) == 30
      assert Dispatcher.advance_days_before(next, ~D[2026-10-01], [30, 7]) == 30
      assert Dispatcher.advance_days_before(next, ~D[2026-09-30], [30, 7]) == nil
      assert Dispatcher.advance_days_before(next, ~D[2026-10-31], [30, 7]) == nil
      assert Dispatcher.advance_days_before(next, ~D[2026-10-26], []) == nil
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/dispatcher_test.exs`
Expected: FAIL, `module Kith.Reminders.Dispatcher is not available`.

- [ ] **Step 3: Implement the dispatcher**

Create `lib/kith/reminders/dispatcher.ex`:

```elixir
defmodule Kith.Reminders.Dispatcher do
  @moduledoc """
  Sends every reminder notice that is due, exactly once. Called hourly by
  `Kith.Workers.ReminderDispatcher`; `run/1` takes `now` so tests control time.

  For each account whose local hour has reached `send_hour`:
  - the on-day notice when `next_reminder_date <= local today` (catch-up
    included); stay-in-touch waits while it has a pending instance;
  - at most one advance notice per birthday/one-time reminder, chosen by
    `advance_days_before/3` from the account's active rules.
  Snoozed instances whose `snoozed_until` has passed are sent again.

  Each notice is a `ReminderInstance`; the unique index on
  (reminder_id, occurrence_date, days_before) turns retries and overlapping
  runs into no-ops. The email is a `ReminderEmailWorker` job inserted in the
  same transaction.
  """

  import Ecto.Query
  require Logger

  alias Kith.Accounts.Account
  alias Kith.Reminders.{Occurrences, Reminder, ReminderInstance, ReminderRule}
  alias Kith.{Repo, TimeHelper}
  alias Kith.Workers.ReminderEmailWorker

  @advance_types ~w(birthday one_time)
  @advancing_types ~w(birthday recurring)

  @spec run(DateTime.t()) :: :ok
  def run(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Account
    |> Repo.all()
    |> Enum.each(fn account ->
      safely("account #{account.id}", fn -> dispatch_account(account, now) end)
    end)

    wake_snoozed(now)
    :ok
  end

  @doc """
  The advance notice (`days_before`) due `today` for an occurrence on `next`,
  or nil. Each rule's window runs from `next - days_before` up to the next
  smaller rule, so only the nearest window notifies: 5 days out gets the
  7-day notice, never a stale 30-day one.
  """
  @spec advance_days_before(Date.t(), Date.t(), [pos_integer()]) :: pos_integer() | nil
  def advance_days_before(next, today, rule_days) do
    days_until = Date.diff(next, today)

    rule_days
    |> Enum.sort(:desc)
    |> Enum.chunk_every(2, 1, [0])
    |> Enum.find_value(fn [days, smaller] ->
      if days_until <= days and days_until > smaller, do: days
    end)
  end

  defp dispatch_account(%Account{} = account, now) do
    {today, hour} = TimeHelper.local_date_hour(now, account.timezone)

    if hour >= account.send_hour do
      rule_days = advance_rule_days(account.id)
      horizon = Date.add(today, Enum.max(rule_days, fn -> 0 end))

      account.id
      |> due_reminders(horizon)
      |> Enum.each(fn reminder ->
        safely("reminder #{reminder.id}", fn -> dispatch_reminder(reminder, today, rule_days, now) end)
      end)
    end
  end

  defp advance_rule_days(account_id) do
    from(r in ReminderRule,
      where: r.account_id == ^account_id and r.active == true and r.days_before > 0,
      select: r.days_before
    )
    |> Repo.all()
  end

  defp due_reminders(account_id, horizon) do
    from(r in Reminder,
      join: c in assoc(r, :contact),
      where: r.account_id == ^account_id and r.active == true,
      where: r.next_reminder_date <= ^horizon,
      where: is_nil(c.deleted_at) and c.is_archived == false,
      preload: [contact: c]
    )
    |> Repo.all()
  end

  defp dispatch_reminder(reminder, today, rule_days, now) do
    cond do
      Date.compare(reminder.next_reminder_date, today) != :gt ->
        send_on_day(reminder, today, now)

      reminder.type in @advance_types ->
        case advance_days_before(reminder.next_reminder_date, today, rule_days) do
          nil -> :not_due
          days -> send_notice(reminder, "advance", days, today, now)
        end

      true ->
        :not_due
    end
  end

  defp send_on_day(%Reminder{type: "stay_in_touch"} = reminder, today, now) do
    if Kith.Reminders.has_pending_instance?(reminder.id),
      do: :waiting,
      else: send_notice(reminder, "on_day", 0, today, now)
  end

  defp send_on_day(reminder, today, now), do: send_notice(reminder, "on_day", 0, today, now)

  defp send_notice(reminder, kind, days_before, today, now) do
    deceased? = reminder.contact.deceased

    attrs = %{
      reminder_id: reminder.id,
      account_id: reminder.account_id,
      contact_id: reminder.contact_id,
      occurrence_date: reminder.next_reminder_date,
      kind: kind,
      days_before: days_before,
      status: if(deceased?, do: "dismissed", else: "pending"),
      scheduled_for: now,
      fired_at: now
    }

    Repo.transaction(fn ->
      %ReminderInstance{}
      |> ReminderInstance.create_changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:reminder_id, :occurrence_date, :days_before]
      )
      |> case do
        {:ok, %ReminderInstance{id: nil}} ->
          :already_sent

        {:ok, instance} ->
          if kind == "on_day", do: advance(reminder, today)
          unless deceased?, do: Oban.insert!(ReminderEmailWorker.new(%{instance_id: instance.id}))
          :sent

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # Advance past *today*, not just past the fired occurrence: after missed
  # periods this sends one notice and resumes at the next future date.
  defp advance(%Reminder{type: type} = reminder, today) when type in @advancing_types do
    next = Occurrences.advance_after(Reminder.schedule(reminder), today)
    reminder |> Reminder.advance_changeset(next) |> Repo.update!()
  end

  defp advance(_reminder, _today), do: :ok

  defp wake_snoozed(now) do
    from(i in ReminderInstance,
      join: r in assoc(i, :reminder),
      join: c in assoc(i, :contact),
      where: i.status == "snoozed" and i.snoozed_until <= ^now,
      where: r.active == true and is_nil(c.deleted_at),
      select: i.id
    )
    |> Repo.all()
    |> Enum.each(fn instance_id ->
      safely("snoozed instance #{instance_id}", fn -> wake(instance_id, now) end)
    end)
  end

  # Conditional update so two overlapping runs can't both re-send.
  defp wake(instance_id, now) do
    Repo.transaction(fn ->
      {count, _} =
        from(i in ReminderInstance, where: i.id == ^instance_id and i.status == "snoozed")
        |> Repo.update_all(set: [status: "pending", fired_at: now, snoozed_until: nil])

      if count == 1, do: Oban.insert!(ReminderEmailWorker.new(%{instance_id: instance_id}))
    end)
  end

  defp safely(label, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "[ReminderDispatcher] #{label} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end
end
```

- [ ] **Step 4: Implement the email worker and the cron worker**

Create `lib/kith/workers/reminder_email_worker.ex`:

```elixir
defmodule Kith.Workers.ReminderEmailWorker do
  @moduledoc """
  Sends the email for one `ReminderInstance` to the reminder's creator.

  Inserted by `Kith.Reminders.Dispatcher` in the same transaction that records
  the instance, so a retry only resends the email and never creates another
  instance. After the final attempt fails, the instance is marked `failed`.
  """

  use Oban.Worker, queue: :reminders, max_attempts: 3

  require Logger

  alias Kith.Accounts.User
  alias Kith.Reminders.ReminderInstance
  alias Kith.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id}, attempt: attempt, max_attempts: max}) do
    case ReminderInstance |> Repo.get(id) |> Repo.preload(reminder: :contact) do
      nil -> {:discard, "instance deleted"}
      instance -> deliver(instance, attempt >= max)
    end
  end

  defp deliver(instance, last_attempt?) do
    reminder = instance.reminder

    case Repo.get(User, reminder.creator_id) do
      %User{} = creator ->
        case Kith.Mailer.deliver(build_email(creator, instance)) do
          {:ok, _} ->
            audit(instance, nil)
            :ok

          {:error, reason} ->
            audit(instance, reason)
            if last_attempt?, do: instance |> ReminderInstance.fail_changeset() |> Repo.update!()
            {:error, reason}
        end

      nil ->
        Logger.warning("[ReminderEmailWorker] reminder #{reminder.id} has no creator; not emailing")
        :ok
    end
  end

  defp build_email(%User{} = creator, instance) do
    reminder = instance.reminder
    contact = reminder.contact
    name = contact.display_name || contact.first_name
    subject = subject(reminder.type, instance.kind, instance.days_before, name, reminder.title)

    Swoosh.Email.new()
    |> Swoosh.Email.to({creator.email, creator.email})
    |> Swoosh.Email.from(
      {"Kith", Application.get_env(:kith, Kith.Mailer)[:from] || "noreply@localhost"}
    )
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body("#{subject}\n\nContact: #{name}")
  end

  defp subject("birthday", "on_day", _days, name, _title), do: "#{name}'s birthday is today"
  defp subject("birthday", "advance", days, name, _title), do: "#{name}'s birthday is in #{days} days"
  defp subject("stay_in_touch", _kind, _days, name, _title), do: "Time to reach out to #{name}"
  defp subject("one_time", "advance", days, _name, title), do: "Reminder in #{days} days: #{title}"
  defp subject(_type, _kind, _days, _name, title), do: "Reminder: #{title || "Untitled"}"

  defp audit(instance, error) do
    reminder = instance.reminder
    metadata = %{reminder_id: reminder.id, instance_id: instance.id, type: instance.kind}
    metadata = if error, do: Map.put(metadata, :delivery_error, inspect(error)), else: metadata

    Kith.AuditLogs.create_audit_log(reminder.account_id, %{
      user_id: nil,
      user_name: "system",
      event: "reminder_fired",
      contact_id: reminder.contact_id,
      contact_name: reminder.contact.display_name,
      metadata: metadata
    })
  end
end
```

Create `lib/kith/workers/reminder_dispatcher.ex`:

```elixir
defmodule Kith.Workers.ReminderDispatcher do
  @moduledoc "Hourly cron entry point for `Kith.Reminders.Dispatcher.run/1`."

  use Oban.Worker, queue: :reminders, unique: [period: 3_000]

  @impl Oban.Worker
  def perform(_job), do: Kith.Reminders.Dispatcher.run(DateTime.utc_now())
end
```

Add `{"0 * * * *", Kith.Workers.ReminderDispatcher},` as the first entry of the crontab in **both** `config/config.exs` and `config/runtime.exs` (where the scheduler line was).

- [ ] **Step 5: Write the email worker tests**

Create `test/kith/workers/reminder_email_worker_test.exs`:

```elixir
defmodule Kith.Workers.ReminderEmailWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Swoosh.TestAssertions
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  setup do
    user = user_fixture()
    contact = contact_fixture(user.account_id, %{first_name: "Mona", display_name: "Mona Vale"})

    {:ok, reminder} =
      Reminders.create_reminder(user.account_id, user.id, %{
        type: "one_time",
        title: "Call Mona",
        anchor_date: Date.utc_today(),
        contact_id: contact.id
      })

    :ok = Dispatcher.run(DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"))
    [instance] = Repo.all(from i in ReminderInstance, where: i.reminder_id == ^reminder.id)

    %{user: user, instance: instance}
  end

  test "emails the reminder's creator", %{user: user, instance: instance} do
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id})

    assert_email_sent(fn email ->
      assert email.to == [{user.email, user.email}]
      assert email.subject == "Reminder: Call Mona"
    end)
  end

  test "a retried job never creates another instance", %{instance: instance} do
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id})
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 2)

    assert Repo.aggregate(from(i in ReminderInstance, where: i.reminder_id == ^instance.reminder_id), :count) ==
             1
  end

  test "discards a job whose instance is gone", %{instance: instance} do
    Repo.delete!(instance)
    assert {:discard, _} = perform_job(ReminderEmailWorker, %{instance_id: instance.id})
  end
end
```

(A test for "creator missing" isn't possible: `reminders.creator_id` is NOT NULL with an `on_delete: :nothing` FK, so the creator can't disappear. The guard in `deliver/2` is defensive only.)

- [ ] **Step 6: Run the new tests, then the full suite**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/dispatcher_test.exs test/kith/workers/reminder_email_worker_test.exs` → 0 failures.
Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures. Run `mix compile --warnings-as-errors` → clean.

- [ ] **Step 7: Commit**

```bash
git add lib/kith/reminders/dispatcher.ex lib/kith/workers/reminder_dispatcher.ex lib/kith/workers/reminder_email_worker.ex test/kith/reminders/dispatcher_test.exs test/kith/workers/reminder_email_worker_test.exs config/config.exs config/runtime.exs
git commit -m "feat(reminders): hourly dispatcher with an idempotent instance ledger" -m "Sends on-day and advance notices at each account's local send hour, catches up missed runs once, re-sends ended snoozes, and advances recurring/birthday reminders after they fire. Emails go to the reminder's creator via ReminderEmailWorker."
```

---

### Task 4: Birthday reminders synced from the contact's birthdate

**Files:**
- Modify: `lib/kith/reminders.ex` (add `sync_birthday/1`; delete `create_birthday_reminder/2` and `delete_birthday_reminder/2`)
- Modify: `lib/kith/contacts.ex` (`create_contact/2`, `update_contact/2`)
- Modify: `lib/kith/contacts/merge.ex` (`remap_birthday_reminders_step/4`)
- Modify tests: `test/kith/reminders_test.exs`, `test/kith/contacts_merge_test.exs`
- Create: `test/kith/reminders/birthday_sync_test.exs`

**Interfaces:**
- Consumes: `create_reminder/3`, `update_reminder/2`, `delete_reminder/1`, `get_birthday_reminder/2` (Task 2).
- Produces: `Kith.Reminders.sync_birthday(%Kith.Contacts.Contact{}) :: {:ok, Reminder.t() | :none} | {:error, term()}`.

- [ ] **Step 1: Write the failing tests**

Create `test/kith/reminders/birthday_sync_test.exs`:

```elixir
defmodule Kith.Reminders.BirthdaySyncTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Reminders}
  alias Kith.Reminders.Occurrences

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  test "creating a contact with a birthdate creates its birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

    r = Reminders.get_birthday_reminder(contact.id, ctx.account_id)
    assert %{type: "birthday", anchor_date: ~D[1990-06-15], interval_unit: "year", interval_count: 1} = r
    assert r.creator_id == ctx.user.id
    assert r.next_reminder_date == Occurrences.next_on_or_after(Kith.Reminders.Reminder.schedule(r), Date.utc_today())
  end

  test "changing the birthdate re-anchors the same reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})
    before = Reminders.get_birthday_reminder(contact.id, ctx.account_id)

    {:ok, contact} = Contacts.update_contact(contact, %{birthdate: ~D[1990-12-01]})

    after_change = Reminders.get_birthday_reminder(contact.id, ctx.account_id)
    assert after_change.id == before.id
    assert after_change.anchor_date == ~D[1990-12-01]
  end

  test "removing the birthdate deletes the birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

    {:ok, contact} = Contacts.update_contact(contact, %{birthdate: nil})

    assert Reminders.get_birthday_reminder(contact.id, ctx.account_id) == nil
  end

  test "a contact without a birthdate gets no birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id)
    assert Reminders.get_birthday_reminder(contact.id, ctx.account_id) == nil
  end

  test "a Feb 29 birthdate falls back to Feb 28 in non-leap years", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1992-02-29]})
    r = Reminders.get_birthday_reminder(contact.id, ctx.account_id)

    assert Occurrences.next_on_or_after(Kith.Reminders.Reminder.schedule(r), ~D[2027-01-01]) ==
             ~D[2027-02-28]
  end
end
```

In `test/kith/reminders_test.exs`, replace the test `"delete_birthday_reminder is safe when none exists"` with:

```elixir
    test "sync_birthday is a no-op for a contact without a birthdate", %{contact: contact} do
      assert {:ok, :none} = Reminders.sync_birthday(contact)
    end
```

(If this file's `contact` fixture has a birthdate, create one without it via `contact_fixture(account_id)` inside the test.)

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/birthday_sync_test.exs`
Expected: FAIL (no birthday reminder is created; `sync_birthday/1` is undefined).

- [ ] **Step 3: Implement `sync_birthday/1`**

In `lib/kith/reminders.ex`, replace `create_birthday_reminder/2` and `delete_birthday_reminder/2` (with their `@doc`s) with:

```elixir
  @doc """
  Makes the contact's birthday reminder match its birthdate: creates it when a
  birthdate is set, re-anchors it when the birthdate changes, deletes it when
  the birthdate is removed. The reminder belongs to the account owner (design
  spec §6). An existing reminder's `active` flag is left as it is.
  """
  def sync_birthday(%Kith.Contacts.Contact{} = contact) do
    case {contact.birthdate, get_birthday_reminder(contact.id, contact.account_id)} do
      {nil, nil} ->
        {:ok, :none}

      {nil, %Reminder{} = reminder} ->
        with {:ok, _} <- delete_reminder(reminder), do: {:ok, :none}

      {%Date{} = birthdate, nil} ->
        case account_owner_id(contact.account_id) do
          nil ->
            {:error, :no_account_owner}

          owner_id ->
            create_reminder(contact.account_id, owner_id, %{
              type: "birthday",
              title: nil,
              anchor_date: birthdate,
              interval_unit: "year",
              interval_count: 1,
              contact_id: contact.id
            })
        end

      {%Date{} = birthdate, %Reminder{} = reminder} ->
        update_reminder(reminder, %{anchor_date: birthdate})
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
```

- [ ] **Step 4: Hook it into Contacts**

In `lib/kith/contacts.ex`, replace `create_contact/2` and `update_contact/2` with:

```elixir
  def create_contact(account_id, attrs) do
    %Contact{account_id: account_id}
    |> Contact.create_changeset(attrs)
    |> Repo.insert()
    |> sync_birthday_if_changed(nil)
  end

  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.update_changeset(attrs)
    |> Repo.update()
    |> sync_birthday_if_changed(contact.birthdate)
  end

  # Every path that sets or clears a birthdate (UI, REST API, CardDAV, the
  # Monica importer) goes through create_contact/2 or update_contact/2.
  defp sync_birthday_if_changed({:ok, %Contact{birthdate: new} = contact} = result, old)
       when new != old do
    case Kith.Reminders.sync_birthday(contact) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Contacts] birthday reminder sync failed for contact #{contact.id}: #{inspect(reason)}"
        )
    end

    result
  end

  defp sync_birthday_if_changed(result, _old), do: result
```

Add `require Logger` near the top of `Kith.Contacts` if it isn't required at module level (today it's only required inside two functions, at lines ~1206 and ~1646).

- [ ] **Step 5: Use it in the merge**

In `lib/kith/contacts/merge.ex`, replace `remap_birthday_reminders_step/4`, `resync_birthday_reminder/4` (both clauses) and `delete_extra_birthday_reminders/3`, plus the comment block above `resync_birthday_reminder`, with:

```elixir
  defp remap_birthday_reminders_step(repo, survivor, loser_ids, _account_id) do
    all_ids = [survivor.id | loser_ids]

    %{rows: rows} =
      repo.query!(
        "SELECT id, contact_id FROM reminders WHERE type = 'birthday' AND contact_id = ANY($1)",
        [all_ids]
      )

    if rows != [] do
      keep_id = reminder_keep_id(rows, survivor.id)
      delete_ids = for [id, _contact_id] <- rows, id != keep_id, do: id

      if delete_ids != [],
        do: repo.query!("DELETE FROM reminders WHERE id = ANY($1)", [delete_ids])

      # Move the kept reminder onto the survivor before syncing, so
      # sync_birthday/1 finds it instead of creating a second one.
      repo.update_all(from(r in Kith.Reminders.Reminder, where: r.id == ^keep_id),
        set: [contact_id: survivor.id]
      )
    end

    case Kith.Reminders.sync_birthday(survivor) do
      {:ok, _} -> {:ok, :done}
      {:error, reason} -> {:error, reason}
    end
  end
```

Keep the comment block that sits directly above `remap_birthday_reminders_step`, but replace its last paragraph (starting `The kept reminder is then re-dated from the *merged* birthdate`) with: `The kept reminder is then synced to the *merged* birthdate via Reminders.sync_birthday/1 (deleted if the merge leaves no birthdate).`

- [ ] **Step 6: Update the merge tests for the new behaviour**

In `test/kith/contacts_merge_test.exs`:

1. `"the surviving birthday reminder matches the merged birthdate"`: the fixtures now create birthday reminders automatically. Replace the two lines calling `Kith.Reminders.create_birthday_reminder(...)` with:

```elixir
      survivor_reminder = Kith.Reminders.get_birthday_reminder(survivor.id, ctx.account_id)
```

   and keep the remaining assertions.

2. Replace the test `"clearing the birthdate leaves the surviving birthday reminder alone"` (whole test, including its comment) with:

```elixir
    test "clearing the birthdate removes the birthday reminder", ctx do
      survivor =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-01-05]
        })

      loser = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Alice"})

      assert Kith.Reminders.get_birthday_reminder(survivor.id, ctx.account_id)

      assert {:ok, merged} =
               Contacts.merge_cluster(ctx.scope, survivor.id, [loser.id], %{
                 fields: %{birthdate: :clear, birthdate_year_unknown: false},
                 drop: %{}
               })

      assert is_nil(merged.birthdate)
      assert Kith.Reminders.get_birthday_reminder(merged.id, ctx.account_id) == nil
    end
```

3. Search the file for any other `create_birthday_reminder` call and replace it with `get_birthday_reminder(contact.id, ctx.account_id)` for a contact created with a birthdate.

- [ ] **Step 7: Run the tests**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/reminders/birthday_sync_test.exs test/kith/contacts_merge_test.exs test/kith/reminders_test.exs` → 0 failures.
Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures. If a test creates a contact **with** a birthdate and then calls `birthday_reminder_fixture/4` for it, it now hits `reminders_birthday_unique_idx`; switch that test to `get_birthday_reminder/2`.

- [ ] **Step 8: Commit**

```bash
git add lib/kith/reminders.ex lib/kith/contacts.ex lib/kith/contacts/merge.ex test
git commit -m "feat(reminders): derive birthday reminders from the contact's birthdate"
```

---

### Task 5: Seed default reminder rules at signup

**Why:** verified 2026-09-26: nothing calls `Reminders.seed_default_rules/1`, so a freshly registered account has 0 rules. Settings → Account shows an empty list, and advance notices never exist. `Kith.Reminders.Cleanup`'s moduledoc already assumes "3 defaults seeded per account".

**Files:**
- Modify: `lib/kith/accounts.ex` (`register_user/1`, `register_oauth_user/4`)
- Create: `test/kith/accounts/reminder_rules_seeding_test.exs`

**Interfaces:**
- Consumes: `Kith.Reminders.seed_default_rules(account_id) :: {count, nil}` (unchanged, `on_conflict: :nothing`).

- [ ] **Step 1: Write the failing test**

Create `test/kith/accounts/reminder_rules_seeding_test.exs`:

```elixir
defmodule Kith.Accounts.ReminderRulesSeedingTest do
  use Kith.DataCase, async: true

  alias Kith.{Accounts, Reminders}

  test "email signup seeds the 0/7/30-day reminder rules" do
    {:ok, user} =
      Accounts.register_user(%{
        email: "seed#{System.unique_integer([:positive])}@example.com",
        password: "hello world!!",
        name: "Seed",
        tos_accepted: true
      })

    assert Enum.map(Reminders.list_reminder_rules(user.account_id), & &1.days_before) == [0, 7, 30]
  end

  test "OAuth signup seeds the same rules" do
    {:ok, user} =
      Accounts.register_oauth_user(
        "github",
        "uid-#{System.unique_integer([:positive])}",
        %{"email" => "oauth#{System.unique_integer([:positive])}@example.com", "name" => "OAuth"},
        %{access_token: "token"}
      )

    assert Enum.map(Reminders.list_reminder_rules(user.account_id), & &1.days_before) == [0, 7, 30]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/accounts/reminder_rules_seeding_test.exs`
Expected: FAIL (`[] == [0, 7, 30]`).

- [ ] **Step 3: Seed in both signup transactions**

In `lib/kith/accounts.ex`, in **both** `register_user/1` and `register_oauth_user/4`, add this step directly after the `Ecto.Multi.insert(:account, ...)` step:

```elixir
    |> Ecto.Multi.run(:reminder_rules, fn _repo, %{account: account} ->
      {count, _} = Kith.Reminders.seed_default_rules(account.id)
      {:ok, count}
    end)
```

- [ ] **Step 4: Run the test and the full suite**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith/accounts/reminder_rules_seeding_test.exs` → 0 failures.
Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures. (Existing tests that also call `seed_default_rules/1` stay green: it uses `on_conflict: :nothing`. `"create_reminder_rule adds new rule"` uses `days_before: 14`, which isn't a default.)

- [ ] **Step 5: Commit**

```bash
git add lib/kith/accounts.ex test/kith/accounts/reminder_rules_seeding_test.exs
git commit -m "fix(accounts): seed default reminder rules at signup"
```

---

### Task 6: REST API and UI compatibility

**Files:**
- Modify: `lib/kith_web/controllers/api/reminder_controller.ex`
- Modify: `lib/kith_web/controllers/api/contact_json.ex` (`reminder/1`)
- Modify: `lib/kith_web/live/contact_live/reminders_component.ex`
- Modify tests: `test/kith_web/controllers/api/reminder_controller_test.exs`

**Interfaces:**
- Consumes: `Reminder.frequency_preset/1`, `Reminder.interval_label/1` (Task 2).

- [ ] **Step 1: Write the failing controller tests**

Append inside the test module in `test/kith_web/controllers/api/reminder_controller_test.exs`. Use the module's existing `setup` names for the authenticated `conn` and the `contact`; if they differ, adapt the variable names, not the assertions.

```elixir
  describe "schedule fields" do
    test "create accepts a preset and returns interval fields", %{conn: conn, contact: contact} do
      conn =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{
            "type" => "recurring",
            "title" => "Rent",
            "frequency" => "monthly",
            "anchor_date" => "2024-02-01"
          }
        })

      data = json_response(conn, 201)["data"]
      assert data["frequency"] == "monthly"
      assert data["interval_unit"] == "month"
      assert data["interval_count"] == 1
      assert data["anchor_date"] == "2024-02-01"
      assert Date.compare(Date.from_iso8601!(data["next_reminder_date"]), Date.utc_today()) != :lt
    end

    test "create accepts unit + count outside the presets", %{conn: conn, contact: contact} do
      conn =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{
            "type" => "recurring",
            "title" => "Every 3 weeks",
            "interval_unit" => "week",
            "interval_count" => 3,
            "anchor_date" => Date.to_iso8601(Date.utc_today())
          }
        })

      data = json_response(conn, 201)["data"]
      assert data["frequency"] == nil
      assert {data["interval_unit"], data["interval_count"]} == {"week", 3}
    end

    test "birthday reminders can't be created, edited or deleted", %{conn: conn, contact: contact} do
      conn1 =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{"type" => "birthday", "anchor_date" => "1990-06-15"}
        })

      assert json_response(conn1, 422)

      {:ok, contact} = Kith.Contacts.update_contact(contact, %{birthdate: ~D[1990-06-15]})
      birthday = Kith.Reminders.get_birthday_reminder(contact.id, contact.account_id)

      conn2 = patch(conn, ~p"/api/reminders/#{birthday.id}", %{"reminder" => %{"title" => "x"}})
      assert json_response(conn2, 422)

      conn3 = delete(conn, ~p"/api/reminders/#{birthday.id}")
      assert json_response(conn3, 422)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith_web/controllers/api/reminder_controller_test.exs`
Expected: FAIL (missing `interval_unit` in the response; birthday create returns 201).

- [ ] **Step 3: Update the controller and contact JSON**

In `lib/kith_web/controllers/api/reminder_controller.ex`:

1. In `create/2`, add a birthday guard as the first `with` clause:

```elixir
    with :ok <- reject_birthday(attrs["type"]),
         true <- Policy.can?(user, :create, :reminder),
```

   and add `{:error, 422, detail} -> {:error, 422, detail}` to its `else` block.
2. In `update/2`, after `reminder when not is_nil(reminder) <- fetch_reminder(account_id, id),` add `:ok <- reject_birthday(reminder.type),`, and add `{:error, 422, detail} -> {:error, 422, detail}` to its `else`.
3. In `delete/2`, after `reminder when not is_nil(reminder) <- fetch_reminder(account_id, id)` add `, :ok <- reject_birthday(reminder.type)` inside the `with`, and add `{:error, 422, detail} -> {:error, 422, detail}` to its `else`.
4. Add the helper:

```elixir
  # Birthday reminders are derived from the contact's birthdate.
  defp reject_birthday("birthday"),
    do: {:error, 422, "Birthday reminders are managed from the contact's birthdate."}

  defp reject_birthday(_type), do: :ok
```

5. Replace `reminder_json/1` with:

```elixir
  defp reminder_json(%Reminder{} = r) do
    %{
      id: r.id,
      contact_id: r.contact_id,
      type: r.type,
      title: r.title,
      anchor_date: r.anchor_date,
      interval_unit: r.interval_unit,
      interval_count: r.interval_count,
      frequency: Reminder.frequency_preset(r),
      next_reminder_date: r.next_reminder_date,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end
```

In `lib/kith_web/controllers/api/contact_json.ex`, make `reminder/1` return the same map (replace `frequency: r.frequency,` with the four lines `anchor_date: …`, `interval_unit: …`, `interval_count: …`, `frequency: Reminder.frequency_preset(r),`). Add `alias Kith.Reminders.Reminder` if it's missing.

- [ ] **Step 4: Update the LiveView component**

In `lib/kith_web/live/contact_live/reminders_component.ex`:

1. In the form, change the date input's `name="reminder[next_reminder_date]"` to `name="reminder[anchor_date]"` and its label text to `First date`.
2. In the list, replace:

```heex
                  <span :if={reminder.frequency}>
                    &middot; {frequency_label(reminder.frequency)}
```

   with:

```heex
                  <span :if={Kith.Reminders.Reminder.interval_label(reminder)}>
                    &middot; {Kith.Reminders.Reminder.interval_label(reminder)}
```

3. Delete all `frequency_label/1` clauses.

- [ ] **Step 5: Run the tests**

Run: `MIX_TEST_PARTITION=_rd mix test test/kith_web` → 0 failures.
Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/kith_web test/kith_web
git commit -m "feat(api): expose reminder schedules; birthday reminders are read-only"
```

---

### Task 7: Final verification (no push)

**Files:** none new (fix whatever the checks find).

- [ ] **Step 1: Quality gates**

Run: `MIX_TEST_PARTITION=_rd mix test` → 0 failures.
Run: `mix quality` → passes (this is what the pre-commit hook runs).

- [ ] **Step 2: Runtime check against a dev server**

1. Temporarily point `config/dev.exs` at a throwaway DB (`database: "kith_rd_check"`; **never commit this edit**), copy `assets/vendor/heroicons.js` from the main checkout's `assets/vendor/`, and run `mix ecto.setup` and `mix assets.build`. If `mix assets.setup` fails with `:eacces` on Windows, run `npm install` inside `assets/` directly.
2. Start the server as a named node: `PORT=4040 elixir --sname rdcheck --cookie rdcheck -S mix phx.server`.
3. Register a user in the browser. Check **Settings → Account** lists the 0/7/30-day rules. Create a contact with a birthdate and check it shows a birthday reminder. Add a weekly reminder whose first date is today through the contact's reminder form.
4. From a second node, switch the mailer to the local adapter and run the dispatcher with a controlled clock:

```elixir
{:ok, h} = :inet.gethostname(); n = :"rdcheck@#{h}"; true = Node.connect(n)
:rpc.call(n, Application, :put_env, [:kith, Kith.Mailer, [adapter: Swoosh.Adapters.Local]])
:rpc.call(n, Kith.Reminders.Dispatcher, :run, [DateTime.new!(Date.utc_today(), ~T[23:00:00], "Etc/UTC")])
```

   Then drain or wait for the `reminders` queue, and confirm:
   - the weekly reminder's `next_reminder_date` is now today + 7
   - one instance exists, with an email in `/dev/mailbox`
   - a second `run` adds nothing
5. Stop the node with `:rpc.call(n, :init, :stop, [])`. Drop the DB with `mix ecto.drop`, then revert `config/dev.exs` with `git checkout -- config/dev.exs` (the drop reads the DB name from the edited file) and delete the copied `heroicons.js`. **If deletions are permission-blocked, ask the user to run them.**

- [ ] **Step 3: Hand back**

Report to the user:
- the branch and its commits
- the test count
- the runtime-check results
- the one addition beyond the spec (Task 5, rule seeding) and why

**Do not push or open a PR.**

---

## Self-review notes

- **Spec coverage:** §3 data model → Task 2; §4 occurrences → Task 1; §5 dispatcher, email worker and cron → Task 3; §6 CRUD → Task 2, birthday sync → Task 4; §7 API/UI → Task 6; §8 errors → Task 3 (`safely/2`, unique index, retries, timezone fallback in Task 1); §9 tests → Tasks 1–6 plus the Task 7 runtime check; §10 out of scope → Global Constraints.
- **Additions beyond the spec, flagged for the user:** Task 5 (default rules were never seeded; without it advance notices can't work). Also, after missed periods the dispatcher advances past *today* rather than just past the fired occurrence (Review Focus 2), the concrete form of "caught up exactly once".
- **Not covered by a test:** the "creator missing" branch in `ReminderEmailWorker` (unreachable: NOT NULL FK).
