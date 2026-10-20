# Monica Note Dates + Timeline Edit Prefill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Imported Monica notes keep Monica's original created/updated dates, and the contact timeline's Edit modal opens pre-filled (and saves) for every editable entry type.

**Architecture:** `Contacts.create_note/4` gains an opts list that sets `inserted_at`/`updated_at` directly on the struct (never cast from user params). A small `Kith.Imports.Monica.NoteTimestamps` module turns a Monica note JSON into those opts, and both Monica import paths use it. `ActivityStreamComponent` loads the record on `edit-entry` into `:modal_record` and every modal clause renders values from it.

**Tech Stack:** Elixir, Ecto, Phoenix LiveView, ExUnit, `Req.Test` stubs.

**Spec:** `docs/superpowers/specs/2026-10-20-monica-note-dates-and-edit-prefill-design.md`

## Global Constraints

- `Note.changeset/2` cast list stays unchanged. Forms and the API must not be able to set timestamps.
- `notes` timestamps are `:utc_datetime`, so truncate to `:second`.
- No backfill: dedupe-skipped existing notes keep their timestamps.
- Datetime prefill is in UTC, `datetime-local` format `"%Y-%m-%dT%H:%M"`, and dates use `Date.to_iso8601/1`.
- Create modals keep today's empty/"now" defaults.
- `mix test` must report 0 failures before every commit. No `Co-Authored-By`. **Never push.**
- Run `mix format` before committing.

## Review Focus

- Monica `created_at` missing, `nil` or malformed. The note must still import, with the timestamp falling back to now and no crash. (Task 1 test.)
- Monica sends `updated_at` but no `created_at`, or `updated_at` earlier than `created_at`. Use `created_at` for `inserted_at` and `updated_at || created_at` for `updated_at`. (Task 1 test.)
- Saving an edit without changing anything must not alter the stored values. In particular, a call's `occurred_at` must stay the same and not shift by a timezone. (Task 3 test.)
- Opening New after Edit must show an empty form, not the last edited record. (Task 3 test.)
- A private note edited by its author must pre-fill the `is_private` checkbox as checked, so saving doesn't silently make it public. (Task 3 test.)

---

### Task 1: Import-only note timestamps

**Files:**
- Modify: `lib/kith/contacts.ex:622` (`create_note`)
- Create: `lib/kith/imports/monica/note_timestamps.ex`
- Test: `test/kith/contacts_sub_entities_test.exs` (notes section), `test/kith/imports/monica/note_timestamps_test.exs`

**Interfaces:**
- Produces: `Contacts.create_note(contact :: Contact.t(), user_id, attrs :: map, opts :: keyword \\ []) :: {:ok, Note.t()} | {:error, Changeset.t()}`. `opts` accepts `inserted_at: DateTime.t() | nil` and `updated_at: DateTime.t() | nil`. Non-nil values are truncated to the second and set on the `%Note{}` struct before the changeset. Nil or absent values leave Ecto's autogeneration in place.
- Produces: `Kith.Imports.Monica.NoteTimestamps.from_note(note :: map) :: keyword` returns `[inserted_at: dt | nil, updated_at: dt | nil]`, where `inserted_at = parse(created_at)` and `updated_at = parse(updated_at) || inserted_at`.

- [ ] **Step 1: Write the failing tests**
  - `create_note/4 uses given timestamps`: given `inserted_at: ~U[2024-02-20 12:00:00.123456Z], updated_at: ~U[2024-03-01 08:00:00Z]`, assert `note.inserted_at == ~U[2024-02-20 12:00:00Z]` and `note.updated_at == ~U[2024-03-01 08:00:00Z]`. Reload from the DB and assert the same values.
  - `create_note/3 still autogenerates`: `DateTime.diff(DateTime.utc_now(), note.inserted_at) < 5`.
  - `create_note ignores timestamp keys in attrs`: `attrs = %{"body" => "x", "inserted_at" => "2001-01-01T00:00:00Z"}` gives `note.inserted_at.year != 2001`.
  - `NoteTimestamps.from_note/1`:
    - `%{"created_at" => "2024-02-20T12:00:00Z", "updated_at" => "2024-02-21T09:30:00Z"}` gives `[inserted_at: ~U[2024-02-20 12:00:00Z], updated_at: ~U[2024-02-21 09:30:00Z]]`.
    - With `updated_at` missing, `updated_at == inserted_at`.
    - `%{"created_at" => "garbage"}` and `%{}` give `[inserted_at: nil, updated_at: nil]`.
    - An offset string `"2024-02-20T14:00:00+02:00"` gives `~U[2024-02-20 12:00:00Z]`.
    - The Monica space format `"2024-02-20 12:00:00"` is treated as UTC and gives `~U[2024-02-20 12:00:00Z]`.

- [ ] **Step 2: Run the tests and confirm they fail**
  `mix test test/kith/contacts_sub_entities_test.exs test/kith/imports/monica/note_timestamps_test.exs`. Expected: failures with undefined `create_note/4` / `NoteTimestamps`.

- [ ] **Step 3: Implement** `create_note/4` (keep the `/3` arity via the default arg) and `NoteTimestamps.from_note/1`. The parser tries `DateTime.from_iso8601/1` first, then `NaiveDateTime.from_iso8601/1` → `DateTime.from_naive!(_, "Etc/UTC")`, then truncates to the second.

- [ ] **Step 4: Run the tests and confirm they pass** (same command).

- [ ] **Step 5: Run `mix test`. Expect 0 failures. Then commit:** `feat(notes): allow import-only original timestamps on create_note`

### Task 2: Use Monica note dates in both import paths

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex:806` (`create_imported_note/4`)
- Modify: `lib/kith/workers/monica_misc_data_worker.ex:261` (`create_imported_note/4`)
- Modify: `test/support/fixtures/monica_api_fixtures.ex:150` (`note_json/1`: make `created_at`/`updated_at` overridable via `overrides[:created_at]` / `overrides[:updated_at]`, using `Map.get` with the current defaults so that an explicit `nil` override is honoured)
- Test: `test/kith/imports/sources/monica_api_test.exs`, `test/kith/workers/monica_misc_data_worker_test.exs`

**Interfaces:**
- Consumes: `Contacts.create_note/4` and `NoteTimestamps.from_note/1` from Task 1.

- [ ] **Step 1: Write the failing tests**
  - In `monica_api_test.exs`, add `describe "crawl/5 — note timestamps"`. Test `embedded notes keep Monica created_at/updated_at`: one contact with `note_json(body: "Old", created_at: "2019-05-04T10:00:00Z", updated_at: "2020-01-01T00:00:00Z")`. After the crawl, assert the note's `inserted_at == ~U[2019-05-04 10:00:00Z]` and `updated_at == ~U[2020-01-01 00:00:00Z]`.
  - In the same describe, test `note without created_at falls back to now`: `note_json(body: "New", created_at: nil, updated_at: nil)`. Assert the note was imported and `DateTime.diff(DateTime.utc_now(), inserted_at) < 60`.
  - In the same describe, test `re-import does not change timestamps of existing notes`: pre-create a note via `note_fixture` with the same body on the contact the crawl will match, or run the crawl twice with different `created_at`. Assert `inserted_at` is unchanged after the second run.
  - In `monica_misc_data_worker_test.exs`, inside `describe "perform/1 — extra notes"`, add test `extra notes keep Monica created_at`: copy the stub setup from the existing "imports notes past the embedded ones" test. Give the paged note `created_at: "2018-07-07T07:07:07Z"` and assert that `inserted_at` on the imported note.

- [ ] **Step 2: Run the tests and confirm they fail.** Run both test files. Expected: the timestamp assertions fail because they get today's date.

- [ ] **Step 3: Implement.** Both `create_imported_note/4` functions call `Contacts.create_note(contact, user_id, %{"body" => note["body"]}, NoteTimestamps.from_note(note))`. Alias the module in both files. No other behaviour changes.

- [ ] **Step 4: Run the two test files and confirm they pass.**

- [ ] **Step 5: Run `mix test`. Expect 0 failures. Then commit:** `fix(monica): imported notes keep Monica's original created/updated dates`

### Task 3: Edit modal loads and pre-fills note, call, task, gift

**Files:**
- Modify: `lib/kith_web/live/contact_live/activity_stream_component.ex` (mount ~L25, `open-entry-modal` ~L62, `edit-entry` ~L72, `close-modal` ~L83, `save-entry` success ~L101, `<.modal>` call ~L377, `entry_modal_content` clauses for `:note`, `:call`, `:task` and `:gift`)
- Test: `test/kith_web/live/contact_live/activity_stream_component_test.exs`

**Interfaces:**
- Produces: assign `:modal_record`, holding the loaded schema struct or `nil`. It is passed to `entry_modal_content` as the `record` attr. Add `defp load_record(type :: atom, id :: integer, assigns) :: struct | nil` with clauses that reuse the same getters as `update_entry/4`: `Contacts.get_note!(account_id, id, current_user_id)`, `Activities.get_call!/2`, `Tasks.get_task!/2`, `Gifts.get_gift!/2`, and a fallback clause that returns `nil`. Task 4 adds clauses here.
- The `:modal_record` assign is set to `nil` in `mount`, `open-entry-modal`, `close-modal`, and after a successful `save-entry` or `delete-entry`.

- [ ] **Step 1: Write the failing tests** in a new `describe "edit modal prefill"`. Each test creates the record (with `note_fixture/3` or the context `create_*` functions; add fixtures only if a test needs them twice), opens `live(conn, ~p"/contacts/#{contact.id}")`, and clicks `button[phx-click="edit-entry"][phx-value-type="<type>"][phx-value-id="<id>"]`.
  - `note`: body `"Met at the conference"` with `is_private: true`. The rendered modal contains `Edit Note` and a `textarea[name="entry[body]"]` whose content is `Met at the conference`. Use `has_element?(view, ~s|textarea[name="entry[body]"]|, "Met at the conference")`. Assert `has_element?(view, ~s|input[name="entry[is_private]"][checked]|)`.
  - `call`: `occurred_at ~U[2023-04-05 06:07:00Z]`, `duration_mins: 42`, `notes: "Talked about trip"`. Assert `input[name="entry[occurred_at]"][value="2023-04-05T06:07"]`, `input[name="entry[duration_mins]"][value="42"]`, and that the notes textarea contains the text.
  - `task`: title, description and due_date `~D[2025-01-02]`. Assert the matching `value=` attributes and the description textarea text.
  - `gift`: name, `direction: "received"` and description. Assert `option[value="received"][selected]` inside `select[name="entry[direction]"]`.
  - `save without changes keeps the call unchanged`: open the call edit, then `render_submit` the form with the pre-filled values. Pass these explicitly as params, because LiveViewTest doesn't read DOM values: `%{"entry" => %{"occurred_at" => "2023-04-05T06:07", "duration_mins" => "42", "notes" => "Talked about trip"}}`. Reload and assert `occurred_at == ~U[2023-04-05 06:07:00Z]`.
  - `new note after editing opens empty`: click Edit on a note, close the modal, click `button[phx-click="open-entry-modal"][phx-value-type="note"]`, and assert the textarea is empty and the heading reads `New Note`.

- [ ] **Step 2: Run the test file and confirm the new tests fail.** `mix test test/kith_web/live/contact_live/activity_stream_component_test.exs`

- [ ] **Step 3: Implement** the record loading, the assign lifecycle, and the prefill for the four clauses. Use `value={...}`, `checked={...}` and `selected={...}` driven by `@record`, with `nil`-safe defaults that keep today's create behaviour. Put textarea content between its tags (`<textarea ...>{@record && @record.body}</textarea>`). Add `defp datetime_local_value(DateTime.t() | nil) :: String.t()`, which returns `Calendar.strftime(dt || DateTime.utc_now(), "%Y-%m-%dT%H:%M")`, and reuse it in Task 4.

- [ ] **Step 4: Run the test file and confirm everything passes.**

- [ ] **Step 5: Run `mix test`. Expect 0 failures. Then commit:** `fix(timeline): edit modal pre-fills note, call, task and gift`

### Task 4: Life event, conversation, activity: prefill + saving edits; hide Edit on photos

**Files:**
- Modify: `lib/kith_web/live/contact_live/activity_stream_component.ex` (`load_record/3` clauses, `update_entry/4` clauses ~L216-L235, the `entry_modal_content` clauses for `:life_event`, `:conversation` and `:activity`, and the overflow-menu Edit button ~L459)
- Test: `test/kith_web/live/contact_live/activity_stream_component_test.exs`

**Interfaces:**
- Consumes: `:modal_record`, `load_record/3` and `datetime_local_value/1` from Task 3.
- New `update_entry/4` clauses:
  - `:life_event` → `Activities.get_life_event!/2` + `Activities.update_life_event/2`
  - `:conversation` → `Conversations.get_conversation!/2` + `Conversations.update_conversation/2`
  - `:activity` → `Activities.get_activity!/2` + `Activities.update_activity/2`, which leaves contacts and emotions untouched
- Matching `load_record/3` clauses with the same getters.

- [ ] **Step 1: Write the failing tests** (same describe as Task 3).
  - `life_event`: record with `occurred_on ~D[2020-08-09]` and `note: "Graduated"`. Assert `input[name="entry[occurred_on]"][value="2020-08-09"]`, the selected `life_event_type_id` option, and the note textarea text. Then submit with `note: "Graduated with honors"`, assert no error is rendered, and reload to check the new note.
  - `conversation`: subject `"Catch-up"` with `platform: "signal"`. Assert the subject `value` and `option[value="signal"][selected]`. Submit with subject `"Catch-up 2"` and assert it was persisted.
  - `activity`: title, `occurred_at ~U[2022-02-02 02:02:00Z]` and description. Assert the prefilled values. Submit with a new title, assert it was persisted, and assert the activity's contacts still include `contact.id`.
  - `photo entries have no Edit action`: with `photo_fixture(contact, ...)`, assert `refute has_element?(view, ~s|button[phx-click="edit-entry"][phx-value-type="photo"]|)`. Also assert the Delete button for that photo still exists if it renders today.

- [ ] **Step 2: Run the file and confirm the new tests fail.**

- [ ] **Step 3: Implement** the prefill for the three clauses, the three `update_entry/4` and `load_record/3` clauses, and `:if={entry.type != :photo}` on the Edit menu button.

- [ ] **Step 4: Run the file and confirm everything passes.**

- [ ] **Step 5: Run `mix format`, `mix compile --warnings-as-errors` and `mix test`. Expect 0 failures. Then commit:** `fix(timeline): edit life events, conversations and activities; hide photo edit`
