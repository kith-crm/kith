# Monica Import — Coverage Backfill Design

**Date:** 2026-05-17
**Status:** Draft
**Branch base:** `feat/v0.x-multi-area-improvements` (PR #23) or a follow-up off it

## Problem

Monica v4's `/api/contacts` listing endpoint silently drops a deterministic subset of contacts under certain conditions (observed: 18 of 1079 contacts missing in production data, ~1.7%). The cause is some interaction of MySQL `LIMIT/OFFSET` semantics with Monica's default `ORDER BY created_at` over rows whose sort-key values place them inside tie groups the engine resolves inconsistently across page boundaries. We were unable to find any explicit `WHERE` filter explaining the omissions:

- `address_book_id IS NULL` — verified for all observed missing rows
- `is_partial = 0` — verified
- `is_active = 1` — verified
- `deleted_at IS NULL` — verified (rows return 200 on direct GET)
- Default sort, ASC/DESC `created_at`, ASC/DESC `updated_at` — all variants drop the same ~18 rows
- `meta.total` reports 1079 (matches DB count of listable contacts) but distinct IDs returned across pagination = 1061

The drop is **invisible**: no error, no warning, `meta.total` matches the row count returned. The importer reports `imported: 1079, skipped: 0, errors: 3` (where the 3 errors are downstream cross-reference failures that themselves are caused by the missing contacts).

The user-visible symptom: Monica contacts that exist (verifiable via direct API GET and Monica's web UI) are absent from Kith after import. Cross-reference resolution (first_met_through, relationships) logs cryptic warnings about contacts not found in `import_records`.

## Goal

Make the Monica importer **self-verifying** for coverage. After the paginated listing crawl, compare its result against Monica's authoritative `meta.total`. For any gap, enumerate the missing IDs via direct `GET /api/contacts/:id` and feed them through the existing import pipeline — applying the same acceptance filters Monica's listing applies, so we don't accidentally import rows the listing deliberately hides.

Side benefit: **partial contacts (relationship-target placeholders) become importable**, closing the existing class of `"Skipping relationship X between A and B: one or both contacts not imported"` warnings.

## Non-Goals

- No CardDAV migration. The existing REST API pipeline stays.
- No changes to auto-merge logic. The 759 auto-merges observed in production are intentional given the user's Monica data shape (CardDAV-bug duplicates).
- No schema migration. No new account fields, no new contact columns.
- No retry-with-different-sort scheme. We already proved unioning 5 sort orders still yields 1061 distinct IDs for this account; throwing more pagination at the problem doesn't recover the lost rows.
- No deduplication of the backfilled contacts against the listing crawl result. The skip-already-seen check is by `source_entity_id`, not by name/email/phone heuristic.

## Design

### Where it fits in the pipeline

`Kith.Imports.Sources.MonicaApi.crawl/5` orchestrates several phases. The backfill is a new **Phase 1.4** between the listing crawl (Phase 1) and the auto-merge step (Phase 1.5):

```
Phase 1   crawl_all_contacts/1                 (listing — may drop rows silently)
Phase 1.4 coverage_check_and_backfill/2  ← NEW (recover missing IDs)
Phase 1.5 auto_merge_duplicates/2              (now sees backfilled contacts too)
Phase 2   resolve_cross_references/3           (now finds previously-missing references)
Phase 3   misc-data fetch                      (unchanged)
Phase 4   MonicaMiscDataWorker                 (unchanged)
```

Inserting before auto-merge means backfilled contacts are first-class citizens for the remainder of the pipeline — they can be auto-merge-evaluated, cross-reference-resolved, photo-synced.

### Algorithm

`coverage_check_and_backfill(ctx, listing_acc) :: {updated_acc, deferred}`

1. **Re-fetch `meta.total`** via `GET /api/contacts?limit=1&page=1`. This is the authoritative count of listable contacts at the moment we're checking. Use this rather than the `total` from the listing crawl because the listing's value may be stale if the crawl was long-running.

2. **Read what we have:** `SELECT source_entity_id::int, MIN(...), MAX(...) FROM import_records WHERE import_id = ? AND source_entity_type = 'contact'`. This gives us the seen-IDs set, plus the `min_id` and `max_id`.

3. **If `meta.total == count(distinct source_entity_id)`**, the listing was complete. Return `listing_acc` unchanged. Record `coverage_backfill: %{gap_detected: 0}` in the summary.

4. **Scan the gap:** for each integer `id` in `[min_id, max_id + safety_margin]` not in our seen-IDs set, issue `GET /api/contacts/:id`. `safety_margin = 50` to handle the case where `meta.total` is higher than our observed `max_id` (e.g., a contact added during the import that has the highest ID). Cap iterations at a hard limit of `max_id - min_id + 100` to guarantee termination.

5. **Per-response handling:**

   | HTTP status | Body shape | Action | Counter |
   |---|---|---|---|
   | 404 | — | Skip silently | `skipped_deleted` |
   | 200 | `is_active == false` | Skip | `skipped_inactive` |
   | 200 | `is_active == true && is_partial == true` | Process via `safe_import_api_contact/5` | `imported_partial` |
   | 200 | `is_active == true && is_partial == false` | Process via `safe_import_api_contact/5` | `imported_full` |
   | 429 / 5xx | — | Existing `RateLimiter` + Req retry | (existing behavior) |
   | other | — | Log warning, count as error | `errors` |

   Order of evaluation matters: `is_active == false` is checked **before** `is_partial`, so an inactive partial is skipped (consistent with Monica's listing, which applies both filters with AND semantics).

   **Not surfaced today:** Monica v4's `/api/contacts` listing also filters `address_book_id IS NULL`, but the API response body never exposes that column (confirmed via `ContactBase::toArrayInternal` source inspection). We have no client-side way to enforce that filter on direct-GET responses. The user has zero named address books in their account, so this is a no-op for the current data. Documented here so a future maintainer dealing with named-address-book accounts knows where to add the check.

6. **Early termination:** after each successful import (counter `imported_full` or `imported_partial` increments), recompute `total_distinct = count(distinct source_entity_id) in import_records`. If `total_distinct == meta.total`, break out of the scan loop. This is the typical termination — once we've recovered the missing rows, scanning the rest of the ID space is wasted work.

7. **Progress broadcasting:** broadcast `{:import_backfill_progress, %{checked: N, imported: M, remaining: K}}` on the existing `import:#{account_id}` topic every 10 IDs so the LiveView shows backfill activity (or, at minimum, doesn't appear frozen between Phase 1 and Phase 1.5).

8. **Summary writeback:** populate the import's `summary` map under a new `coverage_backfill` key (see below).

### Summary surface

The import job's `summary` gets a new nested map:

```elixir
%{
  # ...existing keys...
  coverage_backfill: %{
    gap_detected: 18,          # meta.total - count_distinct_at_start_of_phase_1.4
    range_scanned: 29,         # IDs we actually issued GETs for
    imported_full: 16,         # 200 + active + not-partial
    imported_partial: 2,       # 200 + active + partial
    skipped_deleted: 11,       # 404s (gaps in Monica's ID space — expected)
    skipped_inactive: 0,       # 200 + is_active=false
    skipped_addressbook: 0,    # 200 + address_book_id != null (defensive)
    errors: 0,                 # unexpected statuses / response shapes
    unresolved_gap: 0          # meta.total - count_distinct_at_end_of_phase_1.4
  }
}
```

**`unresolved_gap` is the self-reporting safety net.** If it ends up > 0, the import didn't fully recover and the operator can see this in the import summary. Without this field, the original bug was undetectable from the outside. Logging at `:warning` level when `unresolved_gap > 0`.

### Acceptance filter mirrors Monica's listing

The 200-with-active-and-not-partial OR partial-active path is the only path that creates an `import_record`. Inactive contacts (Monica-archived) and address-book-scoped contacts (future-proofing) are deliberately NOT imported, because their absence in the listing isn't a bug — it's the listing's intended filter.

### What changes in `import_api_contact_children` for partials

Existing partials in Monica's data model typically have:
- `first_name`, `last_name` set
- Empty `contact_fields`, no addresses, no notes, no relationships of their own

The existing `import_api_contact_children/7` handler gracefully no-ops on empty collections. No special-case branch needed in this spec — partials flow through the same pipeline as full contacts; they just end up with sparse data.

If a partial later becomes a full contact in Monica (the user fills it in), the next import will see it via the listing endpoint, call `handle_existing_contact/7` → `do_update_api_contact/7`, and merge the richer data into the existing Kith record. So the partial-stub state is forward-compatible with Monica's natural data evolution.

## Code Touchpoints

- `lib/kith/imports/sources/monica_api.ex`:
  - New private function `coverage_check_and_backfill/2`
  - New private function `fetch_single_contact/2` that returns `{:ok, body} | {:not_found} | {:error, reason}`
  - New private function `accept_backfill_response/1` that returns `:import_full | :import_partial | :skip_inactive | :skip_addressbook | :error`
  - Wire-up in the orchestrator (between Phase 1 and Phase 1.5) — single new function call
  - Summary-map writeback
- No changes to `MonicaApiCrawlWorker`, no changes to schemas, no changes to other workers

## Tests

`test/kith/imports/sources/monica_api_coverage_test.exs` (or additions to existing test files — to be confirmed in the plan):

1. **Happy path: gap detected and closed.** Mock listing returns IDs `[1, 2, 3, 5]` with `meta.total: 5`. Mock direct GET for ID 4 returns 200 + `is_active: true, is_partial: false`. Assert exactly one direct GET issued, contact imported, `import_records` count rises to 5, `unresolved_gap: 0`, `imported_full: 1`.

2. **Gap closed by mixed responses.** Listing returns `[1, 3, 5]`, `meta.total: 5`. Direct GET: ID 2 → 404, ID 4 → 200. Assert one 404 counted as `skipped_deleted`, one import. Early termination after ID 4.

3. **Inactive contact in gap is skipped.** Direct GET returns 200 + `is_active: false`. Assert no import_record created, `skipped_inactive: 1`, no error.

4. **Partial contact in gap is imported.** Direct GET returns 200 + `is_active: true, is_partial: true`. Assert import_record created, `imported_partial: 1`, contact written with `first_name`/`last_name` only.

5. **Address-book-scoped contact is skipped (defensive).** Direct GET returns 200 with a hypothetical `address_book_id: 7` (not in current API, but the filter exists). Assert `skipped_addressbook: 1`.

6. **No gap → no backfill.** Listing returns 5 distinct IDs, `meta.total: 5`. Assert zero direct GETs issued, summary shows `gap_detected: 0, range_scanned: 0`.

7. **Unresolved gap reported.** Listing returns `[1, 3]`, `meta.total: 5`. Direct GETs for 2 → 404, 4 → 404, 5 → 404. Assert `unresolved_gap: 2` in summary and a `:warning` log entry.

8. **Early termination.** Listing returns 8 IDs in range `[1, 100]`, `meta.total: 10`. Direct GETs for 9, 10 succeed (in numerical order). Assert scan stops after ID 10 and IDs 11-100 are NOT requested even though they're in `[min_id+safety, max_id+50]`.

9. **Safety margin.** Listing returns 5 IDs `[1..5]`, `meta.total: 6`. Direct GET for ID 6 succeeds. Assert backfill issued the GET despite ID 6 being one past the observed `max_id` (covered by `safety_margin`).

10. **Hard iteration cap.** Listing returns 1 ID `[1]`, `meta.total: 1000`. Assert backfill stops after `max_iterations = (max_id - min_id) + 100 = 100` GETs, logs a warning, leaves `unresolved_gap > 0`.

11. **Backfilled contact participates in auto-merge.** Listing returns 2 contacts. Direct GET for missing ID 3 returns a contact that's a duplicate (shared phone) of contact 1. Assert auto-merge runs after backfill and contact 3 is auto-merged into contact 1 (when `auto_merge_duplicates: true`).

12. **Backfilled partial unblocks relationship resolution.** Listing returns contact A whose `first_met_through_contact_id` points to contact B (which Monica's listing doesn't return because B is partial). Backfill imports B. Assert Phase 2's `resolve_first_met_through` succeeds for A → B (no warning logged).

## Risks

- **Performance:** ~30s additional API time per import for the user's data shape (28-30 GETs at 55/min). Larger gaps would scale linearly. The `max_iterations` cap prevents runaway scans on pathological data.
- **Monica's API surface drift:** if Monica adds a new listing filter we don't know about (e.g., a hypothetical `is_hidden` flag), the backfill would import rows Monica wants hidden. Mitigated by surfacing all `200` skips in the summary so an operator can audit unfamiliar fields. v5 is a separate code path anyway.
- **Auto-merge interaction:** backfilled contacts go through auto-merge after the listing-crawl contacts. If a backfilled contact has the same name+phone/email as an already-imported contact, it gets merged in. This is the correct behavior given auto-merge's existing semantics, but the user should be aware that backfilled-then-merged contacts will have a `local_entity_id` pointing at the survivor — same as any auto-merged contact.

## Acceptance Criteria

1. The 12 tests above pass.
2. `mix quality` passes (compile + format + credo + sobelow + dialyzer).
3. Re-running the user's Monica import with `auto_merge_duplicates: true` produces a summary where `coverage_backfill.imported_full + coverage_backfill.imported_partial` equals the original gap (18 in observed data).
4. Subsequent Phase 2 cross-reference resolution surfaces zero `"Could not resolve first_met_through"` and zero `"Skipping relationship ... one or both contacts not imported"` warnings whose target IDs are inside the backfilled set.
5. The `coverage_backfill.unresolved_gap` field is visible in the import job's `summary` map and surfaces in the import wizard UI (or at minimum in the worker logs).
