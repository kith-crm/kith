# Release 0.5.0 Contact Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix CardDAV copying/sync, missing Monica contact fields, note editing/rendering, and timeline photo viewing in one PR against `release/0.5.0`.

**Architecture:** Repair existing import and DAV paths, then share a sanitized note renderer and a LiveView-safe Trix editor across contact note surfaces. Render photos through the existing storage abstraction and the app's modal primitives. Keep these as independent testable tasks within one release PR; do not refactor unrelated contact features.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/PostgreSQL, ExUnit/Req.Test, Trix 2, Alpine CSP, Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-release-contact-fixes-design.md`

## Global Constraints

- PR base: `release/0.5.0`; proposed branch: `fix/0.5.0-contact-import-notes-carddav`.
- Keep all reads, writes, imported reference types, tags, relationship targets, and photos inside the current account; preserve private-note visibility and existing permissions.
- Use the existing Phoenix LiveView, Alpine CSP, Trix, storage abstraction, and sanitizer. Do not add an editor framework or change unrelated screens.
- Preserve existing import identity mappings and rerun behavior. No automatic production reimport, reset, or deletion.
- Preserve existing public context return contracts when adding DAV invalidation.
- Run `mix test` successfully before each implementation commit; do not commit generated static files or unrelated local files.

## Review Focus

1. Same-second tag/relationship changes must alter ETags and appear in incremental sync (Tasks 5–6).
2. Partial/client-limited vCards must not erase CRM relationships or expose another account's contacts (Task 6).
3. Literal angle brackets, newlines, and hostile HTML in old/imported notes must display safely without losing text (Task 3).
4. Imported custom phone types must display and export, and reruns after prior partial imports must recover fields exactly once (Task 2).
5. Modal reopen, LiveView patching, clipboard rejection, and photo filenames containing quotes must work without stale state or unsafe Alpine expressions (Tasks 1, 4).

## Preparation

- [ ] Read the spec and repository `CLAUDE.md`; inspect current status and fetch `origin/release/0.5.0`. Create the proposed feature branch from that remote base, preserving unrelated untracked files. Carry these two planning documents onto the feature branch.
- [ ] Run baseline `mix test` and `mix assets.build`; record environmental failures separately from regressions. Inspect the existing browser auth/contact helpers before adding specs. Browser verification is an execution task; none has been run while writing this plan.
- [ ] Record the precise failing surface for each report. For the Monica case, first compare existing sanitized fixtures and available source responses with database field rows, type protocols, UI output, and exported vCards. If only the user's payload can reproduce a remaining omission, request a redacted affected contact payload at that point; continue the independently reproducible fixes.

### Task 1: Copy the displayed CardDAV URL reliably

**Files:** Modify `assets/js/alpine/copy_text.js`, `lib/kith_web/live/settings_live/integrations.ex`; create `test/playwright/carddav-copy.spec.ts`.

**Interfaces:** Keep Alpine `copyText.copy(): Promise<void>` and `copied: boolean`; add `copyFailed: boolean`. Read the value from the component root (`this.$root.dataset.copyValue`), not the event button.

- [ ] Add browser cases asserting copied text equals `#carddav-url`'s value, including after LiveView navigation. Assert `Copied!` appears only after a fulfilled write. Stub a rejected write and missing Clipboard API: no uncaught exception, no success state, and the readonly URL remains focusable/selectable with a visible manual-copy message.
- [ ] Run `npx playwright test --project=e2e test/playwright/carddav-copy.spec.ts`; confirm the relevant assertions fail on the current code.
- [ ] Implement root-bound value lookup, caught failures, and state reset on the next attempt. Use existing `copied` feedback and an accessible live status for failures; avoid unsupported inline CSP expressions and deprecated clipboard fallbacks.
- [ ] Rerun the spec and `mix test`; commit `fix: repair CardDAV URL copying` with only this task's files.

### Task 2: Preserve and recover Monica contact fields

**Files:** Modify `lib/kith/imports/sources/monica_api.ex`, `test/support/fixtures/monica_api_fixtures.ex`, `test/kith/imports/sources/monica_api_test.exs`; modify `lib/kith/vcard/serializer.ex` and `test/kith/vcard/serializer_test.exs` for protocol compatibility. Add import summary UI coverage in `test/kith_web/live/import_wizard_live_test.exs` if its presentation changes.

**Interfaces:** Preserve `MonicaApi.crawl/5` and existing summary keys. Resolve field types to account/global `ContactFieldType` records with canonical protocols (`tel`, `mailto`, `https`, `http`) from source metadata; retain unknown types as generic fields. Preserve `PhoneFormatter.normalize/2 -> {:ok, value | nil}` and the existing `normalize: false` field insertion path. Serializer accepts canonical and seeded protocol variants, including `tel:` and `mailto:`.

- [ ] Extend fixtures with source type/protocol metadata and field labels. Add named cases `imports_custom_phone_type_with_tel_protocol`, `preserves_phone_labels`, `exports_seeded_tel_colon_protocol`, and `rerun_recovers_missing_field_once`. Assert imported `+12025550100` is stored once, has a phone type, appears in contact details, and produces `TEL` in the vCard. Test local numbers with/without region, malformed nonblank phone text retained, null/blank fields, existing same-name generic types, and same-name types in another account. Exercise pagination/backfill and merge-survivor mappings using existing test helpers.
- [ ] Add a fixture matching each demonstrated source omission. Test missing versus explicitly empty embedded fields separately. Only add alternate-key/envelope handling or a per-contact fetch when evidence shows that source shape; a healthy embedded response must not trigger per-contact requests. A failed required fetch or rejected nonblank field must contribute to import diagnostics instead of silently reporting completion.
- [ ] Run `mix test test/kith/imports/sources/monica_api_test.exs test/kith/vcard/serializer_test.exs`; verify the new regression cases fail for the intended reasons.
- [ ] Fix extraction/type resolution once for both reference-data collection and child insertion, preserve labels, normalize protocols at the boundary, and normalize phone values once. Repair a legacy account-specific untyped type only when source metadata identifies it; do not mutate global seeds or unrelated user types. Thread field errors into the existing error-count/summary path without logging field values.
- [ ] Verify rerun behavior adds missing fields to the existing import mapping, preserves unrelated local fields, skips soft-deleted contacts, and avoids duplicate contacts/fields. Document a supported rerun recovery procedure and any evidence still needed; do not run it against production.
- [ ] Rerun targeted tests and `mix test`; commit `fix: preserve Monica contact field metadata and recovery`.

### Task 3: Restore note rich-text editing and rendering

**Files:** Modify `assets/css/app.css`, `assets/js/hooks/trix_editor.js`, `lib/kith/contacts/note.ex`, `lib/kith_web/live/contact_live/activity_stream_component.ex`, `lib/kith_web/live/contact_live/notes_list_component.ex`. Create `lib/kith_web/components/note_components.ex`, `test/kith/contacts/note_test.exs`, `test/playwright/contact-notes.spec.ts`; extend `test/kith_web/live/contact_live/show_test.exs`.

**Interfaces:** Add `KithWeb.NoteComponents.note_body/1` with required `body: String.t()` and `note_editor/1` with required unique `id`, `name`, and `value` string attributes. Timeline uses `name="entry[body]"`; legacy notes use `name="note[body]"`. Both components use a consistent `.trix-content` contract. Keep stored `Note.body` as a string; expose `Note.render_body(body) -> sanitized HTML string` for the display component, and keep changeset sanitization for writes.

- [ ] Add model/rendering cases asserting `<strong>bold</strong>`, `<em>italic</em>`, `<del>strike</del>`, `<pre>code</pre>`, headings, quotes, lists, links, and block/line breaks survive. Assert `"first\n\nsecond"` retains a blank line, `"x < 3 & y > 1"` retains its literal text, and scripts, event attributes, unsafe URLs, and embedded objects never render executable markup. Do not decode escaped imported HTML into executable elements.
- [ ] Add LiveView cases: editing loads the selected saved body and `is_private`; saving changes that note only; private notes remain hidden from other account users. The active timeline must render formatting rather than call `strip_html` on the note body. Keep plain-text summaries separate from the full body.
- [ ] Add browser cases using actual toolbar controls for bold/italic/strike/link/heading/quote/code and bulleted/numbered/nested lists. Assert persisted DOM (`strong`, `em`, `del`, `pre`, `ul li`, `ol li`), visible computed list markers, line separation, working undo/redo, and no visible unstyled toolbar-label run. Reopen the modal, cancel/reopen, edit two notes in succession, trigger a LiveView patch, and verify no stale content or overwritten typing. Cover narrow viewport and dark mode.
- [ ] Run `mix test test/kith/contacts/note_test.exs test/kith_web/live/contact_live/show_test.exs` and `npx playwright test --project=e2e test/playwright/contact-notes.spec.ts`; capture the intended failures.
- [ ] Import the installed Trix stylesheet into the Tailwind CSS build, followed by scoped theme/content overrides. Explicitly restore list markers, paragraph/block spacing, links, and code styling after Tailwind resets; do not rely on unconfigured `prose` utilities. Verify generated icon styling is included in the asset loaded by the root layout.
- [ ] Build the shared editor with a uniquely identified hidden input linked through Trix's `input` attribute and an ignored editor/toolbar DOM island. Initialize after Trix is ready, propagate edits to the form, and clean listeners on destruction. Only reload on a genuine external value/identity change; unrelated LiveView patches must not reset typing or selection. Disable unsupported file acceptance and hide attachment buttons.
- [ ] Load authorized note data for timeline editing, supply the saved body/privacy to the form, and keep invalid submissions populated. Update the sanitizer allowlist for Trix output, preserving plain text/newlines before HTML sanitization can discard literal characters. Render through the shared sanitized component; remove the fixed three-line clamp for note bodies. Render legacy plain text with preserved whitespace; do not infer Markdown from punctuation.
- [ ] Run targeted tests, `mix assets.build`, browser specs, and `mix test`; commit `fix: restore rich-text contact notes`.

### Task 4: Display timeline photos and open an accessible full-image modal

**Files:** Modify `lib/kith_web/live/contact_live/activity_stream_component.ex`, `lib/kith/contacts/activity_stream.ex`, `test/kith/contacts/activity_stream_test.exs`, `test/kith_web/live/contact_live/show_test.exs`; create `test/playwright/contact-photos.spec.ts`. Read existing modal primitives in `lib/kith_web/components/ui.ex` and `core_components.ex`; reuse them where suitable.

**Interfaces:** Resolve every image via `Kith.Storage.url(photo.storage_key)`. Add component events `open-photo` with `%{"id" => string}` and `close-photo`; maintain selected-photo state separately from entry-edit state. Fetch selected photos in the current account and verify `photo.contact_id == contact_id`.

- [ ] Add LiveView cases with filename `MqkbdPlbb5ChW49ifnLKWcchWDhOSQEGwSbIfKvb.jpeg`: the timeline and photos-only filter show an actual image URL, no filename heading, and a thumbnail button with accessible label `View photo`. Uncaptioned entries may use `Photo`; do not change the stored filename. Foreign-account/contact IDs must not open an image.
- [ ] Add browser cases uploading a fixture photo, opening it from the mixed timeline and photos-only filter, and checking the full image loads (`naturalWidth > 0`). Assert Escape, close button, and backdrop close; focus is contained and returns to the thumbnail. Cover a filename containing apostrophes/quotes and open/close after filtering/LiveView updates. Missing images should keep a usable label/fallback.
- [ ] Run `mix test test/kith/contacts/activity_stream_test.exs test/kith_web/live/contact_live/show_test.exs` and `npx playwright test --project=e2e test/playwright/contact-photos.spec.ts`; verify new failures.
- [ ] Replace placeholders with storage-backed thumbnails in both layouts, omit filename titles for photos, and implement one modal outside the entries loop using existing focus/close primitives. Pass photo IDs as data, never interpolate filenames/URLs into Alpine JavaScript. Reuse the same thumbnail and modal behavior across both filter modes.
- [ ] Rerun targeted tests, browser spec, and `mix test`; commit `fix: add timeline photo previews`.

### Task 5: Make CardDAV tags synchronize completely

**Files:** Modify `lib/kith/contacts.ex`, `lib/kith/dav/carddav_plug.ex`, `lib/kith/dav/vcard_adapter.ex` and `lib/kith/vcard/parser.ex` only where property-presence tracking needs it. Extend `test/kith/contacts_dav_test.exs`, `test/kith_web/dav/address_object_test.exs`, `test/kith_web/dav/report_test.exs`, `test/kith/vcard/parser_test.exs`.

**Interfaces:** Preserve `Contacts.tag_contact/2`, `untag_contact/2`, tag update/rename/delete/merge functions, and `replace_contact_children/3` return shapes. Keep wire property `CATEGORIES`, UID conventions, and existing sync tokens accepted. Mutation and contact DAV invalidation must commit atomically.

- [ ] Add GET/PUT/GET cases proving `Family`/`VIP` roundtrip; `CATEGORIES:` and omitted categories in a full replacement clear existing tags; repeats are deduplicated; escaped commas/semicolons/backslashes/Unicode roundtrip; another account's same-name tag is not reused. Assert rollback on an invalid category leaves the old representation intact.
- [ ] Add initial REPORT → mutation → incremental REPORT tests for tag assignment, removal, rename/update, delete, and merge. Assert every affected contact is returned, unrelated contacts remain unchanged, its ETag changes, and address-book change detection notices it. Include two mutations inside the same second and an edit overlapping REPORT execution; use controlled timestamps/test hooks, not sleeps.
- [ ] Run the DAV/parser test files above; verify meaningful failures. Audit actual mutation callers so changes in `rename_tag`, `update_tag`, `delete_tag`, `delete_tag_with_removal`, and `merge_tags` all invalidate affected contacts, including bulk joins.
- [ ] Implement atomic invalidation and true empty-list replacement. Remove blank categories before creation and preserve account boundaries. Fix second-resolution blind spots in ETag/change detection and incremental selection: equal-second changes must be reconsidered, representation ETags must distinguish actual changes, and the REPORT boundary must be captured before reading changes. Safe repeat responses are acceptable; dropped edits are not. Preserve old-token parsing. Tests determine whether timestamp precision alone suffices; never accept a timestamp-only change that still fails the same-second cases.
- [ ] Ensure ETag calculation agrees across GET, PROPFIND, multiget, REPORT, PUT response, and `If-Match`. Avoid per-contact association queries during collection requests by retaining shared DAV preloads. If correctness requires a persisted revision, add its migration/schema and tests in this task and document rollout; do not hide that dependency in a later PR.
- [ ] Rerun targeted tests and `mix test`; commit `fix: synchronize CardDAV tag changes`.

### Task 6: Repair the existing relationship sync paths

**Files:** Modify `lib/kith/contacts.ex`, `lib/kith/vcard/parser.ex`, `lib/kith/vcard/serializer.ex`, `lib/kith/dav/vcard_adapter.ex`; extend `test/kith/contacts_dav_test.exs`, `test/kith/vcard/parser_test.exs`, `test/kith/vcard/serializer_test.exs`, `test/kith_web/dav/address_object_test.exs`, and `test/kith_web/dav/report_test.exs`.

**Interfaces:** Reuse Task 5's DAV invalidation across `create_relationship/2`, `delete_relationship/1`, and relationship-type rename/update. Preserve grouped v3 `X-ABRELATEDNAMES`/`X-ABLabel` and v4 `RELATED;TYPE=...:urn:uuid:kith-contact-ID`. Track absent, empty, and nonempty relationship properties through parser/adapter; absent properties preserve existing CRM relationships.

- [ ] Add serialization and GET tests for existing forward and inverse relationships. Assert the inverse endpoint uses the reverse label, excludes deleted/foreign-account targets, and does not duplicate bidirectional imported pairs. Add initial/incremental REPORT tests for relationship creation/deletion, type-label change, and related-contact display-name change; every resource whose representation changes must receive an updated ETag.
- [ ] Add PUT cases: recognized same-account v4 UIDs map to existing contacts; malformed/foreign/self UIDs do not create links; v3 name-only values roundtrip without deleting UID-backed links; duplicate display names do not guess a target. A PUT omitting relationship properties preserves links, and an explicit supported empty relationship value clears them. Pin these compatibility semantics in parser and endpoint tests.
- [ ] Run the targeted DAV/vCard tests; verify new failures, then implement safe relationship merging/replacement and account-bound UID resolution. Reuse current bidirectional-label logic, adapting it for serialization rather than duplicating raw forward rows. Do not introduce name-based relationship creation or a new relationship model.
- [ ] Rerun targeted tests and `mix test`; commit `fix: repair existing CardDAV relationship sync`.

## Final verification and PR

- [ ] Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix quality`, `mix assets.build`, and `mix test`. Expected: clean formatting, no new warnings, all checks pass, zero test failures. Resolve failures caused by these changes and record any pre-existing environmental blockers precisely.
- [ ] With the application running, run `npx playwright test --project=e2e test/playwright/carddav-copy.spec.ts test/playwright/contact-notes.spec.ts test/playwright/contact-photos.spec.ts test/playwright/monica-import.spec.ts`. Expected: all pass against built assets, no unexpected browser errors. Include a minified-asset check for the Trix stylesheet/icons; backend-only tests cannot prove editor appearance or clipboard behavior.
- [ ] Confirm a fresh CardDAV download and an incremental client sync both carry tags/relationships/phones. Record the client/version and whether it displays the supported properties; distinguish client UI limitations from server wire failures.
- [ ] Self-review the diff for all seven spec requirements, account isolation, retained plain-text note content, and Monica rerun recovery. Obtain the review required by the selected execution workflow and fix findings before publishing the PR.
- [ ] Read the `pr` skill, push the feature branch, and create one PR titled `fix: repair contact imports, notes, photos, and CardDAV sync` with `--base release/0.5.0`. Include reproduced causes, test results, any schema rollout, import recovery instructions, and client-specific limitations. Immediately link the created PR through `link_pull_request` using its full URL. Do not merge or deploy as part of this task.

## Planning self-review

All seven requirements map to Tasks 1–6; relationship work is included because implementation exists. Interfaces preserve existing form names, storage URLs, import mappings, and context returns. The five review-focus conditions have explicit owner tests. Missing-phone payload variants remain an evidence-gathering gate within Task 2, not an asserted diagnosis. This plan contains no claim that the bugs have been reproduced in a browser or that verification has passed.
