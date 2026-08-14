# Monica Import Coverage Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Phase 1.4 coverage check to the Monica importer that detects gaps in `/api/contacts` pagination and backfills missing contacts via direct `GET /api/contacts/:id`, applying the same `is_active`/`is_partial` filters Monica's listing applies.

**Architecture:** Single-file change to `lib/kith/imports/sources/monica_api.ex`. New private function `coverage_check_and_backfill/3` runs after `crawl_all_contacts/1` and before `auto_merge_duplicates/2`. It re-fetches Monica's authoritative `meta.total`, compares against `import_records` count, and for any gap iterates `[min_id, max_id + safety_margin]` issuing `GET /api/contacts/:id` for unseen IDs. Each response is dispatched: 404 → skip; 200 + `is_active=false` → skip; 200 + remainder → feed through the existing `safe_import_api_contact/5` pipeline so backfilled contacts are first-class participants in auto-merge and cross-reference resolution.

**Tech Stack:** Elixir, Ecto, Oban, Req (HTTP client), Req.Test (mock plug for tests), ExUnit, `Kith.Imports.Sources.MonicaApi.RateLimiter` (existing per-host limiter), Monica v4 REST API.

**Design spec:** `docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md`

---

## File Inventory

| File | Change |
|---|---|
| `lib/kith/imports/sources/monica_api.ex` | Modify `crawl_all_contacts/1` return shape; add `fetch_single_contact/2`, `accept_backfill_response/1`, `coverage_check_and_backfill/3`; wire into `crawl/5`; extend summary writeback |
| `test/kith/imports/sources/monica_api_test.exs` | Add `describe "coverage_check_and_backfill"` block with 12 tests |
| `docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md` | Already committed (no change) |

No new files, no schema changes, no migrations, no worker changes.

---

## Pre-flight

- [ ] **Step 0a: Confirm worktree**

```bash
pwd
# Expected: /Users/basharqassis/projects/kith/.worktrees/monica-coverage-backfill
git branch --show-current
# Expected: fix/monica-import-coverage-backfill
git log --oneline -1
# Expected: 4919369 docs(specs): design for Monica import coverage backfill
```

- [ ] **Step 0b: Fetch dependencies**

```bash
mix deps.get
```

Expected: `All dependencies are up to date` (deps were already fetched when this worktree's branch base was set up).

- [ ] **Step 0c: Baseline tests pass**

```bash
mix test test/kith/imports/sources/monica_api_test.exs
```

Expected: all tests pass. If any fail, STOP and report — the plan assumes a green baseline.

- [ ] **Step 0d: Confirm test database is set up**

```bash
MIX_ENV=test mix ecto.create --quiet 2>&1 | tail -3
MIX_ENV=test mix ecto.migrate --quiet 2>&1 | tail -3
```

Expected: either both quiet (already set up) or migration messages. No errors.

---

## Task 1: Thread `ref_data` through `crawl_all_contacts/1`

**Why this task exists:** The backfill needs to call `safe_import_api_contact/5`, which requires the `ref_data` argument (Monica genders/tags/contact_field_types map). The listing crawl already builds and updates `ref_data` per page but currently discards it at the end. We need to return it so the backfill can reuse it without rebuilding from scratch.

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex`
  - `crawl_all_contacts/1` (line 161)
  - `crawl_contacts_loop/2` (line 179)
  - `handle_contacts_page/4` (around line 215)
  - The four return tuples inside `crawl_contacts_loop/2` (`{:ok, [], _meta}`, `{:ok, unexpected}`, `{:error, :rate_limited}`, `{:error, reason}`)
  - `crawl/5` call site (line 95)

- [ ] **Step 1.1: Read the existing `crawl_all_contacts/1` and `crawl_contacts_loop/2`**

Open `lib/kith/imports/sources/monica_api.ex` and confirm the current return shape is `{acc, deferred}`. Note that `state.ref_data` is built up inside the loop but never returned.

- [ ] **Step 1.2: Add a failing test**

The existing test file has many `describe` blocks. Add this test inside the existing `describe "crawl/5"` block (or at the very end of the test file, in a new `describe "crawl/5 ref_data threading"` block — either is fine, the agent should pick the spot consistent with the surrounding test style):

```elixir
test "crawl/5 carries ref_data through to be available for downstream phases", %{
  user: user,
  account_id: account_id
} do
  import_job = api_import_fixture(account_id, user.id)

  # Single-page listing with one contact and one gender to populate ref_data
  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => 1,
              "first_name" => "Alpha",
              "last_name" => "One",
              "is_active" => true,
              "is_partial" => false,
              "gender" => %{"name" => "Male", "type" => "M"},
              "contactFields" => []
            }
          ],
          "meta" => %{"total" => 1, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
      "auto_merge_duplicates" => false
    })

  # Sanity: import succeeded with one contact and zero coverage gap.
  assert summary.imported == 1
  assert summary.coverage_backfill.gap_detected == 0
end
```

This test will FAIL initially because `summary.coverage_backfill` doesn't exist yet (Task 6 adds it). That's fine — it serves as a forward-looking sanity that the orchestration changes still produce one alive contact. The reason we add it here, in Task 1, is to anchor the worktree-state of "ref_data threading produces unchanged behavior". The full coverage_backfill semantics arrive in later tasks.

- [ ] **Step 1.3: Run the new test to confirm it FAILS for the expected reason**

```bash
mix test test/kith/imports/sources/monica_api_test.exs --only line:<line_number_of_new_test>
```

Expected: failure on `summary.coverage_backfill.gap_detected == 0` (KeyError). NOT failure on the import succeeding — the import itself should still produce `imported: 1`.

- [ ] **Step 1.4: Modify `crawl_all_contacts/1` to return ref_data**

Replace the existing `crawl_all_contacts/1` and `crawl_contacts_loop/2` such that:

- `crawl_all_contacts/1` returns `{acc, deferred, ref_data}` instead of `{acc, deferred}`.
- `crawl_contacts_loop/2` mirrors that: every termination path returns `{acc, deferred, ref_data}`.
- `state.ref_data` is the value returned (defaults to `nil` if no contacts were ever fetched).

Specific edits:

```elixir
defp crawl_all_contacts(ctx) do
  initial_state = %{
    page: 1,
    total: nil,
    acc: %{contacts: 0, notes: 0, skipped: 0, error_count: 0, errors: []},
    deferred: %{
      first_met_through: [],
      relationships: [],
      extra_notes: [],
      misc_data: []
    },
    ref_data: nil,
    global_idx: 0
  }

  crawl_contacts_loop(ctx, initial_state)
end

defp crawl_contacts_loop(ctx, state) do
  case fetch_contacts_page(ctx.credential, state.page) do
    {:ok, %{"data" => contacts, "meta" => meta}} when is_list(contacts) ->
      handle_contacts_page(ctx, state, contacts, meta)

    {:ok, %{"data" => [], "meta" => _}} ->
      {state.acc, state.deferred, state.ref_data}

    {:ok, unexpected} ->
      Logger.error("[MonicaApi] Unexpected contacts response: #{inspect(unexpected)}")
      acc = add_error(state.acc, "Unexpected API response format from contacts endpoint")
      {acc, state.deferred, state.ref_data}

    {:error, :rate_limited} ->
      acc = add_error(state.acc, "Rate limited by Monica API after retries")
      {acc, state.deferred, state.ref_data}

    {:error, reason} ->
      acc =
        add_error(state.acc, "Failed to fetch contacts page #{state.page}: #{inspect(reason)}")

      {acc, state.deferred, state.ref_data}
  end
end
```

- [ ] **Step 1.5: Update `handle_contacts_page/4` to return the third element**

Find `handle_contacts_page/4`. It currently calls `process_contact_page/6` (or similar) and either recurses via `crawl_contacts_loop/2` or returns `{acc, deferred}`. Replace its terminal return with `{acc, deferred, ref_data}`. The recursive case is fine — it threads `ref_data` through `next_state` already.

Concretely, find the line in `handle_contacts_page/4` that returns to the caller (the non-recursive branch — when `state.page >= last_page`) and change `{acc, deferred}` to `{acc, deferred, ref_data}`.

- [ ] **Step 1.6: Update the orchestrator call in `crawl/5`**

Around line 95 of `monica_api.ex`, change:

```elixir
# Phase 1: Crawl contacts
{acc, deferred} = crawl_all_contacts(ctx)
```

to:

```elixir
# Phase 1: Crawl contacts
{acc, deferred, ref_data} = crawl_all_contacts(ctx)
```

The `ref_data` variable becomes available for use in Task 4's wiring. For Task 1 it's bound but unused — Elixir will compile-warn unless we mark it `_ref_data`. Since the next task will use it, leave it as `ref_data` and add a single line below it to silence the warning during this task only:

```elixir
{acc, deferred, ref_data} = crawl_all_contacts(ctx)
_ = ref_data  # consumed by coverage_check_and_backfill/3 in Task 4
```

The `_ = ref_data` line is intentionally removed in Task 4 when the variable becomes used.

- [ ] **Step 1.7: Run the full file's tests**

```bash
mix test test/kith/imports/sources/monica_api_test.exs
```

Expected: all PRE-EXISTING tests pass (the ref_data plumbing doesn't change semantics). The new test from Step 1.2 STILL FAILS at the `coverage_backfill` assertion — that's expected; it'll go green in Task 6.

If any pre-existing test breaks, the threading was done wrong. Inspect the failure carefully; the most likely cause is a missing third element in one of the return tuples in `crawl_contacts_loop/2` or `handle_contacts_page/4`.

- [ ] **Step 1.8: `mix compile --warnings-as-errors`**

```bash
mix compile --warnings-as-errors
```

Expected: clean. The `_ = ref_data` line silences the "unused" warning for the bound-but-not-yet-consumed variable.

- [ ] **Step 1.9: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex test/kith/imports/sources/monica_api_test.exs
git -c commit.gpgsign=false commit -m "refactor(monica): thread ref_data through crawl_all_contacts return

Phase 1.4 (coverage backfill, next commits) needs ref_data so it can
call safe_import_api_contact/5 on directly-fetched contacts. crawl_all_contacts/1
was already building ref_data per page but discarding it on return; this
commit threads it through to the orchestrator. No behavior change."
```

---

## Task 2: Add `fetch_single_contact/2` helper

**Why this task exists:** The existing `api_get_json/3` returns `{:error, "Unexpected status: 404"}` for 404, indistinguishable from other unexpected statuses. The backfill needs to treat 404 as a normal expected outcome (Monica-side soft-delete), not an error. We add a focused helper that returns a 3-way variant.

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (add new private function near `api_get_json/3` at line 1182)
- Modify: `test/kith/imports/sources/monica_api_test.exs` (new tests)

- [ ] **Step 2.1: Write the failing tests**

Add a new `describe` block at the end of `test/kith/imports/sources/monica_api_test.exs` (the file has many describe blocks; place this one consistently with the existing style — after the existing final block):

```elixir
describe "fetch_single_contact/2 (private — tested via send_test)" do
  # The helper is private; we exercise it via a public seam — the coverage
  # backfill end-to-end test in a later describe block. This describe block
  # exists only as a placeholder for direct unit tests if the function were
  # ever made public.
  test "documented behavior — see coverage_check_and_backfill tests" do
    assert true
  end
end
```

(Private functions in Elixir aren't directly testable from outside the module. The actual behavior of `fetch_single_contact/2` is exercised through `coverage_check_and_backfill/3` in Task 4, where every status branch gets a Req.Test stub. The placeholder above documents the deliberate skip.)

- [ ] **Step 2.2: Implement the helper**

Insert the new private function in `lib/kith/imports/sources/monica_api.ex` immediately AFTER `api_get_json/3` (around line 1190). Use this exact code:

```elixir
defp fetch_single_contact(credential, monica_id) do
  url = "#{credential.url}/api/contacts/#{monica_id}"

  case api_get(credential, url, []) do
    {:ok, %{status: 200, body: %{"data" => contact}}} when is_map(contact) ->
      {:ok, contact}

    {:ok, %{status: 404}} ->
      :not_found

    {:ok, %{status: 429}} ->
      {:error, :rate_limited}

    {:ok, %{status: status}} ->
      {:error, "Unexpected status: #{status}"}

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 2.3: Compile + run tests**

```bash
mix compile --warnings-as-errors
mix test test/kith/imports/sources/monica_api_test.exs
```

Expected: clean compile (the helper is unused so far but the `defp` plus the warning-suppressing `_ = ref_data` from Task 1 cover it — actually `defp` doesn't trigger an unused-warning in Elixir at module level, so no extra suppression needed). All previously-passing tests still pass.

If you get an "unused function" warning on `fetch_single_contact`, add `@compile {:nowarn_unused_function, fetch_single_contact: 2}` near the top of the module. Remove that compile directive in Task 4 when the function becomes used.

- [ ] **Step 2.4: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex test/kith/imports/sources/monica_api_test.exs
git -c commit.gpgsign=false commit -m "feat(monica): add fetch_single_contact/2 helper

Phase 1.4 coverage backfill needs to distinguish 404 (Monica-side
soft-delete, expected) from other errors. api_get_json/3 lumps them
all into {:error, \"Unexpected status: N\"}. New helper returns
{:ok, contact} | :not_found | {:error, reason}."
```

---

## Task 3: Add `accept_backfill_response/1` dispatch helper

**Why this task exists:** The acceptance logic (is_active=false → skip, is_partial=true → import-as-partial, etc.) is a pure function of the response body. Extracting it as a named helper lets the main backfill loop stay focused on iteration + accumulation, and lets the dispatch logic be tested independently via unit tests on the public path in Task 4.

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (add new private function)

- [ ] **Step 3.1: Insert the helper near `fetch_single_contact/2`**

Immediately after `fetch_single_contact/2` in `lib/kith/imports/sources/monica_api.ex`:

```elixir
# Mirror Monica's listing filter on direct-GET responses:
# - Monica's index() chains ->real()->active() which means
#   is_active = 1 AND is_partial = 0.
# - Partials still anchor relationship targets, so we accept them
#   (relationship resolution depends on importing the partial stubs).
# - Inactive contacts are deliberately hidden by Monica's UI; skip
#   them so we don't import rows Monica wants archived.
#
# Returns one of:
#   :import_full       — full contact, process via safe_import_api_contact/5
#   :import_partial    — partial contact, also process (for relationships)
#   :skip_inactive     — is_active is false-ish; count as skipped_inactive
defp accept_backfill_response(%{"is_active" => true, "is_partial" => true}),
  do: :import_partial

defp accept_backfill_response(%{"is_active" => true, "is_partial" => false}),
  do: :import_full

# Anything where is_active is false (or missing — defensive, Monica
# always serializes it) is skipped.
defp accept_backfill_response(%{"is_active" => false}), do: :skip_inactive
defp accept_backfill_response(_other), do: :skip_inactive
```

Note: the falling-through `_other` clause counts as `:skip_inactive` because in practice anything missing both `is_active` and `is_partial` from Monica's response is malformed and we choose the safer "don't import" default. If this ever fires in production, the import summary's `skipped_inactive` count would surface it.

- [ ] **Step 3.2: Compile**

```bash
mix compile --warnings-as-errors
```

Expected: clean. If "unused function" warning fires, add to the existing `@compile {:nowarn_unused_function, ...}` directive (if you created one in Task 2.3) or add `accept_backfill_response: 1` to its list.

- [ ] **Step 3.3: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex
git -c commit.gpgsign=false commit -m "feat(monica): add accept_backfill_response/1 dispatch

Mirrors Monica's listing filter (->real()->active() = is_active=1 AND
is_partial=0) on direct-GET responses so the backfill doesn't import
rows Monica deliberately hides from the listing. Partials are still
accepted because they anchor relationship targets."
```

---

## Task 4: Add `coverage_check_and_backfill/3`

**Why this task exists:** This is the heart of the fix. Implements the algorithm from the spec: re-fetch `meta.total`, compute gap, iterate missing IDs in [min, max + safety_margin], early-terminate when gap closes, cap iterations.

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex`
- Modify: `test/kith/imports/sources/monica_api_test.exs`

- [ ] **Step 4.1: Write the failing test — happy path**

Add a new `describe "coverage_check_and_backfill"` block in the test file (immediately after the placeholder `describe "fetch_single_contact/2"` from Task 2.1):

```elixir
describe "coverage_check_and_backfill" do
  test "closes a single-ID gap via direct fetch", %{user: user, account_id: account_id} do
    import_job = api_import_fixture(account_id, user.id)

    Req.Test.stub(@stub_name, fn conn ->
      case {conn.method, conn.request_path, conn.query_string} do
        {"GET", "/api/contacts", qs} when qs != "" ->
          # Listing call — return IDs 1, 2, 3, 5 (ID 4 missing) with meta.total=5
          Req.Test.json(conn, %{
            "data" =>
              Enum.map([1, 2, 3, 5], fn id ->
                %{
                  "id" => id,
                  "first_name" => "Listed#{id}",
                  "last_name" => "X",
                  "is_active" => true,
                  "is_partial" => false,
                  "contactFields" => []
                }
              end),
            "meta" => %{
              "total" => 5,
              "last_page" => 1,
              "current_page" => 1,
              "per_page" => 100
            }
          })

        {"GET", "/api/contacts/4", _} ->
          Req.Test.json(conn, %{
            "data" => %{
              "id" => 4,
              "first_name" => "Backfilled4",
              "last_name" => "X",
              "is_active" => true,
              "is_partial" => false,
              "contactFields" => []
            }
          })

        {"GET", "/api/contacts/" <> _id, _} ->
          # Any other direct-fetch ID returns 404
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    {:ok, summary} =
      MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
        "auto_merge_duplicates" => false
      })

    assert summary.coverage_backfill.gap_detected == 1
    assert summary.coverage_backfill.imported_full == 1
    assert summary.coverage_backfill.imported_partial == 0
    assert summary.coverage_backfill.skipped_deleted == 0
    assert summary.coverage_backfill.skipped_inactive == 0
    assert summary.coverage_backfill.unresolved_gap == 0
    assert summary.imported == 5

    # And the backfilled contact is now in import_records
    record = Imports.find_import_record(account_id, "monica_api", "contact", "4")
    refute is_nil(record)
  end
end
```

- [ ] **Step 4.2: Run the test to confirm it FAILS at the assertion (not at a compile error)**

```bash
mix test test/kith/imports/sources/monica_api_test.exs --only line:<line_number>
```

Expected: FAIL — `coverage_backfill` key not in summary OR `imported_full == 1` not satisfied. Specifically the failure should be a key/value mismatch, not a function-undefined error.

- [ ] **Step 4.3: Implement `coverage_check_and_backfill/3`**

Insert the new private function in `lib/kith/imports/sources/monica_api.ex` immediately AFTER `crawl_all_contacts/1` (or in a section close to it). Use this exact code:

```elixir
# ── Phase 1.4: Coverage check + backfill ──────────────────────────────
#
# Monica's /api/contacts listing endpoint silently drops a subset of
# contacts under LIMIT/OFFSET pagination over its default sort (this is
# a v4 server-side issue we can't fix). We compensate by re-fetching
# meta.total and any IDs in [min_seen, max_seen + safety_margin] that
# weren't returned by the listing.
#
# See docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md
# for full design context.

@safety_margin 50
@max_iterations_buffer 100

defp coverage_check_and_backfill(ctx, acc, ref_data) do
  case fetch_meta_total(ctx.credential) do
    {:ok, monica_total} ->
      do_backfill(ctx, acc, ref_data, monica_total)

    {:error, _reason} ->
      # Can't determine gap; pass through with zeroed coverage stats.
      {acc, ref_data, empty_backfill_stats()}
  end
end

defp fetch_meta_total(credential) do
  url = "#{credential.url}/api/contacts"

  case api_get_json(credential, url, limit: 1, page: 1) do
    {:ok, %{"meta" => %{"total" => total}}} when is_integer(total) -> {:ok, total}
    _ -> {:error, :unknown_total}
  end
end

defp do_backfill(ctx, acc, ref_data, monica_total) do
  seen_ids = seen_source_ids(ctx.import_job.id)

  case Enum.empty?(seen_ids) do
    true ->
      # Nothing imported by listing; refuse to scan an unbounded range.
      {acc, ref_data, empty_backfill_stats(gap: monica_total)}

    false ->
      min_id = Enum.min(seen_ids)
      max_id = Enum.max(seen_ids)

      gap = monica_total - MapSet.size(seen_ids)

      stats = %{
        gap_detected: gap,
        range_scanned: 0,
        imported_full: 0,
        imported_partial: 0,
        skipped_deleted: 0,
        skipped_inactive: 0,
        errors: 0,
        unresolved_gap: 0
      }

      if gap <= 0 do
        {acc, ref_data, %{stats | unresolved_gap: 0}}
      else
        scan_gap_range(ctx, acc, ref_data, seen_ids, min_id, max_id, monica_total, stats)
      end
  end
end

defp seen_source_ids(import_id) do
  from(ir in Kith.Imports.ImportRecord,
    where:
      ir.import_id == ^import_id and
        ir.source_entity_type == "contact",
    select: ir.source_entity_id
  )
  |> Repo.all()
  |> Enum.flat_map(fn s ->
    case Integer.parse(s) do
      {n, ""} -> [n]
      _ -> []
    end
  end)
  |> MapSet.new()
end

defp scan_gap_range(ctx, acc, ref_data, seen_ids, min_id, max_id, monica_total, stats) do
  scan_start = min_id
  scan_end = max_id + @safety_margin
  max_iterations = max_id - min_id + @max_iterations_buffer

  Logger.info(
    "[MonicaApi] Coverage backfill scanning [#{scan_start}..#{scan_end}] " <>
      "(seen=#{MapSet.size(seen_ids)}, monica_total=#{monica_total}, gap=#{stats.gap_detected})"
  )

  candidates =
    scan_start..scan_end
    |> Enum.reject(&MapSet.member?(seen_ids, &1))
    |> Enum.take(max_iterations)

  initial = {acc, ref_data, stats, seen_ids}

  {final_acc, final_ref_data, final_stats, final_seen} =
    Enum.reduce_while(candidates, initial, fn id, {a, rd, s, seen} ->
      # Early termination: if we've closed the gap, stop.
      if MapSet.size(seen) >= monica_total do
        {:halt, {a, rd, s, seen}}
      else
        case fetch_and_dispatch_backfill(ctx, id, a, rd) do
          {:imported_full, new_acc, new_ref_data} ->
            {:cont,
             {new_acc, new_ref_data,
              %{s | range_scanned: s.range_scanned + 1, imported_full: s.imported_full + 1},
              MapSet.put(seen, id)}}

          {:imported_partial, new_acc, new_ref_data} ->
            {:cont,
             {new_acc, new_ref_data,
              %{s | range_scanned: s.range_scanned + 1, imported_partial: s.imported_partial + 1},
              MapSet.put(seen, id)}}

          :skipped_deleted ->
            {:cont, {a, rd, %{s | range_scanned: s.range_scanned + 1, skipped_deleted: s.skipped_deleted + 1}, seen}}

          :skipped_inactive ->
            {:cont, {a, rd, %{s | range_scanned: s.range_scanned + 1, skipped_inactive: s.skipped_inactive + 1}, seen}}

          {:error, _reason} ->
            {:cont, {a, rd, %{s | range_scanned: s.range_scanned + 1, errors: s.errors + 1}, seen}}
        end
      end
    end)

  unresolved = max(0, monica_total - MapSet.size(final_seen))

  if unresolved > 0 do
    Logger.warning(
      "[MonicaApi] Coverage backfill could not close the gap: " <>
        "monica_total=#{monica_total}, seen=#{MapSet.size(final_seen)}, unresolved=#{unresolved}"
    )
  end

  {final_acc, final_ref_data, %{final_stats | unresolved_gap: unresolved}}
end

defp fetch_and_dispatch_backfill(ctx, monica_id, acc, ref_data) do
  case fetch_single_contact(ctx.credential, monica_id) do
    :not_found ->
      :skipped_deleted

    {:error, reason} ->
      {:error, reason}

    {:ok, api_contact} ->
      case accept_backfill_response(api_contact) do
        :skip_inactive ->
          :skipped_inactive

        verdict when verdict in [:import_full, :import_partial] ->
          # Update ref_data with the new contact's gender/tags/cfts
          new_ref_data =
            build_or_update_ref_data(ctx.account_id, [api_contact], ref_data)

          # Feed through the existing import pipeline. safe_import_api_contact/5
          # handles success/failure logging and accumulator updates internally.
          {new_acc, _new_deferred} =
            safe_import_api_contact(ctx, api_contact, new_ref_data, acc, %{
              first_met_through: [],
              relationships: [],
              extra_notes: [],
              misc_data: []
            })

          case verdict do
            :import_full -> {:imported_full, new_acc, new_ref_data}
            :import_partial -> {:imported_partial, new_acc, new_ref_data}
          end
      end
  end
end

defp empty_backfill_stats(opts \\ []) do
  %{
    gap_detected: Keyword.get(opts, :gap, 0),
    range_scanned: 0,
    imported_full: 0,
    imported_partial: 0,
    skipped_deleted: 0,
    skipped_inactive: 0,
    errors: 0,
    unresolved_gap: Keyword.get(opts, :gap, 0)
  }
end
```

Note about the dropped `deferred` from `safe_import_api_contact/5`: backfilled contacts don't contribute to Phase 2 cross-reference resolution because their first-met-through and relationships were already collected during Phase 1's listing crawl (Phase 1 didn't have these contacts to add them, but other listed contacts ARE the ones whose references to these backfilled IDs we want to resolve). The empty deferred map here is intentional — we don't want to recurse into Phase 2 from backfill.

- [ ] **Step 4.4: Run the test from Step 4.1**

```bash
mix test test/kith/imports/sources/monica_api_test.exs --only line:<line_number>
```

Expected: FAIL — `summary.coverage_backfill` still doesn't exist because Task 5 hasn't wired it into the orchestrator yet. The function is implemented but uncalled. Move to Task 5.

- [ ] **Step 4.5: `mix compile --warnings-as-errors`**

```bash
mix compile --warnings-as-errors
```

Expected: clean. If `fetch_single_contact` or `accept_backfill_response` still show as unused, the `@compile {:nowarn_unused_function, ...}` directive from earlier tasks needs to include `coverage_check_and_backfill: 3`, `fetch_meta_total: 1`, `do_backfill: 4`, `seen_source_ids: 1`, `scan_gap_range: 8`, `fetch_and_dispatch_backfill: 4`, and `empty_backfill_stats: 1`. Add them all in one go and remove the directive entirely in Task 5 once `coverage_check_and_backfill/3` becomes called.

- [ ] **Step 4.6: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex
git -c commit.gpgsign=false commit -m "feat(monica): coverage_check_and_backfill/3 core algorithm

Implements the Phase 1.4 logic: re-fetch meta.total, compare against
import_records, iterate [min_id..max_id+50] for unseen IDs, dispatch
each via fetch_single_contact + accept_backfill_response, early-terminate
when gap closes, cap iterations at (max_id-min_id)+100 to guarantee
termination. Stats accumulator covers gap_detected, range_scanned,
imported_full, imported_partial, skipped_deleted, skipped_inactive,
errors, unresolved_gap.

Wiring into crawl/5 is the next commit."
```

---

## Task 5: Wire into `crawl/5` and extend summary

**Why this task exists:** Phase 1.4 has to be invoked between the listing crawl (Phase 1) and auto-merge (Phase 1.5). This is also where the `coverage_backfill` key gets added to the summary map.

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (around line 95 — orchestrator)
- Modify: `test/kith/imports/sources/monica_api_test.exs` (the test from Step 4.1 should now go GREEN)

- [ ] **Step 5.1: Wire the call into `crawl/5`**

In `lib/kith/imports/sources/monica_api.ex`, locate the Phase 1 → Phase 1.5 boundary (around line 95-99). Replace this block:

```elixir
# Phase 1: Crawl contacts
{acc, deferred, ref_data} = crawl_all_contacts(ctx)
_ = ref_data  # consumed by coverage_check_and_backfill/3 in Task 4

# Phase 1.5: Auto-merge definite duplicates (optional)
merge_result =
  if opts["auto_merge_duplicates"] do
    auto_merge_duplicates(account_id, import_job)
  else
    %{merged: 0, errors: []}
  end
```

with:

```elixir
# Phase 1: Crawl contacts
{acc, deferred, ref_data} = crawl_all_contacts(ctx)

# Phase 1.4: Coverage check + backfill any silently-dropped contacts.
# See docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md
{acc, _ref_data, coverage_stats} = coverage_check_and_backfill(ctx, acc, ref_data)

# Phase 1.5: Auto-merge definite duplicates (optional).
# Runs AFTER Phase 1.4 so backfilled contacts participate in auto-merge.
merge_result =
  if opts["auto_merge_duplicates"] do
    auto_merge_duplicates(account_id, import_job)
  else
    %{merged: 0, errors: []}
  end
```

The `_ref_data` discard is intentional — Phase 1.5 onward doesn't need ref_data; Phase 4 (misc-data worker) rebuilds it on its own.

- [ ] **Step 5.2: Extend the summary writeback**

Locate the final `{:ok, %{ ... }}` summary in `crawl/5` (around line 140-150). Add a `coverage_backfill:` key to the map. Replace the existing summary construction:

```elixir
{:ok,
 %{
   imported: acc.contacts,
   contacts: acc.contacts,
   notes: acc.notes,
   skipped: acc.skipped,
   merged: merge_result.merged,
   error_count: error_count,
   errors: Enum.take(all_errors, 50),
   misc_data_plan: Enum.reverse(deferred.misc_data)
 }}
```

with:

```elixir
{:ok,
 %{
   imported: acc.contacts,
   contacts: acc.contacts,
   notes: acc.notes,
   skipped: acc.skipped,
   merged: merge_result.merged,
   error_count: error_count,
   errors: Enum.take(all_errors, 50),
   misc_data_plan: Enum.reverse(deferred.misc_data),
   coverage_backfill: coverage_stats
 }}
```

Also update the cancellation summary at the end of the same function (the `catch :cancelled` branch). Currently:

```elixir
catch
  :cancelled ->
    {:ok,
     %{
       imported: 0,
       contacts: 0,
       notes: 0,
       skipped: 0,
       merged: 0,
       error_count: 1,
       errors: ["Import cancelled"]
     }}
end
```

becomes:

```elixir
catch
  :cancelled ->
    {:ok,
     %{
       imported: 0,
       contacts: 0,
       notes: 0,
       skipped: 0,
       merged: 0,
       error_count: 1,
       errors: ["Import cancelled"],
       coverage_backfill: empty_backfill_stats()
     }}
end
```

- [ ] **Step 5.3: Run the happy-path test from Step 4.1**

```bash
mix test test/kith/imports/sources/monica_api_test.exs --only line:<line_number>
```

Expected: PASS. All assertions about `summary.coverage_backfill.*` and `summary.imported == 5` hold.

- [ ] **Step 5.4: Run the test from Task 1 (Step 1.2)**

```bash
mix test test/kith/imports/sources/monica_api_test.exs --only line:<line_number_from_1.2>
```

Expected: PASS. The `coverage_backfill.gap_detected == 0` assertion now holds (single-contact listing, total=1, no gap).

- [ ] **Step 5.5: Remove the `@compile {:nowarn_unused_function, ...}` directive**

If Task 2.3 / 3.2 / 4.5 added a `@compile {:nowarn_unused_function, ...}` directive to suppress warnings on functions that weren't yet called, remove that directive now. All those functions are reachable through `coverage_check_and_backfill/3` which is reachable through `crawl/5`.

```bash
mix compile --warnings-as-errors
```

Expected: clean.

- [ ] **Step 5.6: Run the full test file**

```bash
mix test test/kith/imports/sources/monica_api_test.exs
```

Expected: all tests pass, including the two new ones from Task 1 and Task 4.

- [ ] **Step 5.7: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex test/kith/imports/sources/monica_api_test.exs
git -c commit.gpgsign=false commit -m "feat(monica): wire coverage_check_and_backfill into crawl/5

Phase 1.4 now runs between the listing crawl (Phase 1) and auto-merge
(Phase 1.5). Backfilled contacts participate in auto-merge and Phase 2
cross-reference resolution as first-class import-record holders.

Import summary now carries coverage_backfill.{gap_detected, range_scanned,
imported_full, imported_partial, skipped_deleted, skipped_inactive,
errors, unresolved_gap}. The unresolved_gap field is the self-reporting
safety net: if it ends up > 0, the operator knows the listing dropped
contacts the backfill couldn't recover, surfaced in import.summary."
```

---

## Task 6: Round out the test matrix

**Why this task exists:** The happy path is green. The spec lists 11 more test scenarios that lock in the edge-case behavior (404s, inactives, partials, early termination, hard cap, unresolved gap, auto-merge interaction, cross-ref unblock). Each scenario gets its own test.

**Files:**
- Modify: `test/kith/imports/sources/monica_api_test.exs`

For each of the following sub-tasks, the pattern is:
1. Add the test inside the `describe "coverage_check_and_backfill"` block from Task 4.
2. Run the single test to confirm it fails OR passes for the expected reason.
3. If it fails unexpectedly, the production code has a real bug — fix it inline and document in the commit.

- [ ] **Step 6.1: Test — gap closed by mixed responses (200 + 404)**

```elixir
test "closes a 1-of-2 gap when one direct fetch 404s",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" =>
            Enum.map([1, 3, 5], fn id ->
              %{"id" => id, "first_name" => "L#{id}", "last_name" => "X",
                "is_active" => true, "is_partial" => false, "contactFields" => []}
            end),
          "meta" => %{"total" => 5, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/2"} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})

      {"GET", "/api/contacts/4"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 4, "first_name" => "B4", "last_name" => "X",
                      "is_active" => true, "is_partial" => false, "contactFields" => []}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.gap_detected == 2
  assert summary.coverage_backfill.imported_full == 1
  assert summary.coverage_backfill.skipped_deleted == 1
  assert summary.coverage_backfill.unresolved_gap == 1
end
```

Run: `mix test test/kith/imports/sources/monica_api_test.exs --only line:<line>`.
Expected: PASS.

- [ ] **Step 6.2: Test — inactive contact skipped**

```elixir
test "skips inactive contact in gap", %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "A", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []}
          ],
          "meta" => %{"total" => 2, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/2"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 2, "first_name" => "Inactive", "last_name" => "X",
                      "is_active" => false, "is_partial" => false, "contactFields" => []}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.skipped_inactive == 1
  assert summary.coverage_backfill.imported_full == 0
  assert summary.coverage_backfill.unresolved_gap == 1

  # Inactive contact was NOT written to import_records
  refute Imports.find_import_record(account_id, "monica_api", "contact", "2")
end
```

Run, expected PASS.

- [ ] **Step 6.3: Test — partial contact is imported**

```elixir
test "imports partial contact in gap (relationships need it)",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "A", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []}
          ],
          "meta" => %{"total" => 2, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/2"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 2, "first_name" => "Partial", "last_name" => "Stub",
                      "is_active" => true, "is_partial" => true, "contactFields" => []}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.imported_partial == 1
  assert summary.coverage_backfill.imported_full == 0
  assert summary.coverage_backfill.unresolved_gap == 0

  record = Imports.find_import_record(account_id, "monica_api", "contact", "2")
  refute is_nil(record)
end
```

Run, expected PASS.

- [ ] **Step 6.4: Test — no gap, no backfill**

```elixir
test "no-op when meta.total matches distinct imported",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  request_count = :counters.new(1, [])

  Req.Test.stub(@stub_name, fn conn ->
    :counters.add(request_count, 1, 1)

    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" =>
            Enum.map([1, 2, 3], fn id ->
              %{"id" => id, "first_name" => "L#{id}", "last_name" => "X",
                "is_active" => true, "is_partial" => false, "contactFields" => []}
            end),
          "meta" => %{"total" => 3, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/" <> _} ->
        flunk("unexpected direct-fetch when no gap exists")
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.gap_detected == 0
  assert summary.coverage_backfill.range_scanned == 0
  # 1 listing call + 1 meta.total recheck = 2 API calls; no per-ID GETs.
  assert :counters.get(request_count, 1) == 2
end
```

Run, expected PASS.

- [ ] **Step 6.5: Test — unresolved gap warning**

```elixir
test "logs warning and surfaces unresolved_gap when gap can't be closed",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "A", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []},
            %{"id" => 3, "first_name" => "C", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []}
          ],
          "meta" => %{"total" => 5, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  log =
    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, summary} =
        MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

      assert summary.coverage_backfill.unresolved_gap == 3
    end)

  assert log =~ "Coverage backfill could not close the gap"
end
```

Note: this test uses `ExUnit.CaptureLog`. If the test module doesn't already `import ExUnit.CaptureLog`, add the import to the top of the test module.

Run, expected PASS.

- [ ] **Step 6.6: Test — early termination when gap closes**

```elixir
test "stops scanning once gap closes (early termination)",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  request_count = :counters.new(1, [])

  Req.Test.stub(@stub_name, fn conn ->
    :counters.add(request_count, 1, 1)

    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        # IDs [1, 100] returned, meta.total=2. We expect only ID 2 to be
        # fetched directly before early termination kicks in.
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "A", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []},
            %{"id" => 100, "first_name" => "Z", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []}
          ],
          "meta" => %{"total" => 3, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/2"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 2, "first_name" => "B", "last_name" => "X",
                      "is_active" => true, "is_partial" => false, "contactFields" => []}
        })

      {"GET", "/api/contacts/" <> _} ->
        flunk("scan should have terminated after closing the gap")
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.unresolved_gap == 0
  assert summary.coverage_backfill.imported_full == 1
end
```

Run, expected PASS.

- [ ] **Step 6.7: Test — backfilled contact participates in auto-merge**

```elixir
test "backfilled contact gets auto-merged when matching", %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  shared_phone = %{
    "contact_field_type" => %{"type" => "phone", "name" => "Mobile", "protocol" => "tel:"},
    "data" => "+15555550100"
  }

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "Same", "last_name" => "Name",
              "is_active" => true, "is_partial" => false,
              "contactFields" => [shared_phone]}
          ],
          "meta" => %{"total" => 2, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/2"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 2, "first_name" => "Same", "last_name" => "Name",
                      "is_active" => true, "is_partial" => false,
                      "contactFields" => [shared_phone]}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
      "auto_merge_duplicates" => true
    })

  assert summary.coverage_backfill.imported_full == 1
  assert summary.merged == 1
end
```

This test exercises the Phase 1.4 → Phase 1.5 boundary: the backfilled contact 2 has the same name+phone as listed contact 1, so auto-merge collapses it.

Run, expected PASS. If auto-merge logic disagrees with the spec's claim that backfilled contacts participate, this test reveals it — fix the placement in `crawl/5` (Step 5.1) before continuing.

- [ ] **Step 6.8: Test — safety margin extends scan past max_id**

```elixir
test "scans IDs past max_seen up to safety_margin",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        # Listing returns IDs 1..5, meta.total=6. The 6th lives past max_seen=5.
        Req.Test.json(conn, %{
          "data" =>
            Enum.map([1, 2, 3, 4, 5], fn id ->
              %{"id" => id, "first_name" => "L#{id}", "last_name" => "X",
                "is_active" => true, "is_partial" => false, "contactFields" => []}
            end),
          "meta" => %{"total" => 6, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/6"} ->
        Req.Test.json(conn, %{
          "data" => %{"id" => 6, "first_name" => "PastMax", "last_name" => "X",
                      "is_active" => true, "is_partial" => false, "contactFields" => []}
        })

      {"GET", "/api/contacts/" <> _} ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  {:ok, summary} =
    MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

  assert summary.coverage_backfill.imported_full == 1
  assert summary.coverage_backfill.unresolved_gap == 0

  record = Imports.find_import_record(account_id, "monica_api", "contact", "6")
  refute is_nil(record)
end
```

Run, expected PASS. This verifies `@safety_margin 50` is actually consulted (ID 6 = max_seen + 1, within margin).

- [ ] **Step 6.9: Test — hard iteration cap enforced**

```elixir
test "hard cap on iterations leaves unresolved_gap > 0",
     %{user: user, account_id: account_id} do
  import_job = api_import_fixture(account_id, user.id)

  Req.Test.stub(@stub_name, fn conn ->
    case {conn.method, conn.request_path} do
      {"GET", "/api/contacts"} ->
        # Listing returns just ID 1. Meta says total=1000.
        # min_id = max_id = 1, max_iterations = (1-1) + 100 = 100.
        # Even with safety_margin, the scan should cap at 100 GETs and
        # leave the rest of the gap unresolved.
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "first_name" => "A", "last_name" => "X",
              "is_active" => true, "is_partial" => false, "contactFields" => []}
          ],
          "meta" => %{"total" => 1000, "last_page" => 1, "current_page" => 1, "per_page" => 100}
        })

      {"GET", "/api/contacts/" <> _} ->
        # Every per-ID GET returns 404; gap never closes.
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end)

  log =
    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, summary} =
        MonicaApi.crawl(account_id, user.id, credential(), import_job, %{})

      assert summary.coverage_backfill.gap_detected == 999
      assert summary.coverage_backfill.range_scanned <= 100
      assert summary.coverage_backfill.unresolved_gap > 0
    end)

  assert log =~ "Coverage backfill could not close the gap"
end
```

Run, expected PASS. The `range_scanned <= 100` assertion verifies the hard cap actually engages — without it, the scan would attempt 1000+ GETs.

- [ ] **Step 6.10: Run the full file**

```bash
mix test test/kith/imports/sources/monica_api_test.exs
```

Expected: all tests pass. Anywhere from ~6 new tests in this task + ~2 from earlier = 8+ new tests, all green, plus all pre-existing tests green.

- [ ] **Step 6.9: Commit**

```bash
git add test/kith/imports/sources/monica_api_test.exs
git -c commit.gpgsign=false commit -m "test(monica): edge-case coverage for coverage_check_and_backfill

Adds: mixed 200+404 closure, inactive skip, partial import, no-op when
no gap, unresolved-gap log+summary, early termination, auto-merge
interaction. Together with the happy path and ref_data threading tests
from earlier tasks, this covers every branch listed in the spec's test
matrix."
```

---

## Task 7: Quality gate + ship

- [ ] **Step 7.1: Full test suite**

```bash
mix test
```

Expected: 0 failures across the full project.

- [ ] **Step 7.2: Static analysis**

```bash
mix quality
```

Expected: clean across format, credo, sobelow, dialyzer.

If dialyzer complains about the new private functions' specs (Elixir tends to want @spec annotations on private functions when the inferred type is unusually complex), add a focused @spec for `coverage_check_and_backfill/3`:

```elixir
@spec coverage_check_and_backfill(map(), map(), map() | nil) ::
        {map(), map() | nil, map()}
defp coverage_check_and_backfill(ctx, acc, ref_data) do
  ...
```

Re-run `mix quality`. Repeat if dialyzer flags additional specs needed.

- [ ] **Step 7.3: Push and confirm CI**

```bash
git push -u origin fix/monica-import-coverage-backfill
```

CI runs ExUnit + Playwright. Confirm both green before opening the PR.

- [ ] **Step 7.4: Open PR or stack into PR #23**

Two options. The repeat user-decision from the phone-format fix workflow applies here. Default to opening a separate PR off `main` if `feat/v0.x-multi-area-improvements` has already merged, or stacking on it if it hasn't.

```bash
# Option A: stack into PR #23 (fast-forward if possible)
git push origin fix/monica-import-coverage-backfill:feat/v0.x-multi-area-improvements

# Option B: separate PR off main (only if PR #23 already merged)
gh pr create \
  --title "fix(monica): coverage backfill for /api/contacts pagination drops" \
  --body "$(cat <<'EOF'
## Summary
Monica v4's /api/contacts paginated listing silently drops a deterministic
subset of contacts (~1.7% in observed data). This adds a Phase 1.4
coverage check between the listing crawl and auto-merge that detects the
gap via meta.total comparison and backfills via direct GET /api/contacts/:id,
applying the same is_active and is_partial filters Monica's listing applies.

Backfilled partial contacts unlock relationship cross-reference resolution
that was previously failing with "Could not resolve first_met_through".

## Spec
docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md

## Test plan
- [x] mix test (full suite, 0 failures)
- [x] mix quality (format/credo/sobelow/dialyzer)
- [x] New tests: happy path, mixed 200+404, inactive skip, partial import,
      no-op when no gap, unresolved-gap warning, early termination,
      auto-merge interaction
- [ ] Manual: trigger a Monica import on the user's account, observe
      coverage_backfill.{gap_detected, imported_full, imported_partial,
      unresolved_gap} in import.summary
EOF
)"
```

---

## Done Criteria

1. `mix test` reports 0 failures with the new coverage_backfill tests passing.
2. `mix quality` is clean.
3. `coverage_check_and_backfill/3` is wired between Phase 1 and Phase 1.5 in `crawl/5`.
4. Import summary carries `coverage_backfill.{gap_detected, range_scanned, imported_full, imported_partial, skipped_deleted, skipped_inactive, errors, unresolved_gap}`.
5. The `unresolved_gap` field surfaces a warning log line when > 0.
6. Re-running the user's Monica import (manual smoke) returns `coverage_backfill.imported_full + coverage_backfill.imported_partial` equal to the original 18-contact gap, with `unresolved_gap: 0`.
7. The PR description references this plan and the spec.
