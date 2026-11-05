# PR 51 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Fix the four review findings without changing default Monica rerun behavior or overwriting local field metadata.

**Architecture:** Use logical CSS for existing Trix surfaces and a shared pure protocol-token normalizer for importer/exporter consistency. Recover missing labels using account-scoped source mappings, preserving nonblank local labels and distinct source fields.

**Tech Stack:** Elixir, Ecto, ExUnit, Phoenix, Trix, Tailwind CSS.

**Spec:** `docs/superpowers/specs/2026-11-02-release-contact-fixes-design.md`, requirements 2–4 and constraints; `docs/frontend-conventions.md` sections 3 and 6; PR 51 review findings in this session.

## Global Constraints

- Keep all reads, writes, imported reference types, tags, relationship targets, and photos inside the current account; preserve private-note visibility and existing permissions.
- Preserve existing import identity mappings and rerun behavior. No automatic production reimport, reset, or deletion.
- Preserve existing public context return contracts when adding DAV invalidation.
- Use CSS logical properties for spacing and positioning. Maximum heading weight is 600.
- No new dependencies, schema migrations, production requests, or generated static files.
- Run `mix test` successfully before each implementation commit; do not commit generated static files or unrelated local files.

### Task 1: Correct Trix styles and share protocol normalization

**Files:** Modify `assets/css/app.css`, `lib/kith/imports/sources/monica_api.ex`, `lib/kith/vcard/serializer.ex`; create `lib/kith/contacts/field_protocol.ex`, `test/kith/contacts/field_protocol_test.exs`.

**Interfaces:** Produce `Kith.Contacts.FieldProtocol.normalize/1`: binary -> trimmed lowercase protocol token, nil -> nil. Importer retains its own allowed-protocol classification. Serializer retains existing dispatch/fallback behavior.

- [x] Add pure ExUnit coverage before implementation:

```elixir
assert FieldProtocol.normalize(" TEL:// ") == "tel"
assert FieldProtocol.normalize("mailto:") == "mailto"
assert FieldProtocol.normalize(" HTTPS ") == "https"
assert FieldProtocol.normalize("custom:") == "custom"
assert FieldProtocol.normalize(nil) == nil
```

- [x] Run `mix test test/kith/contacts/field_protocol_test.exs`; establish the expected undefined-function/module failure once dependencies are installed.
- [x] Implement the helper and replace only the duplicated normalization pipelines:

```elixir
def normalize(nil), do: nil
def normalize(protocol) when is_binary(protocol) do
  protocol
  |> String.trim()
  |> String.downcase()
  |> String.trim_trailing("://")
  |> String.trim_trailing(":")
end
```

- [x] Replace Trix `padding-left`, `border-left`, `margin-right` with `padding-inline-start`, `border-inline-start`, `margin-inline-end`; set heading weight 700 to 600. Inspect the scoped CSS against frontend conventions. Do not add tests mirroring these low-impact CSS declarations.
- [x] Run helper, serializer, and Monica tests; `mix format --check-formatted`; full `mix test` before committing. If environment setup fails, record exact blocker and leave edits uncommitted instead of bypassing the repository rule.
- [x] Self-review, report test evidence, commit as `fix: align note styles and share field protocol normalization` only when allowed by the test rule.

### Task 2: Recover missing Monica labels without losing source identity

**Files:** Modify `lib/kith/imports/sources/monica_api.ex`, `test/kith/imports/sources/monica_api_test.exs`, and `docs/monica-field-recovery.md`.

**Interfaces:** Consume `FieldProtocol.normalize/1` from Task 1. Keep `MonicaApi.crawl/5` and existing summary/error contracts. Use `Imports.find_import_record(account_id, "monica_api", "contact_field", uuid)` for source identity and `Contacts.update_contact_field/2` for coordinated writes; verify signatures first.

- [x] Add recovery regression using existing `stub_fields`, `mapped_contact`, and `api_import_fixture` helpers. Import a UUID-bearing field with no label, finish its import, then provide the same UUID/type/value with `"Work"` and run with `"recover_contact_fields" => true` twice. Assert same contact ID, same field ID, `label == "Work"`, one field, original mapping, zero errors, and exported `TYPE=WORK`.
- [x] Add regressions for default skip-existing (no label change), nonblank locally edited labels (preserved), distinct UUIDs sharing value/type but labels `"Work"` and `"Home"` (both retained once across reruns), absent UUID (label-aware idempotency), and foreign/stale field mappings (never update another account/contact). Use actual DB records, not mocked context returns.
- [x] Run `mix test test/kith/imports/sources/monica_api_test.exs`; confirm new behavioral tests fail before changing importer.
- [x] Replace the boolean duplicate shortcut with source-aware reconciliation: validate mapped field ownership/contact/type/value; fill only blank labels on verified imported matches during opt-in recovery; never overwrite a nonblank label or change mapped values/types. Treat a valid existing source identity as already represented even if its local label changed. For unmapped entries deduplicate by normalized value/type and label; distinct nonblank labels represent distinct fields. Never adopt an unrelated local unlabeled field for metadata mutation. Propagate failed writes through existing redacted error reporting. Preserve existing mappings and no-duplicate semantics for identical unlabeled fields.
- [x] Update recovery documentation to describe blank-label recovery and preservation of local labels. Do not claim missing source metadata can be reconstructed.
- [x] Run `mix test test/kith/imports/sources/monica_api_test.exs test/kith/vcard/serializer_test.exs`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, and full `mix test` before committing. Record command output and any setup blockers.
- [x] Self-review, report test evidence, commit as `fix: recover missing Monica field labels safely` only when the full test rule passes.

## Completion

- [x] Review each task for spec compliance and code quality with a fresh reviewer.
- [ ] Review the complete fix diff against the pinned starting HEAD `1fcaf0d527152d6ae899894c27eab2074743fa21`.
- [ ] Report validation and remaining limitations. Leave the work on this isolated branch for review; pushing or merging is outside this request.

## Execution evidence

- Task 1: `82cc3c1`, with reviewed fallback/RTL corrections in `6e59ccb`. Fresh scoped re-review passed spec and quality.
- Task 2: `f60f301`; fresh task review approved spec and quality.
- Final implementation suite: 2,537 tests, zero failures; focused suite 132/0; formatting and warnings-as-errors compile passed.
- Asset build blocked by pre-existing missing `assets/vendor/heroicons`; no generated files committed.
- Final complete-fix review pending at plan-recording time.
