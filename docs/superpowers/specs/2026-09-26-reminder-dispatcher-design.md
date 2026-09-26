# Reminder dispatcher: design

- **Date:** 2026-09-26
- **Branch:** `feat/reminder-dispatcher` (off `release/0.5.0`)
- **Status:** approved in conversation, section by section; this document is awaiting review
- **Origin:** the stack #40 review of PR #37 (Monica reminder dates). Reproducing that PR against a real Monica 4.1.2
  showed that reminder scheduling itself is broken, so it gets redesigned first. PR #37 is then reduced to an
  importer change built on this design.

## 1. Problem

Verified at runtime on `release/0.5.0` code (PR #37 worktree, 2026-09-26):

1. **Recurring and birthday reminders fire once and never again.** `ReminderNotificationWorker` creates an instance
   and sends an email, but never moves `next_reminder_date` forward. Reproduced: a weekly reminder was fired
   successfully (`:ok`), and afterwards `next_reminder_date` was unchanged and no future job existed. Only
   `stay_in_touch` reminders ever advance (on resolve or dismiss). The `Reminder` moduledoc claims recurring
   reminders auto-advance.
2. **A reminder whose date has passed is never scheduled again.** `ReminderSchedulerWorker` (nightly, 2 AM UTC) only
   selects `next_reminder_date` in `[today, tomorrow]`. A reminder created after the day's send hour, or one that
   already fired (see 1), is never scheduled.
3. **Job bookkeeping is spread across ~10 code paths.** Each reminder stores `enqueued_oban_job_ids`. Create, update,
   delete, convert, archive, cancel-all, dismiss, contact merge, `Reminders.Cleanup` and account deletion each have to
   cancel and re-enqueue those jobs correctly. Jobs are also created in two ways: eagerly on write, and by the nightly
   cron.
4. **Dates drift.** `Reminder.frequency_days/1`: "monthly" is +30 days and "annually" is +365 days.
5. **Snooze does nothing.** `snooze_instance/2` sets `status: "snoozed"` and `snoozed_until`, and nothing reads them to
   notify again.
6. **Only one user gets the email.** `build_email/3` builds a message per account user, then takes `List.first()`.
7. **A retried email creates another instance.** The worker inserts the instance before sending, and an Oban retry
   repeats both.
8. **Birthday reminders never exist.** Nothing in `lib/` calls `Reminders.create_birthday_reminder/2` or
   `delete_birthday_reminder/2`, and the reminder form only offers one-time, recurring and stay-in-touch. The 7/30-day
   rules under Settings → Account therefore have nothing to apply to.
9. **Intervals are a fixed list** (`weekly biweekly monthly 3months 6months annually`), so Monica schedules like "every
   3 weeks" can't be represented.

## 2. Goals

- Recurring and birthday reminders fire every period, on the right calendar date, with no drift.
- Anything due is sent at the account's local send hour, and anything missed is caught up exactly once.
- Advance notices (Settings → Account rules), resolve, dismiss, **snooze (now notifies again)**, stay-in-touch,
  the account's timezone and send hour, and deceased/deleted/archived contact handling all work.
- Every contact with a birthdate has exactly one birthday reminder, kept in sync automatically.
- No per-reminder Oban jobs and no stored job ids. Writing a reminder is just a row write.
- Retries and overlapping runs never send the same notice twice.
- The REST API stays compatible for existing clients.

## 3. Data model

Schema-only migration. **It assumes a fresh, empty database** (production is reset for this release), so it does no
backfill, conversion or clearing.

### `reminders`

| Column | Change | Meaning |
|---|---|---|
| `type` | unchanged | `birthday`, `stay_in_touch`, `one_time`, `recurring` |
| `anchor_date` | **new**, `date`, not null | The first occurrence. Birthday: the birthdate. Monica import: `initial_date`. |
| `interval_unit` | **new**, string, nullable | `week`, `month` or `year`. Null for `one_time`. Required for every other type. |
| `interval_count` | **new**, integer, nullable | ≥ 1. Null for `one_time`. Required for every other type. |
| `next_reminder_date` | kept | Cached next occurrence. Read by "upcoming" lists and the dispatcher; never set directly by clients. |
| `frequency` | **dropped** | Replaced by unit + count (presets are mapped, see §7). |
| `enqueued_oban_job_ids` | **dropped** | No longer needed. |

`title`, `active`, `contact_id`, `account_id` and `creator_id` are unchanged. The existing one-birthday-reminder-per-contact
unique index stays.

### `reminder_instances` (one row per notice actually sent)

| Column | Change | Meaning |
|---|---|---|
| `occurrence_date` | **new**, `date`, not null | The occurrence this notice belongs to. |
| `kind` | **new**, string, not null | `on_day` or `advance` |
| `days_before` | **new**, integer, not null | 0 for `on_day`; the rule's `days_before` for `advance` |
| `status`, `fired_at`, `resolved_at`, `snoozed_until`, `snooze_count` | kept | Same meaning as today |
| unique index | **new** | (`reminder_id`, `occurrence_date`, `days_before`). This is the idempotency guarantee. |

### `reminder_rules`

Unchanged. Settings → Account keeps its toggles. The on-day rule (`days_before: 0`) can't be deactivated, as today.

## 4. Occurrence calculation: `Kith.Reminders.Occurrences`

Pure functions with no database access.

- `next_on_or_after(schedule, date)`: the first occurrence ≥ `date`.
  - `one_time`: `anchor_date` if ≥ `date`, otherwise `nil`.
  - Repeating: occurrence *n* is always derived **from the anchor** (never from the previous occurrence), and *n* is
    found by arithmetic, not by stepping one period at a time:
    - `week`: `anchor + 7 × count × n` days
    - `month`: `Date.shift(anchor, month: count × n)`. A 31st falls back to the month's last day when needed and
      returns to the 31st afterwards.
    - `year`: the same month and day in year `anchor.year + count × n`. **Feb 29 → Feb 28** in non-leap years (the same
      rule as today's `TimeHelper.next_birthday_date/1`).
- `advance_after(schedule, occurrence_date)`: the occurrence strictly after `occurrence_date`. `nil` for `one_time`.
- **Stay-in-touch** is the exception, and keeps today's semantics: after a resolve or dismiss, the next date is
  *today + one interval* (from the last contact), not anchor-based.

Removed: `TimeHelper.advance_by_frequency/2`, `Reminder.frequency_days/1`.

## 5. Dispatcher

`Kith.Workers.ReminderDispatcher`: an Oban cron job, **every hour** (`0 * * * *`), with a uniqueness window so it's
never queued twice in the same hour. It replaces `ReminderSchedulerWorker` (and the `0 2 * * *` cron entry).
`perform/1` delegates to a function that takes `now` as a parameter, so it can be tested without depending on the clock.

For each account: compute the **local date and hour** from `account.timezone` (fall back to UTC with a log line if the
timezone is invalid). Nothing is due for an account until the local hour is ≥ `send_hour`. After that, everything due
for the local date goes out, which also gives catch-up after missed runs.

### What is due

Only `active` reminders whose contact is not soft-deleted and not archived:

1. **On-day notice:** `next_reminder_date <= local_today`, with no instance for (`next_reminder_date`, 0).
   `stay_in_touch` additionally requires that the reminder has no `pending` instance.
2. **Advance notices** (`birthday` and `one_time` only, as today): for each active rule with `days_before > 0`,
   sorted descending (e.g. 30, 7), the rule's window is `[next − days_before, next − next_smaller_days_before)`, where
   the smallest rule's window ends at `next`. The notice is due if `local_today` is inside the window and no instance
   exists for (`next_reminder_date`, `days_before`). Example: a reminder created 5 days out gets only the 7-day notice.
3. **Ended snoozes:** instances with `status = "snoozed"` and `snoozed_until <= now`. These are sent again, set back to
   `pending`, and get a new `fired_at`.

### Sending one notice (a single transaction)

1. Insert the instance (`occurrence_date`, `kind`, `days_before`, `status: "pending"`, `fired_at: now`). If the unique
   index conflicts, the notice was already sent, so stop.
2. If it's an **on-day** notice on a `recurring` or `birthday` reminder, set `next_reminder_date =
   Occurrences.advance_after(schedule, occurrence_date)`. `one_time` keeps its date as history. `stay_in_touch` waits
   for a resolve or dismiss.
3. **Deceased contact:** insert the instance as `dismissed`, send nothing, and still advance (step 2).
4. Otherwise, insert a `ReminderEmailWorker` job (`Oban.insert` inside the same transaction) addressed to the
   reminder's **creator**. If the creator no longer exists, skip the email and log it.

### `ReminderEmailWorker`

It sends one email for one instance. On failure it retries with Oban's backoff, using the same `max_attempts` as today's
`ReminderNotificationWorker`. A retry never
touches instances. After the final attempt, the instance becomes `failed`. The email subject and text keep today's
wording (`email_subject/5`). It writes the `reminder_fired` audit log entry, as today.

### Removed

`ReminderSchedulerWorker`, `ReminderNotificationWorker`, `Reminders.enqueue_jobs_for_reminder/2`,
`Reminders.cancel_jobs/1`, `cancel_enqueued_jobs_step/2`, and the job-cancel code in `Reminders.Cleanup`,
`AccountDeletionWorker`, `Contacts.Merge`, `archive_contact_reminders/2` and `cancel_all_for_contact/2`.

## 6. The `Kith.Reminders` API and birthday sync

- `create_reminder/3` and `update_reminder/2`: validate the schedule, set `next_reminder_date =
  Occurrences.next_on_or_after(schedule, account-local today)`, save. No jobs.
- `delete_reminder/1`: delete the row (instances cascade).
- Archive, soft-delete, restore and merge: set `active` where they do today, or rely on the dispatcher's contact filters.
  No job handling.
- `resolve_instance/1`, `dismiss_instance/1` and `snooze_instance/2` keep their signatures. Resolve and dismiss advance
  `stay_in_touch` reminders (§4). Snooze is now honoured by the dispatcher (§5.3).
- **Birthday sync:** `Reminders.sync_birthday(contact)` is called from `Contacts.create_contact/2` and
  `Contacts.update_contact/2` when `birthdate` changes, and after a contact merge. Every path that changes a birthdate
  (UI, REST API, CardDAV, importer) goes through those functions, so they're covered without touching their 19 call
  sites.
  - Birthdate set or changed → upsert the contact's birthday reminder (`anchor_date = birthdate`, `year`/1,
    `next_reminder_date` recomputed).
  - Birthdate removed → delete the birthday reminder.
  - **Creator = the account owner** (its admin user; the only user in practice). The contact functions receive no user.
    This rule depends on the ownership question in §10.
  - Birthday reminders can't be created, edited or deleted by hand. The UI already hides editing; the REST API returns
    a validation error for `type: "birthday"`.
- `create_birthday_reminder/2` and `delete_birthday_reminder/2` are replaced by `sync_birthday/1`.
  `get_birthday_reminder/2` stays as a read helper.

## 7. REST API and UI compatibility

- **Presets:** `weekly` = week/1, `biweekly` = week/2, `monthly` = month/1, `3months` = month/3, `6months` = month/6,
  `annually` = year/1.
- **Responses** keep `frequency` (the preset name for those combinations, otherwise `null`) and add `anchor_date`,
  `interval_unit` and `interval_count`. `next_reminder_date` stays (read-only).
- **Requests** accept `frequency` (a preset) **or** `interval_unit` + `interval_count`, plus `anchor_date`. For backward
  compatibility, a `next_reminder_date` in a create request is treated as `anchor_date` when `anchor_date` is absent.
  In update requests `next_reminder_date` is ignored.
- **Reminder form in the UI:** same fields. The date input becomes the anchor ("First date"), and the frequency select
  keeps the presets.
- Settings → Account rule toggles are unchanged.

## 8. Error handling

- **Email failure:** only `ReminderEmailWorker` retries. After the final attempt the instance is `failed`.
- **An account or reminder raising in the dispatcher:** it's logged and skipped, and the rest of the run continues.
  Nothing was recorded, so the next hourly run retries it.
- **Overlapping runs, several nodes:** the unique instance index prevents duplicate notices; the cron's uniqueness
  window prevents duplicate dispatcher jobs.
- **Invalid timezone:** fall back to UTC and log it.
- **Missing creator:** skip the email and log it. The instance is still recorded, so there's no retry loop.

## 9. Testing

Run on the pinned toolchain (mise: Elixir 1.19.5 / OTP 28.5), with the test database isolated via `MIX_TEST_PARTITION`.

- **`Occurrences`** (pure, table-driven): week/month/year × count 1/2/3/6; month-end anchors (31st → Feb → the 31st
  again); Feb 29 anchors in leap and non-leap years; an anchor far in the past (1990); `one_time` before and after
  `date`; `advance_after`.
- **Dispatcher** (with `now` passed in):
  - exactly once, with a second run sending nothing
  - catch-up after missed hours
  - not due before the send hour, due after it, in a non-UTC timezone
  - advance-notice windows (5 days out → only the 7-day notice)
  - an ended snooze re-sends and goes back to `pending`
  - stay-in-touch waits while an instance is pending, and resolve/dismiss advance it from today
  - deceased → dismissed and advanced
  - soft-deleted or archived contacts skipped
  - **recurring and birthday reminders advance after firing** (regression for §1.1)
  - the email goes only to the creator; a missing creator is skipped and logged
  - a retried `ReminderEmailWorker` creates no extra instance
- **Birthday sync:** create, change and remove a birthdate via `Contacts`; a merge; Feb 29 birthdates.
- **REST API:** existing reminder tests updated; presets round-trip; interval fields round-trip; `next_reminder_date`
  treated as the anchor on create; birthday reminders rejected for create, update and delete.
- **Runtime check:** run a dev server and create reminders through the UI; fire the dispatcher with a controlled clock;
  confirm the emails (Swoosh local adapter) and the advanced dates.

## 10. Out of scope

- **Per-user ownership (vision mismatch).** The product vision is that each user owns their contacts and reminders. The
  codebase is account-shared multi-tenancy: contacts belong to an account, accounts can have several users with roles,
  and there's an invitation-acceptance LiveView, but no UI or API to send invitations or manage users. Resolving this is a
  separate decision; an issue will record it. This design's only dependency on it is "birthday reminder creator = account
  owner" (§6).
- **Monica importer changes: the reduced PR #37**, which comes after this lands. It computes schedules from `initial_date`
  + `frequency_type` + `frequency_number`, skips Monica's `delible: false` birthday reminders (Kith derives them from the
  birthdate), and handles past one-time reminders (decision pending).
- **Older import bugs** found during the review: `ImportWizardLive` has no `handle_info` clause for
  `{:import_misc_complete, _}` (the LiveView crashes at the end of every Monica import), and that crash report logs the
  Monica API key in plain text.
