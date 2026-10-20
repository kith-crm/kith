# Monica 4.1.2 reminder import rework: design

- **Date:** 2026-10-14
- **Branch:** `feat/stack-40-consolidated` (PR #44 → `release/0.5.0`)
- **Status:** approved in conversation, section by section; this document is awaiting review
- **Origin:** PR #44's deferred follow-up "rework the Monica reminder import for Monica 4.1.2". Every rule
  below was checked against a real Monica 4.1.2 and a real import through Kith's UI (see §2).
- **Decision 2026-10-19:** re-importing previously imported contacts is not supported; such contacts are
  skipped (counted in the summary's `skipped`) along with their children. A purged contact is re-created.
  Only a retry of the *same* import job is idempotent.
- **Related:** [reminder dispatcher design](2026-09-26-reminder-dispatcher-design.md) (the schedule model this
  importer targets).

## 1. Problem

Observed on PR #44 head `c70b145`, by importing a seeded Monica 4.1.2 through the Kith import wizard
(headless browser) on 2026-10-14:

1. **Every Monica birthday reminder is duplicated.** Kith detects a birthday reminder only when its title is blank,
   but Monica requires a title (`Wish happy birthday to Mona`). Each one is imported as a generic yearly reminder
   next to the birthday reminder Kith derives from the birthdate.
2. **Past dates are lost.** Monica 4.1.2 sends no `next_expected_date`, so the importer falls back to `initial_date`
   and clamps any past date to today. The reminder's anchor becomes the import day; the original day and month are
   gone for good.
3. **`frequency_number` is ignored.** Every 2 weeks → Weekly, every 3 months → Monthly, every 2 years → Annually,
   and `month/0` → Monthly.
4. **Old one-time reminders come back.** Already-sent and long-past one-time reminders are imported as active and
   due today. Together with 2, every imported past reminder is due on import day, so the dispatcher's catch-up rule
   sends them all at the account's send hour (inferred from the dispatcher; not yet observed).
5. **A contact born on 29 February crashes the contact page.** `ContactLive.Show.compute_next_birthday_badge/1`
   calls `Date.new!(today.year, 2, 29)` → `ArgumentError :invalid_date` in non-leap years.
6. **Not imported:** stay-in-touch settings and reminder descriptions.

## 2. Monica 4.1.2 facts

Read from the source inside the `monica:4-apache` (4.1.2) container, and observed through its REST API after seeding
every reminder source Monica has. Seed and captured payloads: `test/playwright/fixtures/monica/` (§7).

| # | Fact |
|---|------|
| M1 | Reminder API keys: `id uuid object title description frequency_type frequency_number initial_date delible account contact created_at updated_at`. There's no `next_expected_date`, no `inactive` and no birthday flag. `initial_date` is `"YYYY-MM-DDT00:00:00Z"`. |
| M2 | `delible: false` is set only by the birthday reminder (`UpdateBirthdayInformation`, also `ImportCSV`) and the first-met anniversary (`UpdateContactIntroduction`). Death-anniversary and life-event reminders are `delible: true`. |
| M3 | `UpdateReminder` defaults `delible` to `true` when the field is omitted, so editing a birthday reminder through the API makes it `delible: true`. |
| M4 | The contact resource doesn't expose `birthday_reminder_id` or `first_met_reminder_id`; the link exists only in Monica's database. |
| M5 | Birthday titles are translated (40+ locales). In English: `Wish happy birthday to :name`, deceased `On this date, :name would have celebrated their birthday`, first-met `Anniversary of the day you first met`, death `Anniversary of the death of :name`. |
| M6 | For a year-unknown birthday, the special date and the reminder's `initial_date` use the year the birthday was entered (`2026-07-04`, `is_year_unknown: true`). |
| M7 | `frequency_type ∈ {one_time, week, month, year}`. `frequency_number` is only `required|integer`, so 0 is accepted. |
| M8 | Monica's next date adds intervals to `initial_date` until it's in the future and skips today. Carbon's `addMonths` overflows and drifts (Jan 31 monthly → the 3rd; Nov 30 quarterly → Dec 2; Feb 29 yearly → Mar 1). |
| M9 | The same loop moves a past one-time reminder forward by whole **years** (2020-01-01 → 2027-01-01). |
| M10 | A sent one-time reminder is marked `inactive` and loses its outbox row, but the API still returns it unchanged. Sent and unsent one-time reminders look the same. |
| M11 | Life-event reminders take the life-event type's name as their title. The default types have a NULL name, so only custom types can have reminders. |
| M12 | Stay-in-touch lives on the contact (`stay_in_touch_frequency` as a free number of **days**, `stay_in_touch_trigger_date`). It's set only in the UI and exposed on the contact resource. |
| M13 | Reminders have a free-text `description`. |

## 3. Decisions

| # | Decision | Rejected alternatives |
|---|----------|-----------------------|
| D1 | A Monica reminder **is the birthday reminder** when it's `year`/1 and its `initial_date` month-day equals the contact's birthdate month-day. Title and `delible` are ignored. | Also requiring `delible: false` (misses API-edited birthdays, M3); also matching the translated title (we'd have to maintain Monica's translations). Accepted cost: a user-made yearly reminder on the birthday (e.g. "Fiona birthday party") merges into the birthday reminder and its title is lost. |
| D2 | Monica's first-met anniversary maps onto a new **derived `first_met` reminder**, opt-in per contact. | Importing it as a generic yearly reminder; skipping it; deriving it for every contact with a first-met date. |
| D3 | A past **one-time** reminder is imported with its original date and `active: false`. | Skipping it; moving it forward a year like Monica (M9 brings back reminders that already fired). |
| D4 | **Stay-in-touch** is imported, and Kith gains a `day` interval unit so Monica's day counts import exactly. | Rounding to weeks; leaving it out. |
| D5 | Reminders gain a **`description`** field. | Saving it as a contact note; dropping it. |
| D6 | Kith's own schedule maths applies: month-end and 29 Feb are clamped without drift, and a date equal to today counts as due. Monica's M8/M9 behaviour is not copied. | Copying Monica's scheduler. |
| D7 | A `frequency_number` ≤ 0 imports as a one-time reminder on `initial_date`, with a warning. | Rejecting the reminder. |
| D8 | A first-met reminder sends **on the day only** (no 7/30-day advance notices), like `recurring`. | Advance notices like birthdays. |
| D9 | The in-app reminder form keeps its six presets and adds a **"Custom…"** option that shows "Every [N] [days/weeks/months/years]". | Always-visible count + unit fields (two inputs for every reminder); presets only (day intervals unreachable in the UI). |
| D10 | No repair of existing data: production is reset for this release (the dispatcher migration already assumes an empty database). | A repair mix task. |

## 4. Mapping rules

`Kith.Imports.Monica.ReminderMapper.map(monica_reminder, %Contact{})` returns one decision. The rules are checked
in order:

| # | Monica input | Decision → Kith result |
|---|--------------|------------------------|
| R1 | `frequency_type` not in M7's set | `{:skip, :unknown_frequency}`, logged and counted |
| R2 | `year`/1, `initial_date` month-day = `contact.birthdate` month-day | `{:birthday}` → `Reminders.sync_birthday/1`, then record the mapping |
| R3 | `year`/1, `initial_date` month-day = `contact.first_met_at` month-day | `{:first_met}` → `update_contact(first_met_reminder: true)` (which runs `sync_first_met/1`), then record the mapping |
| R4 | `week`/`month`/`year`, N ≥ 1 | `recurring`: `anchor_date = initial_date`, `interval_unit = week/month/year`, `interval_count = N` |
| R5 | `one_time`, or N ≤ 0 (D7, with a warning), with `initial_date` ≥ today | `one_time`, `anchor_date = initial_date`, `active: true` |
| R6 | Same as R5 but `initial_date` < today | `one_time`, `anchor_date = initial_date`, `active: false` (D3) |

All decisions that create a reminder copy `title` (`"Imported reminder"` if it's blank, kept as a safeguard) and
`description`. "Today" is the importing account's local date (`Kith.TimeHelper`), the same date the dispatcher uses.

**Stay-in-touch** (from the contact resource, not the reminders endpoint): when `stay_in_touch_frequency` > 0,
create a `stay_in_touch` reminder with `interval_unit: "day"`, `interval_count = frequency`, and `anchor_date` =
the date part of `stay_in_touch_trigger_date`. If the trigger date is missing, use today + frequency days.

**Retries (not re-imports):** contacts from an earlier import are skipped (2026-10-19 decision), so the rules
below only matter when Oban retries the *same* import job:
- **Mapped Monica reminder id:**
  - A `birthday` or `first_met` mapped row: re-run its sync and keep the mapping.
  - A generic mapped row of the same type: update it in place. Never create a second one.
- **Stay-in-touch:** the import record key is `stay_in_touch:<monica contact id>`.

## 5. Kith changes

### 5.1 Schema (one additive migration)
- `reminders.description`: `text`, nullable.
- The `reminders_interval_unit_values` check constraint allows `'day'`.
- `contacts.first_met_reminder`: `boolean NOT NULL DEFAULT false`.
- A partial unique index `reminders_first_met_unique_idx` on `(contact_id) WHERE type = 'first_met'`.

### 5.2 Reminders
- `Reminder`: `@types` gains `first_met`; `@units` gains `day`. `description` is cast in `create_changeset` and
  `update_changeset`. `interval_label/1`: `day`/1 → "Daily", `day`/N → "Every N days".
- `Occurrences`: `nth/2` and `lower_bound_index/2` get `day` clauses (`Date.add(anchor, count * n)`,
  `div(Date.diff(date, anchor), count)`).
- `Reminders.sync_first_met/1`, mirroring `sync_birthday/1`:
  - If the flag is on and `first_met_at` is set: create or update a yearly reminder anchored on `first_met_at`,
    owned by the account owner.
  - Otherwise: delete it.
  - `Contacts.create_contact/2` and `update_contact/2` call it when `first_met_at` or `first_met_reminder` changes.
  - `Contacts.Merge` calls it for the survivor. The survivor's flag is on if any merged contact had it on.
- Dispatcher: `first_met` is not in `@advance_types` (D8) and advances yearly after its on-day notice.
- `ReminderEmailWorker`: the subject for `first_met` is "Anniversary of meeting {name}". The body includes
  `description` when present (all types).

### 5.3 API
- `ReminderController`: `reject_birthday/1` becomes `reject_derived/1` and covers `first_met`. Create, update and
  delete return 422 with "…managed from the contact's first-met date."
- Reminder JSON (`reminder_controller.ex`, `contact_json.ex`) adds `description`. `interval_unit` accepts `day`.
- Contact JSON exposes `first_met_reminder`, and it can be updated through the contact API.

### 5.4 UI
- First-met form: a "Remind me every year" toggle bound to `first_met_reminder`.
- `RemindersComponent`: shows `description` under the title, labels the `first_met` type, hides delete for `first_met`.
- `RemindersComponent` form (D9):
  - The Frequency select gains a last option, `Custom…` (`value="custom"`).
  - The form's `phx-change` handler tracks the selected frequency (`:form_frequency`) next to `:form_type`.
  - When `custom` is selected, two fields appear: `reminder[interval_count]` (number, min 1, required) and
    `reminder[interval_unit]` (`day`/`week`/`month`/`year`, default `day`).
  - On save:
    - **`custom`:** `interval_unit` and `interval_count` are sent and `frequency` is dropped.
    - **A preset:** the preset is sent as today.
    - **Validation:** the changeset's existing schedule validation and the `interval_count >= 1` check constraint
      are used; errors show as a flash, the same as the current form.
  - The form also gains an optional Description textarea (`reminder[description]`).
- `ReminderLive.Upcoming` and `KithUI.reminder_row`: icon and label for `first_met`.
- `ContactLive.Show.compute_next_birthday_badge/1`: use `Occurrences.next_on_or_after/2` (yearly schedule anchored
  on the birthdate) instead of `Date.new!`. The plan includes a grep for other birthday `Date.new!` call sites.

### 5.5 Importer
- **New** `lib/kith/imports/monica/reminder_mapper.ex`: pure, no Repo access. It owns date parsing; the worker's
  `reminder_next_date`, `initial_date_fallback`, `max_today`, `fallback_today` and `map_monica_reminder_frequency`
  helpers are deleted.
- `MonicaMiscDataWorker.import_single_reminder/5` carries out the mapper's decision (§4) and counts skips and
  warnings in the import summary.
- `Imports.Sources.MonicaApi` creates the stay-in-touch reminder after saving each contact (a same-job retry updates it), when
  the `reminders` import option is on.

## 6. Error handling
- Unknown `frequency_type` or an unparseable `initial_date`: skip that reminder, log it with the Monica id, count it
  in the import summary. The rest of the import continues.
- `sync_birthday` / `sync_first_met` returning an error (e.g. no account owner): log it and skip the mapping, the
  same as the existing `log_reminder_error/1` path.
- A changeset error on create or update: log the Monica id and the errors; nothing is retried. The behaviour of the
  current worker is kept.

## 7. Testing

**ExUnit**
- `ReminderMapper`: table-driven, one case per R1–R6 row plus stay-in-touch, using
  `test/fixtures/monica/4.1.2/reminders.json` and `contacts.json` (cut down from the captured real payloads).
- `Occurrences` `day` unit; `Reminder.interval_label/1`; `description` round-trips through the changeset and the API.
- `sync_first_met/1`: flag on/off, date set/cleared, merge OR, unique index.
- API: 422 for create/update/delete of `first_met`; `first_met_reminder` on the contact API.
- Dispatcher: `first_met` gets no advance notice and advances yearly; the email subject for `first_met`.
- `MonicaMiscDataWorker`: a retry of the same import updates the mapped reminder in place (no duplicates).
- `MonicaApi.crawl/5`: contacts from an earlier import are skipped and untouched; a purged contact is re-created; a same-job retry is idempotent; relationships to skipped contacts still link.
- LiveView: the contact page renders a 29 Feb birthday in a non-leap year.
- LiveView (`RemindersComponent`):
  - Choosing `Custom…` shows the count and unit fields; choosing a preset hides them.
  - Saving "Every 10 days" creates a reminder with `day`/10 and shows "Every 10 days".
  - A preset still saves as before.
  - A count of 0 is rejected.
  - The description is saved and shown.

**Repeatable end-to-end**
- Commit the Monica seed (`seed2.py`, `state.php`, `mon.py`) and a README under `test/playwright/fixtures/monica/`.
- `test/playwright/monica-reminders.spec.ts` is skipped unless `MONICA_URL` and `MONICA_API_KEY` are set. It
  registers a user, confirms through Mailpit, imports through the wizard, and checks every seeded contact's
  reminders against §8.
- Before merging, run it headless against a local Monica 4.1.2 and Kith in Docker.

## 8. Expected result for the seeded Monica (import run on 2026-10-14)

| Contact | Kith reminders |
|---|---|
| Mona | Birthday, next Jun 15 2027 (Monica's edited, `delible: true` birthday reminder maps onto it) |
| Paul (29 Feb 1992) | Birthday, next Feb 28 2027; the contact page loads |
| Yara (year unknown) | Birthday, next Jul 4 2027 |
| Noel (no Monica reminder) | Birthday, next Nov 2 2026 (derived from the birthdate) |
| Dora (deceased) | Birthday, next Apr 20 2027 · "Anniversary of the death of Dora", yearly, next Aug 1 2027 |
| Fiona | Birthday, next Jan 15 2027 ("Fiona birthday party" merges into it) · first-met flag on → First met, next Sep 1 2027 |
| Liam | "Promotion", yearly, next May 10 2027 |
| Solo | Wedding anniversary, yearly, next Mar 9 2027 · Call mum, every 2 weeks, next Oct 26 2026 · Pay rent, monthly, next Nov 1 2026 · Renew passport, one-time, inactive · Dentist, one-time, Jan 10 2027 |
| Gina | Water plants, every 2 weeks, next Oct 26 2026 · Pay card (31st), monthly, next Oct 31 2026 · Quarterly review, every 3 months, next Nov 30 2026 · Leap-day thing, every 2 years, next Feb 29 2028 · One-time today, due Oct 14 2026 · One-time past (never sent), inactive · One-time past (sent), inactive · One-time future, Feb 14 2027, description "Has a description" · Zero frequency → one-time Jun 1 2027 (warning) · Stay in touch, every 14 days, next Oct 28 2026 |

## 9. Out of scope
- Deceased contacts: the derived birthday reminder doesn't use Monica's "would have celebrated" wording.
- Editing an existing reminder's schedule in the UI (the form is create-only today; unchanged here).
- Monica `ReminderRule` settings (7/30 days): Kith seeds its own default rules at signup.
- The PR #35/#36 review findings (a separate spec).
