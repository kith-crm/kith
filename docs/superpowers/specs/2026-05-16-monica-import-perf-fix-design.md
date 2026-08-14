# Monica import performance fix — design

**Status:** approved
**Date:** 2026-05-16
**Branch:** `fix/duplicate-detection`
**Builds on:** commit `6af91bf` (the bug-fix that unleashed Phase 4)

## Context

The bug-fix commit `6af91bf` restored a previously broken contract: `MonicaApiCrawlWorker.build_opts/1` now forwards every wizard option to `MonicaApi.crawl/5`, not just `extra_notes`. That fix was correct — auto-merge, pets, calls, activities, gifts, debts, tasks, reminders, conversations were all designed to be controllable from the wizard, but `build_opts/1` was silently dropping them.

The consequence: a per-contact phase that had been an unreachable no-op for the wizard UI's entire lifetime suddenly fires **eight HTTP endpoints per imported contact**. For a 1000-contact account that is 8000 API calls against Monica's default 60-req/min rate limit. Imports went from ~2 minutes (Phase 1 only) to multi-hour stalls, made worse by a double retry layer that resets its inner counter every outer retry — the symptom users see as "retry: got response with status 429, will retry in 59000ms, 3 attempts left" repeating forever.

This design fixes that, plus a small handful of pre-existing and self-inflicted perf issues that compound the problem.

### Problems being addressed

1. **Phase 4 explosion** *(primary user-visible regression)*
   `import_extra_data_types/5` walks every imported contact and fires up to 8 endpoints per contact unconditionally. There is no statistics-based short-circuit (unlike Phase 3 for notes), so contacts with zero pets/debts/gifts still incur a round-trip per endpoint. With ~1000 contacts × 8 endpoints = 8000 calls, the import cannot complete under Monica's default rate limit in reasonable wall-clock time.

2. **Double retry layering** *(amplifier)*
   `api_get_json_with_retry/4` (custom 65-second sleep loop, max 3 outer retries) wraps `Req.get`, which itself has built-in `:safe_transient` retry (max 3 inner retries, respects `Retry-After`). On a 429 these stack: up to 12 retry rounds for a single logical call, with up to ~12 minutes of cumulative sleep. The "3 attempts left always" log is the outer layer kicking off fresh inner-layer attempts.

3. **No proactive throttle** *(amplifier)*
   We make calls as fast as the BEAM lets us until Monica refuses. Every 429 burst then wastes a 59-second `Retry-After` window before traffic resumes.

4. **`:persistent_term` global-GC storm** *(self-inflicted in PR 6af91bf)*
   `phone_field_type?/1` caches one boolean per cft_id via `:persistent_term.put/2`. Each new key triggers a global GC of every BEAM process. On a cold import we warm 5-8 cft_ids back-to-back, stopping the world (LiveView, PubSub, PromEx, every Oban worker) each time.

5. **Double libphonenumber normalization** *(self-inflicted)*
   `MonicaApi.import_single_contact_field` normalizes via `PhoneFormatter.normalize/2`, then `Contacts.create_contact_field/2` calls `maybe_normalize_phone/1` which normalizes the already-canonical value again. Per phone field this is one wasted libphonenumber parse plus one wasted `Repo.get(ContactFieldType, cft_id)` DB round trip.

6. **Pre-existing per-write `Repo.get` in `maybe_normalize_phone`** *(amplifier, not in scope here)*
   `Contacts.maybe_normalize_phone/1` looks up the ContactFieldType per call to discover the protocol. For 5000 field writes that's 5000 DB queries. Not introduced by recent work; we sidestep it for the Monica path only.

## Goal

1. Restore the Monica import to a reasonable wall-clock runtime — Phase 1+2+3 should complete in minutes for ~1000 contacts; Phase 4 should run in the background and only fire endpoints that actually have data.
2. Eliminate the double-retry layering so a single 429 doesn't cascade into multi-minute log loops.
3. Add a client-side throttle so 429s become rare under normal Monica defaults.
4. Pay back the perf debt introduced in commit `6af91bf` (persistent_term GC storm, double normalization).

**Out of scope** (noted for follow-up):
- Fixing `maybe_normalize_phone`'s per-write `Repo.get` for UI/API callers (still a per-field DB query for non-Monica paths, but Monica is the only path that creates fields at bulk scale).
- Account-locale-derived region for UI form phone writes (currently UI writes leave bare numbers untouched).
- Auto-detection of Monica's actual rate limit (defaults are hand-configured).
- Batched per-contact fetches via Monica's `?include=...` if/when supported.

## Approach

### Part 1 — Extract Phase 4 into a dedicated worker

**New worker:** `Kith.Workers.MonicaMiscDataWorker`, queue `:imports`, max attempts 3, timeout 30 minutes.

A single Oban job per import (not per contact). Takes args:
```elixir
%{
  "import_id" => integer,
  "credential_url" => string,
  "credential_api_key" => string,   # same wipe-after-completion pattern as MonicaPhotoSyncWorker
  "plan" => [%{"source_id" => integer, "local_id" => integer, "endpoints" => [string]}, ...]
}
```

Worker logic:
1. Load `import_job`; bail early if `status == "cancelled"`.
2. Iterate `plan` entries.
3. For each entry, load the local contact (`Repo.get`); skip if `deleted_at != nil`.
4. For each endpoint in the entry's list, call the corresponding fetch helper (e.g. `import_contact_pets/6`).
5. Accumulate per-endpoint counts (e.g. `%{pets: 17, calls: 4, activities: 0, ...}`).
6. After completion, update `import_job.summary` with a new `"misc"` key holding the counts. Broadcast via the existing PubSub topic `"import:#{account_id}"` so the wizard UI sees the update.

The per-contact `import_contact_pets/calls/activities/gifts/debts/tasks/reminders/conversations` helpers move verbatim from `MonicaApi` into the new worker module. Their internals are unchanged.

**`MonicaApi.crawl/5` changes:**
- Phase 4 (`import_extra_data_types/5`) deleted.
- The `crawl/5` return value's `summary` map gains a new key `:misc_data` (the plan list). Caller `MonicaApiCrawlWorker` consumes this to construct the misc worker's args.

**`MonicaApiCrawlWorker.perform/1` changes:**
- After `Imports.update_import_status(:completed)`, alongside the existing `MonicaPhotoSyncWorker` enqueue, enqueue `MonicaMiscDataWorker` with the plan from `summary[:misc_data]`.
- The plan is removed from the persisted summary before writing (it's transit data, not a metric).

### Part 2 — Throttle: Hammer-backed rate limiter

**New module:** `Kith.Imports.Sources.MonicaApi.RateLimiter`.

Single public function `wait!(host)`. Wraps `Hammer.check_rate(bucket, scale_ms, limit)` with:
- Bucket key: `"monica_api:#{URI.parse(url).host}"` — per-host so independent Monica instances don't share a quota.
- Scale: 60_000 ms.
- Limit: configurable via `Application.get_env(:kith, :monica_rate_limit, 55)`.

55 is one token below Monica's documented default of 60/min, leaving safety margin.

On `{:deny, _}`, sleep ~1100ms and recurse. (The `:deny` carries a retry-after but Hammer 6.x returns the bucket reset time, which can be over-conservative; a fixed small sleep paces us back into the window naturally.)

**Call site:** `MonicaApi.api_get/3` calls `RateLimiter.wait!(credential.url)` before every `Req.get`. The new misc worker's helpers go through the same `api_get`, so they're throttled too.

**Config:**
- `config/config.exs`: `config :kith, :monica_rate_limit, 55`.
- `config/test.exs`: `config :kith, :monica_rate_limit, 1_000_000` — effectively unthrottled so tests don't sleep. Throttle logic itself is exercised via its own test file with a temporarily lowered limit.

### Part 3 — Retry: collapse to Req's built-in only

**Delete:**
- `MonicaApi.api_get_json_with_retry/4` (lines 1109-1137 of current monica_api.ex)
- `@max_rate_limit_retries 3`
- `@rate_limit_sleep_ms :timer.seconds(65)`

**Replace** `api_get_json/3` with a direct version:
```elixir
defp api_get_json(credential, url, params) do
  case api_get(credential, url, params) do
    {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
    {:ok, %{status: status}} -> {:error, {:http, status}}
    {:error, reason} -> {:error, reason}
  end
end
```

**Update** `api_get/3` to configure Req's retry behavior explicitly:
```elixir
defp api_get(credential, url, params \\ []) do
  RateLimiter.wait!(credential.url)

  options = [
    headers: [...],
    params: params,
    max_retries: 5,
    retry_log_level: :warn
  ] ++ Map.get(credential, :req_options, [])

  Req.get(url, options)
end
```

`max_retries: 5` (up from the implicit Req default of 3) so a sustained slow window doesn't terminate the call. Req's `:safe_transient` retry handles 429/5xx and respects `Retry-After` natively.

The two error tuples that previously distinguished `:rate_limited` from other errors are no longer needed — `{:error, {:http, 429}}` is now self-describing and bubbles up to the same caller error-handling that already exists.

### Part 4 — Statistics short-circuit + misc plan

**New helper** `collect_misc_data/5` in `MonicaApi`, called inside the contact loop alongside the existing `collect_extra_notes/3`:

```elixir
@misc_endpoints [
  {:calls, "number_of_calls"},
  {:activities, "number_of_activities"},
  {:gifts, "number_of_gifts"},
  {:debts, "number_of_debts"},
  {:tasks, "number_of_tasks"},
  {:reminders, "number_of_reminders"},
  {:conversations, "number_of_conversations"}
]

defp collect_misc_data(deferred, api_contact, source_id, local_id, opts) do
  stats = api_contact["statistics"] || %{}

  endpoints =
    @misc_endpoints
    |> Enum.filter(fn {key, stat_field} ->
      opts[Atom.to_string(key)] != false and (stats[stat_field] || 0) > 0
    end)
    |> Enum.map(&elem(&1, 0))

  endpoints = if opts["pets"] != false, do: [:pets | endpoints], else: endpoints

  if endpoints == [] do
    deferred
  else
    entry = %{source_id: source_id, local_id: local_id, endpoints: endpoints}
    %{deferred | misc_data: [entry | deferred.misc_data]}
  end
end
```

Rules:
- Endpoint is included only if (a) the wizard opt for that data type is not false **and** (b) Monica's stat field reports > 0 (or, for pets, the wizard opt is on — pets has no statistic field in Monica's payload).
- Contact contributes zero entries if every endpoint is filtered out — it's not even in the plan.
- Stat absent in payload is treated as ">0" (safer default; we'd rather make a wasted call than miss data).

`deferred` (already threaded through `crawl/5`) gains a new key `misc_data: []`. After the contact loop completes, `deferred.misc_data` is the plan list passed to the misc worker.

### Part 5 — Self-inflicted perf debt cleanup

#### 5a. Replace `:persistent_term` cache with `ref_data` MapSet

**Delete** `phone_field_type?/1` and `phone_field_type?(nil)` clauses in `monica_api.ex`.

**Extend** `ref_data` from:
```elixir
%{contact_field_types: %{name => id}}
```
to:
```elixir
%{
  contact_field_types: %{name => id},
  phone_cft_ids: MapSet.t()
}
```

`build_or_update_ref_data/3` computes `phone_cft_ids` once per ref_data refresh (1-2 queries per entire import, vs 5-8 GC-triggering `:persistent_term.put` calls).

**Update** `normalize_field_value/3` to take `ctx` (already in scope at the caller) instead of just `opts`:
```elixir
defp normalize_field_value(value, cft_id, ctx) when is_binary(value) do
  if MapSet.member?(ctx.ref_data.phone_cft_ids, cft_id) do
    region = parse_region(ctx.opts["phone_default_region"])
    {:ok, normalized} = PhoneFormatter.normalize(value, region)
    normalized || value
  else
    value
  end
end
```

#### 5b. Bypass `Contacts.maybe_normalize_phone` from Monica path

**Extend** `Contacts.create_contact_field/2` to `create_contact_field/3` with `opts \\ []`:
```elixir
def create_contact_field(%Contact{} = contact, attrs, opts \\ []) do
  attrs = if Keyword.get(opts, :normalize, true), do: maybe_normalize_phone(attrs), else: attrs

  %ContactField{contact_id: contact.id, account_id: contact.account_id}
  |> ContactField.changeset(attrs)
  |> Repo.insert()
end
```

Default `normalize: true` preserves behavior for UI/API callers (one line touched in `monica_api.ex` to pass `normalize: false`).

This eliminates ~2000 redundant libphonenumber parses **and** ~5000 redundant `Repo.get(ContactFieldType, cft_id)` queries per typical 1000-contact import — all on the Monica path only. UI form path is unchanged.

## Files to modify

**Production code:**
- `lib/kith/imports/sources/monica_api/rate_limiter.ex` *(new)* — Hammer-backed throttle.
- `lib/kith/workers/monica_misc_data_worker.ex` *(new)* — Phase 4 worker.
- `lib/kith/imports/sources/monica_api.ex` — Phase 4 removed; `collect_misc_data/5` added; `phone_field_type?/1` deleted; `api_get_json_with_retry/4` deleted; `api_get/3` wraps `RateLimiter.wait!`; `normalize_field_value/3` takes `ctx`; `ref_data` extended with `phone_cft_ids`; `build_or_update_ref_data/3` computes that field; per-contact endpoint helpers (`import_contact_pets/calls/activities/gifts/debts/tasks/reminders/conversations`) relocated to the misc worker module.
- `lib/kith/workers/monica_api_crawl_worker.ex` — enqueues `MonicaMiscDataWorker` on successful completion.
- `lib/kith/contacts.ex` — `create_contact_field/2` → `create_contact_field/3` with `normalize: true` default.
- `config/config.exs` — `config :kith, :monica_rate_limit, 55`.
- `config/test.exs` — high override so tests don't sleep on the throttle.

**Tests:**
- `test/kith/imports/sources/monica_api/rate_limiter_test.exs` *(new)* — under-limit allows, over-limit waits, per-host isolation, env override.
- `test/kith/workers/monica_misc_data_worker_test.exs` *(new)* — worker fires only planned endpoints; cancelled import skipped; summary populated; cred carried through args.
- `test/kith/imports/sources/monica_api_test.exs` *(extend)* — `crawl/5` enqueues misc worker with right plan; statistics-zero excluded; statistics-missing included; opt-outs honored; no per-contact endpoint stubs hit during main crawl.
- `test/kith/workers/monica_api_crawl_worker_test.exs` *(extend)* — boundary test for the enqueue.
- `test/kith/contacts_test.exs` *(extend or add)* — `create_contact_field/3` with `normalize: false` bypasses `maybe_normalize_phone`.

## Existing functions to reuse

- `MonicaPhotoSyncWorker` (`lib/kith/workers/monica_photo_sync_worker.ex`) — pattern for "enqueue from main crawl, carry credential through args, check `import.status` at top of `perform/1`, single Oban job that iterates contacts internally."
- `Imports.update_import_status/3` (existing) — pattern for writing `summary` updates that trigger the existing PubSub broadcast.
- `Phase 3 collect_extra_notes/3` (`lib/kith/imports/sources/monica_api.ex:583-599`) — pattern for "inspect statistics in the contact loop, accumulate a deferred entry, process after main crawl."
- `Hammer.check_rate/3` (existing dep) — token bucket primitive for the throttle.
- `Req`'s `:safe_transient` retry + `Retry-After` handling (default behavior) — single source of truth for retry logic after we delete the hand-rolled wrapper.

## Verification

1. **Unit tests:**
   ```
   mix test test/kith/imports/sources/monica_api/rate_limiter_test.exs \
            test/kith/workers/monica_misc_data_worker_test.exs \
            test/kith/imports/sources/monica_api_test.exs \
            test/kith/workers/monica_api_crawl_worker_test.exs \
            test/kith/contacts_test.exs
   ```
   All green.

2. **Static analysis:** `mix quality` — no new credo issues, no new dialyzer warnings beyond the existing `.dialyzer_ignore.exs` entries.

3. **Manual dev test:**
   - Reset dev account via `Kith.Workers.AccountResetWorker`.
   - Re-import ~1000 Monica contacts with default wizard options (all 8 misc data types checked).
   - **`MonicaApiCrawlWorker` should complete in well under 2 minutes** (Phase 1 paginated calls + auto-merge + cross-refs + extra notes — bounded by ~20-30 throttled requests).
   - **`MonicaMiscDataWorker` should complete in single-digit minutes** for typical CRM data (most contacts have nothing in pets/debts/gifts).
   - Logs should show **zero** `"retry: got response with status 429"` messages under normal Monica defaults.
   - `import_job.summary` after main worker: `imported`, `merged`, `contacts`, `notes` populated.
   - `import_job.summary["misc"]` after misc worker: per-endpoint counts.
   - Duplicates tab: a small number of pending candidates, not 6000 (this validates the earlier bug-fix is still working).

4. **Oban dashboard:**
   - `MonicaApiCrawlWorker` job completes and disappears from `executing`.
   - `MonicaMiscDataWorker` job appears separately, runs to completion.
   - Both individually cancellable.

5. **Rate limiter sanity (optional IEx):**
   ```elixir
   times = for _ <- 1..70 do
     {time_us, _} = :timer.tc(fn ->
       Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://test.monica")
     end)
     time_us / 1_000
   end
   {Enum.take(times, 55) |> Enum.sum(), Enum.drop(times, 55) |> Enum.sum()}
   ```
   First 55 calls should be near-zero; remaining 15 should be ~1100ms each.

## Risks

- **Plan size in Oban args.** For typical CRMs the plan is small (5-15% of contacts contribute entries). At ~100k+ contact scale the args could grow large; if that happens, swap to a `misc_data_plan` jsonb column on `imports` and pass only `import_id`. Localized change, two lines.
- **Phase 4 status visibility.** Users see "import complete" when the main crawl finishes; misc data trickles in afterward. The wizard's PubSub channel already broadcasts summary updates, but the "complete" copy doesn't currently distinguish between "fully done" and "main done, misc running." Consider a UI follow-up: show a second progress line for `misc_data` if `summary["misc"]` is absent.
- **Misc worker cancellation race.** If the user cancels the import between main-crawl completion and the misc worker picking up the job, the misc worker checks `import.status == "cancelled"` at the top of `perform/1` and exits cleanly. If cancellation happens *mid-run*, the in-flight request finishes but no further requests fire. Same model as `MonicaPhotoSyncWorker` today.
- **Throttle starvation across concurrent imports.** If two users on the same Monica instance import simultaneously, they share the per-host bucket. Each gets ~half the throughput. Acceptable — Monica's actual limit is the shared resource anyway.
- **The pre-existing `maybe_normalize_phone` N+1 remains for UI form callers.** Not in scope; tracked as future work. Practical impact is invisible because UI writes happen one at a time.

## Non-goals

- Account-locale-derived region applied to UI form phone writes (separate change, larger surface).
- Hammer auto-detection of Monica's actual rate limit (Monica doesn't expose this in headers).
- Batched per-contact data fetches via Monica `?include=` query parameter (Monica's API doesn't currently support multi-resource includes for these endpoints).
- Splitting the misc worker into per-endpoint sub-workers (premature; single worker is simpler and the per-endpoint counts are already preserved).
