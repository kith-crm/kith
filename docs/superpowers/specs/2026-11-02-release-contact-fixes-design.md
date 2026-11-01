# Release 0.5.0 contact fixes

**Source:** User bug report, 2026-11-02. **Delivery:** One new fix PR targeting `release/0.5.0`.

## Required behavior

1. The CardDAV URL Copy button copies the displayed URL exactly and reports success only after copying succeeds. Clipboard rejection or unavailability leaves a usable manual-copy route.
2. Monica imports retain available contact information, especially phone numbers, their field types, and labels. A rerun can add previously omitted fields to the existing imported contact without duplicate contacts or fields. Unparseable phone text is retained. Missing source data must not be invented.
3. Contact timeline note creation and editing use a styled rich-text editor. Edit loads the saved body and privacy setting. Bold, italic, strike, links, headings, quotes, code, bulleted and numbered lists, nesting, undo, and redo work and survive saving/reopening. Unsupported attachment controls are hidden until an upload flow exists.
4. Timeline notes preserve paragraph breaks, line breaks, and supported formatting. Existing plain-text notes retain their literal text and newlines. HTML rendering remains sanitized. Do not interpret every plain-text note as Markdown or run a destructive format migration.
5. Timeline photos display actual thumbnails, with no storage filename/hash as a visible title. Clicking a thumbnail opens the full image in a popup. The popup has an accessible name, keyboard-operable controls, Escape/backdrop close, focus containment, and focus return. The photos-only filter behaves the same way.
6. Tags sync in both directions through CardDAV. Add, remove, rename, delete, and merge operations reach incremental-sync clients. Empty categories remove tags. Duplicate categories do not create duplicate tags.
7. Relationships are already implemented, so repair their existing sync paths. Preserve existing vCard 3.0 related-name and vCard 4.0 UID representations. Do not create contacts by guessing from nonunique display names. A client PUT that omits unsupported relationship properties must not erase existing CRM relationships.

## Constraints

- PR base: `release/0.5.0`; proposed branch: `fix/0.5.0-contact-import-notes-carddav`.
- Keep all reads, writes, imported reference types, tags, relationship targets, and photos inside the current account; preserve private-note visibility and existing permissions.
- Use the existing Phoenix LiveView, Alpine CSP, Trix, storage abstraction, and sanitizer. Do not add an editor framework or change unrelated screens.
- Preserve existing import identity mappings and rerun behavior. No automatic production reimport, reset, or deletion.
- Preserve existing public context return contracts when adding DAV invalidation.
- Run `mix test` successfully before each implementation commit; do not commit generated static files or unrelated local files.

## Evidence and remaining questions

Inspected local `release/0.5.0` at `dbc7fd8`. These are code observations, not browser reproductions:

- `copy_text.js` reads `this.$el.dataset.copyValue`, while the attribute is on the surrounding `x-data` element and the handler runs on its button. There is no rejection handling.
- `assets/css/app.css` does not include Trix CSS or typography styles; Tailwind resets list markers. The Trix hook imports JavaScript only.
- `show.html.heex` mounts `ActivityStreamComponent`. Its note form is a textarea without a bound saved body; the separate `NotesListComponent` uses Trix. This differs from the reported deployed modal, so reproduce both the release implementation and the reported path.
- Timeline rendering calls `strip_html(entry.body)` and uses a three-line clamp. Photo entries use `photo.file_name` as a title and render placeholders rather than storage URLs.
- `Note.Scrubber` allows much of rich text but omits Trix `div`, `del`, and `pre`/`code` output. Plain-text versus HTML representation needs an explicit compatibility path.
- Monica field ingestion reads only `contactFields`, resolves types by name, creates new types with only a name, and drops field labels. Field creation failures are logged without contributing to the import summary. Actual missing-phone payloads have not been examined; do not declare a payload shape or pagination bug proven.
- The serializer handles bare protocols such as `tel`, while other code explicitly accommodates seeded forms such as `tel:`. Distinguish an absent database field from a stored field omitted during export/display.
- CardDAV already preloads/serializes tags and relationships and parses/replaces both. Tag and relationship mutations do not invalidate contact timestamps. ETags and sync tokens use seconds; incremental selection uses strict `updated_at > token`. Empty categories currently do nothing. Relationships exported as v3 names cannot be resolved by the UID-only import path.

## Acceptance

Each requirement has a regression test plus targeted verification. Browser tests exercise actual toolbar actions, computed list styles, clipboard contents, note persistence, thumbnails, and modal behavior. DAV tests exercise GET/PUT/REPORT, with edits inside one second as well as across seconds. Import tests assert database fields, type protocols, display/export, summary diagnostics, and idempotent reruns. The PR records which causes were reproduced and any client-specific limitations.
