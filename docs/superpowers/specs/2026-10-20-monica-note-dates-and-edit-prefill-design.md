# Monica note dates + timeline edit-modal prefill

Date: 2026-10-20
Branch: `t3/monica-note-dates-edit-prefill` (from `feat/stack-40-consolidated` @ b8cdd4d)

## Why

Two bugs on the contact page timeline (`KithWeb.ContactLive.ActivityStreamComponent`):

1. **Imported Monica notes show today's date.** The timeline orders and labels notes
   by `note.inserted_at` (`Kith.Contacts.ActivityStream.normalize_note/1`). Both Monica
   import paths call `Contacts.create_note/3` with only `"body"`, so `inserted_at` is
   the moment of import. Monica's note payload carries `created_at` / `updated_at`
   (ISO 8601, e.g. `"2024-02-20T12:00:00Z"`), and the importer discards them.
   - Embedded notes (≤3 per contact): `Kith.Imports.Sources.MonicaApi.create_imported_note/4`
     (`lib/kith/imports/sources/monica_api.ex` ~L806).
   - Extra notes (paged `GET /api/contacts/:id/notes`):
     `Kith.Workers.MonicaMiscDataWorker.create_imported_note/4`
     (`lib/kith/workers/monica_misc_data_worker.ex` ~L261).

2. **The edit modal opens blank.** `handle_event("edit-entry", ...)` only sets
   `modal_type` / `modal_entry_id`. It never loads the record, and every
   `entry_modal_content/1` clause renders empty inputs (or "now"/"today" defaults for
   dates). This affects **every** entry type, not only notes. Saving a blank edit
   overwrites existing data. For example, a call's `occurred_at` resets to now and its
   notes get blanked.

## Goals

- Imported Monica notes get `inserted_at` = Monica `created_at` and `updated_at` =
  Monica `updated_at` on both import paths. Fall back to `created_at` when
  `updated_at` is missing, and to the current time when both are missing or unparseable.
- Opening Edit on any timeline entry shows the modal pre-filled with that record's
  current values: note, call, life event, task, gift, conversation, activity.
- Saving an edit works for every type whose Edit button is shown. Today
  `update_entry/4` only handles note/call/task/gift. Life event, conversation and
  activity return "Update not supported". Wire them to the existing context functions:
  `Activities.get_life_event!/2` + `update_life_event/2`,
  `Conversations.get_conversation!/2` + `update_conversation/2`,
  `Activities.get_activity!/2` + `update_activity/2`.

## Non-goals

- **No backfill of already-imported notes.** This was the user's decision: only new
  imports get original dates. Re-import dedupe (body match) stays as it is and does
  not touch timestamps on existing notes.
- No other Monica entities. Calls, activities and conversations already map their own
  date fields.
- No mapping of Monica `is_favorited` → `favorite`.
- No change to delete support for life event/conversation/activity.
- No photo edit (the photo modal is upload-only). *Builder's call:* hide the Edit
  item in the `…` menu for `:photo` entries so it can't open the upload modal.
- `NotesListComponent` (`notes_list_component.ex`) isn't mounted anywhere. Leave it alone.

## Anti-goals

- User-facing forms and the REST API must **not** be able to set `inserted_at` /
  `updated_at`. `Note.changeset/2` keeps its current cast list. Import timestamps go
  through an import-only path.
- Don't break the existing create flow. A new entry modal still opens empty, with
  today/now defaults where they exist.

## Constraints

- `notes.inserted_at` / `updated_at` are `:utc_datetime`, so truncate parsed values
  to the second.
- Tests: ExUnit, `@tag :integration` pattern as in existing tests
  (`test/kith/imports/sources/monica_api_test.exs`,
  `test/kith/workers/monica_misc_data_worker_test.exs`,
  `test/kith_web/live/contact_live/activity_stream_component_test.exs`).
  Fixture `note_json/1` already emits `created_at`. Make it overridable.
- `mix test` must pass with 0 failures before each commit. Commits must not include
  Co-Authored-By. **Do not push.**

## Decided how

- Add an import-only way to create a note with explicit timestamps. For example,
  `Contacts.create_note/4` takes an opts keyword list (`inserted_at:`, `updated_at:`),
  or a dedicated `Contacts.import_note/4` puts the timestamps on the struct/changeset
  directly instead of casting them. Both import call sites use it, with one shared
  Monica datetime parser rather than two copies.
- Prefill: on `edit-entry`, load the record (scoped by `account_id`, and for notes by
  `current_user_id`, the same as `update_entry`) and assign it, e.g. `:modal_record`.
  Pass it into `entry_modal_content` and render each input's `value` / `checked` /
  `selected` from it when present. Clear it in `close-modal`, `open-entry-modal` and
  after a successful save.
- The note body is shown as-is in the textarea. Notes created via this modal are
  plain text, and Monica notes are plain text/markdown.

## Left to the builder

- Datetime prefill uses UTC, matching the existing create defaults (`DateTime.utc_now()`), so saving without changes doesn't shift times.

- The exact function name/signature for the import-only note creation.
- Datetime-input formatting helpers (`datetime-local` needs `YYYY-MM-DDTHH:MM`, date
  inputs need ISO date). The activity modal's contact/emotion fields should keep
  their current behaviour; prefill only the fields the modal renders.
- Test granularity.
