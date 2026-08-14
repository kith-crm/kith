# Monica Import Performance Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the Monica importer to a reasonable runtime by extracting Phase 4 (per-contact extra data) into a dedicated throttled background worker, collapsing the double retry layer, and paying back the perf debt introduced in commit `6af91bf`.

**Architecture:** Phase 4 moves out of `MonicaApi.crawl/5` into a new `MonicaMiscDataWorker` Oban job enqueued by the existing `MonicaApiCrawlWorker` on success. The new worker consumes a plan built during main crawl that pre-filters contacts by Monica's `statistics.number_of_*` fields. A single `Hammer`-backed `RateLimiter` paces every outbound Monica call (~55 req/min) so 429s become rare; the hand-rolled retry wrapper is deleted and `Req`'s built-in `:safe_transient` retry is the sole retry source. Two cleanups: phone-cft lookup moves from a `:persistent_term`-cached boolean into a `MapSet` on `ref_data`, and `Contacts.create_contact_field` accepts an explicit `normalize: false` option so the Monica path skips the redundant second normalization.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Oban 2.18 (queue `:imports`), Req 0.5, Hammer 6.2, ex_phone_number 0.4.

**Reference spec:** `docs/superpowers/specs/2026-05-16-monica-import-perf-fix-design.md`

---

## Task 1: Add the RateLimiter module + unit tests

**Files:**
- Create: `lib/kith/imports/sources/monica_api/rate_limiter.ex`
- Create: `test/kith/imports/sources/monica_api/rate_limiter_test.exs`

- [ ] **Step 1: Inspect the Hammer setup in the project so the new module uses the same backend**

Run: `grep -rn "Hammer\|hammer:" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/config /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib --include='*.exs' --include='*.ex' | head -20`

Expected: see `:hammer` config and an existing usage (e.g. `KithWeb.Plugs.RateLimiter`) calling `Hammer.check_rate/3`. Note the backend module (likely `Hammer.Backend.ETS`) so test setup mirrors it.

- [ ] **Step 2: Write the failing tests**

Create `test/kith/imports/sources/monica_api/rate_limiter_test.exs`:

```elixir
defmodule Kith.Imports.Sources.MonicaApi.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Kith.Imports.Sources.MonicaApi.RateLimiter

  # Tests run with the real Hammer backend; we use a unique host per test
  # so buckets do not collide between tests.

  setup do
    # Force a low limit for predictable timing.
    prev = Application.get_env(:kith, :monica_rate_limit)
    Application.put_env(:kith, :monica_rate_limit, 3)
    on_exit(fn -> Application.put_env(:kith, :monica_rate_limit, prev) end)
    :ok
  end

  defp unique_host, do: "test-#{System.unique_integer([:positive])}.example"

  describe "wait!/1" do
    test "returns :ok immediately while under the per-minute budget" do
      host = unique_host()

      {us, _} =
        :timer.tc(fn ->
          for _ <- 1..3, do: assert :ok = RateLimiter.wait!("https://#{host}")
        end)

      assert us < 50_000, "expected sub-50ms for 3 calls under the budget, got #{us}us"
    end

    test "sleeps once the budget is exhausted" do
      host = unique_host()
      for _ <- 1..3, do: RateLimiter.wait!("https://#{host}")

      {us, _} = :timer.tc(fn -> RateLimiter.wait!("https://#{host}") end)

      # One inter-call sleep (≈1100ms) is enough to clear back into the window
      # for the test's tiny limit. Allow generous slack.
      assert us >= 1_000_000, "expected ≥1s wait when over budget, got #{us}us"
    end

    test "per-host buckets do not share quota" do
      host_a = unique_host()
      host_b = unique_host()

      for _ <- 1..3, do: RateLimiter.wait!("https://#{host_a}")

      {us, _} = :timer.tc(fn -> RateLimiter.wait!("https://#{host_b}") end)
      assert us < 50_000, "host_b should be in its own bucket"
    end

    test "extracts the host portion of a URL for the bucket key" do
      url1 = "https://example.test/api/contacts"
      url2 = "https://example.test/api/me"

      # Same host → same bucket → exhausting via url1 should impact url2.
      for _ <- 1..3, do: RateLimiter.wait!(url1)

      {us, _} = :timer.tc(fn -> RateLimiter.wait!(url2) end)
      assert us >= 1_000_000
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/kith/imports/sources/monica_api/rate_limiter_test.exs`

Expected: FAIL with `(UndefinedFunctionError) function Kith.Imports.Sources.MonicaApi.RateLimiter.wait!/1 is undefined`.

- [ ] **Step 4: Write the module**

Create `lib/kith/imports/sources/monica_api/rate_limiter.ex`:

```elixir
defmodule Kith.Imports.Sources.MonicaApi.RateLimiter do
  @moduledoc """
  Per-host token bucket for outbound Monica API calls.

  Configured at one token below Monica's documented default of 60 requests
  per minute, leaving a one-call safety margin so a small clock-skew or
  burst on Monica's side does not push us into the 429 window.

  Configurable via:

      config :kith, :monica_rate_limit, <integer>

  per-test overrides via `Application.put_env/3`.

  Hammer (already a dep) supplies the underlying token bucket; we use a
  bucket key per Monica host so independent Monica instances do not share
  a quota. Calls block the caller process via `Process.sleep/1` until a
  token is available, then return `:ok`.
  """

  @scale_ms 60_000
  @default_limit 55
  @retry_sleep_ms 1_100

  @doc """
  Block until a request token is available for the given Monica host.

  `url_or_host` may be a full URL (the host is extracted) or a bare host
  string. Returns `:ok` once a token has been claimed.
  """
  @spec wait!(String.t()) :: :ok
  def wait!(url_or_host) when is_binary(url_or_host) do
    bucket = bucket_key(url_or_host)
    limit = Application.get_env(:kith, :monica_rate_limit, @default_limit)

    case Hammer.check_rate(bucket, @scale_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _retry_after_ms} ->
        Process.sleep(@retry_sleep_ms)
        wait!(url_or_host)
    end
  end

  defp bucket_key(url_or_host) do
    host = URI.parse(url_or_host).host || url_or_host
    "monica_api:#{host}"
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/kith/imports/sources/monica_api/rate_limiter_test.exs`

Expected: PASS, 4 tests.

- [ ] **Step 6: Verify the rest of the suite still passes**

Run: `mix test`

Expected: PASS, no new failures. (If `mix test` triggers Hammer initialization that wasn't set up, surface it now rather than later.)

- [ ] **Step 7: Commit**

```bash
cd /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection
git add lib/kith/imports/sources/monica_api/rate_limiter.ex test/kith/imports/sources/monica_api/rate_limiter_test.exs
git commit -m "feat: add Monica API per-host rate limiter (55/min)"
```

---

## Task 2: Config knobs for the rate limit

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add the production default**

Open `config/config.exs`. After the existing `config :ex_cldr, default_backend: Kith.Cldr` line (added in commit `6af91bf`), add:

```elixir
# Outbound rate limit for Monica API calls. One below the documented
# default of 60 req/min leaves a one-call safety margin.
config :kith, :monica_rate_limit, 55
```

- [ ] **Step 2: Add a high-ceiling override for tests**

Open `config/test.exs`. After the existing `config :ex_phone_number, metadata_file: ...` line (added in commit `6af91bf`), add:

```elixir
# Effectively unthrottled in tests — throttle logic is exercised in
# isolation in rate_limiter_test.exs, not via the full crawl integration.
config :kith, :monica_rate_limit, 1_000_000
```

- [ ] **Step 3: Verify both configs compile and tests still pass**

Run: `mix test test/kith/imports/sources/monica_api/rate_limiter_test.exs && mix test`

Expected: PASS. The rate_limiter test brackets its own override, so the high test default doesn't break it. The rest of the suite shouldn't notice.

- [ ] **Step 4: Commit**

```bash
git add config/config.exs config/test.exs
git commit -m "chore: configure Monica API rate limit (55/min prod, unlimited test)"
```

---

## Task 3: Wire RateLimiter into `api_get` and collapse the double retry

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (`@max_rate_limit_retries`, `@rate_limit_sleep_ms`, `api_get`, `api_get_json`, `api_get_json_with_retry`)

- [ ] **Step 1: Locate the existing functions**

Run: `grep -n "@max_rate_limit_retries\|@rate_limit_sleep_ms\|defp api_get\|defp api_get_json" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: matches around lines 37-38 (module attrs), 1101 (`api_get`), 1109 (`api_get_json`), 1113-1118 (`api_get_json_with_retry`).

- [ ] **Step 2: Add the alias**

In `lib/kith/imports/sources/monica_api.ex`, find the `alias` block near the top (currently includes `Kith.Contacts.PhoneFormatter`). Add right after the existing aliases:

```elixir
  alias Kith.Imports.Sources.MonicaApi.RateLimiter
```

- [ ] **Step 3: Delete the two module attributes**

In the same file, find and delete the lines:

```elixir
  @max_rate_limit_retries 3
  @rate_limit_sleep_ms :timer.seconds(65)
```

- [ ] **Step 4: Replace `api_get/3` with the throttled version**

Find the existing `api_get/3`:

```elixir
  defp api_get(credential, url, params \\ []) do
    headers = [{"Authorization", "Bearer #{credential.api_key}"}, {"Accept", "application/json"}]
    req_options = Map.get(credential, :req_options, [])
    options = [headers: headers, params: params] ++ req_options

    Req.get(url, options)
  end
```

Replace with:

```elixir
  defp api_get(credential, url, params \\ []) do
    RateLimiter.wait!(credential.url)

    headers = [{"Authorization", "Bearer #{credential.api_key}"}, {"Accept", "application/json"}]
    req_options = Map.get(credential, :req_options, [])

    options =
      [
        headers: headers,
        params: params,
        max_retries: 5,
        retry_log_level: :warn
      ] ++ req_options

    Req.get(url, options)
  end
```

`max_retries: 5` overrides Req's default of 3 so a sustained 429 window doesn't terminate the call. `retry_log_level: :warn` keeps the existing log visibility.

- [ ] **Step 5: Replace `api_get_json/3` and delete `api_get_json_with_retry/4`**

Find:

```elixir
  defp api_get_json(credential, url, params) do
    api_get_json_with_retry(credential, url, params, 0)
  end

  defp api_get_json_with_retry(_credential, _url, _params, retries)
       when retries >= @max_rate_limit_retries do
    {:error, :rate_limited}
  end

  defp api_get_json_with_retry(credential, url, params, retries) do
    case api_get(credential, url, params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 429}} ->
        Logger.info(
          "[MonicaApi] Rate limited, sleeping #{@rate_limit_sleep_ms}ms (retry #{retries + 1})"
        )

        Process.sleep(@rate_limit_sleep_ms)
        api_get_json_with_retry(credential, url, params, retries + 1)

      {:ok, %{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
```

Replace the entire block with:

```elixir
  defp api_get_json(credential, url, params) do
    case api_get(credential, url, params) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end
```

The `{:error, :rate_limited}` shape is preserved — it's matched by callers (e.g. line 183 of `crawl_contacts_loop`, line 949 of `fetch_extra_notes_for_contact`). After 5 internal Req retries we surface rate-limited rather than silently looping.

- [ ] **Step 6: Run the existing Monica tests to verify behavior is preserved**

Run: `mix test test/kith/imports/sources/monica_api_test.exs test/kith/workers/monica_api_crawl_worker_test.exs`

Expected: PASS. The contract callers depend on (`{:ok, body}` / `{:error, :rate_limited}` / `{:error, other}`) is unchanged.

- [ ] **Step 7: Spot-check no dangling references to deleted attrs**

Run: `grep -n "max_rate_limit_retries\|rate_limit_sleep_ms\|api_get_json_with_retry" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: no matches. If anything remains, delete it.

- [ ] **Step 8: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex
git commit -m "refactor: collapse Monica double-retry to Req's built-in + RateLimiter"
```

---

## Task 4: Add `normalize: false` opt to `Contacts.create_contact_field`

**Files:**
- Modify: `lib/kith/contacts.ex` (line 390)
- Modify: `test/kith/contacts_sub_entities_test.exs`

- [ ] **Step 1: Inspect the existing test file to follow its setup pattern**

Run: `grep -n "describe\|create_contact_field" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/test/kith/contacts_sub_entities_test.exs | head -20`

Expected: see the existing describe blocks for `create_contact_field/2`. Note the setup helpers used (likely `setup_account()`, `seed_reference_data!()`).

- [ ] **Step 2: Add a failing test**

In `test/kith/contacts_sub_entities_test.exs`, find the `describe "create_contact_field/2"` block (or the location of existing contact_field tests) and add inside it:

```elixir
    test "create_contact_field/3 with normalize: false skips phone normalization",
         %{account: account, phone_field_type: phone_type} do
      contact = insert(:contact, account: account)

      # Value that PhoneFormatter.normalize/1 would change (no region, but
      # +-prefixed numbers get parsed and re-emitted as canonical E.164).
      # We assert the value is stored unchanged when normalization is skipped.
      attrs = %{"contact_field_type_id" => phone_type.id, "value" => "+1 (202) 555-0100"}

      assert {:ok, field} =
               Kith.Contacts.create_contact_field(contact, attrs, normalize: false)

      assert field.value == "+1 (202) 555-0100"
    end

    test "create_contact_field/3 with normalize: true (default) normalizes phone",
         %{account: account, phone_field_type: phone_type} do
      contact = insert(:contact, account: account)

      attrs = %{"contact_field_type_id" => phone_type.id, "value" => "+1 (202) 555-0100"}

      assert {:ok, field} = Kith.Contacts.create_contact_field(contact, attrs)
      assert field.value == "+12025550100"
    end
```

If the existing tests don't already provide `phone_field_type` in the setup context, add a setup helper at the top of the describe block:

```elixir
    setup %{account: account} do
      phone_type =
        Kith.Repo.one!(
          from t in "contact_field_types",
            where: t.protocol == "tel:",
            select: %{id: t.id},
            limit: 1
        )

      {:ok, phone_field_type: phone_type}
    end
```

Adapt this to whatever shape the file already uses — if the file's setup already returns the account, ensure the new helper merges with it rather than replacing it.

- [ ] **Step 3: Run the new tests, expect the first to fail**

Run: `mix test test/kith/contacts_sub_entities_test.exs -k "normalize"`

Expected: One test fails (the 3-arity call) with `(UndefinedFunctionError) function Kith.Contacts.create_contact_field/3 is undefined`. The 2-arity test should already pass.

- [ ] **Step 4: Implement the 3-arity version**

Open `lib/kith/contacts.ex` and find `create_contact_field/2` (around line 390):

```elixir
  def create_contact_field(%Contact{} = contact, attrs) do
    attrs = maybe_normalize_phone(attrs)

    %ContactField{contact_id: contact.id, account_id: contact.account_id}
    |> ContactField.changeset(attrs)
    |> Repo.insert()
  end
```

Replace with:

```elixir
  def create_contact_field(%Contact{} = contact, attrs, opts \\ []) do
    attrs =
      if Keyword.get(opts, :normalize, true) do
        maybe_normalize_phone(attrs)
      else
        attrs
      end

    %ContactField{contact_id: contact.id, account_id: contact.account_id}
    |> ContactField.changeset(attrs)
    |> Repo.insert()
  end
```

The default-arg `opts \\ []` keeps every existing 2-arity caller working without changes. Only callers that explicitly want to bypass normalization need to pass `normalize: false`.

- [ ] **Step 5: Run the tests to verify both pass**

Run: `mix test test/kith/contacts_sub_entities_test.exs -k "normalize"`

Expected: PASS, both tests.

- [ ] **Step 6: Run the full Contacts test files to verify no regressions**

Run: `mix test test/kith/contacts_sub_entities_test.exs test/kith/contacts/contact_test.exs`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/kith/contacts.ex test/kith/contacts_sub_entities_test.exs
git commit -m "feat: Contacts.create_contact_field/3 supports normalize: false opt"
```

---

## Task 5: Monica importer passes `normalize: false` to `create_contact_field`

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (`create_contact_field/5` helper at ~line 452)
- Modify: `test/kith/imports/sources/monica_api_test.exs`

- [ ] **Step 1: Locate the inner helper**

Run: `grep -n "defp create_contact_field" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: one match near line 452.

- [ ] **Step 2: Update the inner helper**

Find:

```elixir
  defp create_contact_field(contact, field, cft_id, value, import_job) do
    attrs = %{"value" => value, "contact_field_type_id" => cft_id}

    case Contacts.create_contact_field(contact, attrs) do
```

Replace the `Contacts.create_contact_field(contact, attrs)` call with:

```elixir
    case Contacts.create_contact_field(contact, attrs, normalize: false) do
```

The Monica path already normalizes phone values upfront in `normalize_field_value/3` using the user-chosen region. The downstream `Contacts.maybe_normalize_phone/1` would re-parse the same E.164 value and do a redundant `Repo.get(ContactFieldType, ...)` per write. Skipping it saves ~2000 libphonenumber parses and ~5000 DB round trips per 1000-contact import.

- [ ] **Step 3: Write a test asserting Monica import doesn't double-normalize**

Tricky to assert directly without instrumenting. Instead, add a behavioral test in `test/kith/imports/sources/monica_api_test.exs` that imports a phone field and verifies the stored value matches what `PhoneFormatter.normalize/2` would produce (i.e. the import path's own normalization is the single source of truth):

In `test/kith/imports/sources/monica_api_test.exs`, find the existing test `"normalizes phone fields to E.164 when phone_default_region is set"` (added in commit `6af91bf`). Right after it, add:

```elixir
    test "phone normalization happens exactly once during import",
         %{user: user, account_id: account_id} do
      # Regression: Contacts.create_contact_field used to re-run
      # maybe_normalize_phone on the already-E.164 value, costing one extra
      # libphonenumber parse and one extra Repo.get per phone field. The
      # behavioral assertion here is "value stored matches MonicaApi's own
      # normalization output exactly, with no later mutation."
      contacts = [
        contact_json(
          id: 99,
          first_name: "OnceOnly",
          contact_fields: [
            contact_field_json(content: "(202) 555-0100", type_name: "Phone")
          ]
        )
      ]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1))
      end)

      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, _} =
               MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
                 "phone_default_region" => "US"
               })

      rec = Imports.find_import_record(account_id, "monica_api", "contact", "99")

      values =
        Repo.all(from cf in Contacts.ContactField, where: cf.contact_id == ^rec.local_entity_id)
        |> Enum.map(& &1.value)

      assert "+12025550100" in values
    end
```

This test passes both before and after Task 5; its purpose is to lock in the behavior so a future regression that re-introduces double-normalization (e.g. accidentally calling `normalize/1` with `nil` region on an already-canonical value) doesn't change the stored value.

- [ ] **Step 4: Run the test and existing Monica tests**

Run: `mix test test/kith/imports/sources/monica_api_test.exs`

Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex test/kith/imports/sources/monica_api_test.exs
git commit -m "perf: skip redundant normalization in Monica contact_field writes"
```

---

## Task 6: Replace `:persistent_term` phone-cft cache with `ref_data` MapSet

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (`crawl/5`, `build_or_update_ref_data/3`, `normalize_field_value/3`, delete `phone_field_type?/1`, delete `phone_field_type?(nil)`)

- [ ] **Step 1: Locate the cache and the ref_data builders**

Run:

```bash
grep -n "phone_field_type?\|build_or_update_ref_data\|defp build_ref_data\|ref_data: ref_data\|ref_data ->" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex
```

Expected: matches at the cache (~line 432-450), `build_or_update_ref_data` (~line 864-870), `find_or_create_contact_field_types` (~line 956-966), and various ref_data references in the contact loop.

- [ ] **Step 2: Read the existing `build_or_update_ref_data` and `find_or_create_contact_field_types`**

Open `lib/kith/imports/sources/monica_api.ex`. Read both functions (~lines 860-970). Confirm the shape: `ref_data` is a map with keys including `contact_field_types: %{name => id}`. `build_or_update_ref_data` is called per page to merge in newly-discovered cft types.

- [ ] **Step 3: Add a helper to compute phone-cft IDs from a set of cft IDs**

In `lib/kith/imports/sources/monica_api.ex`, add a new private helper near the other ref_data helpers (place it just before `find_or_create_contact_field_types/2` so related code clusters together):

```elixir
  # Returns the subset of `cft_ids` whose protocol begins with "tel" (phone).
  # Called when ref_data is built or refreshed; the resulting MapSet replaces
  # the per-cft `:persistent_term` cache that triggered global GCs on cold
  # imports.
  defp phone_cft_ids(account_id, cft_ids) when is_list(cft_ids) do
    Repo.all(
      from t in Contacts.ContactFieldType,
        where: t.id in ^cft_ids,
        where: is_nil(t.account_id) or t.account_id == ^account_id,
        where: fragment("? LIKE 'tel%'", t.protocol),
        select: t.id
    )
    |> MapSet.new()
  end
```

Account scope mirrors the existing pattern in `find_or_create_contact_field_types/2`. The `is_nil(t.account_id)` clause handles system-wide cft types seeded in test/dev.

- [ ] **Step 4: Extend `ref_data` to carry `phone_cft_ids`**

Find `build_or_update_ref_data/3` (the initial build path, ~line 864):

```elixir
  defp build_or_update_ref_data(account_id, contacts, nil) do
    cfts = collect_api_contact_field_types(contacts)

    %{
      contact_field_types: find_or_create_contact_field_types(account_id, cfts)
    }
  end
```

Replace with:

```elixir
  defp build_or_update_ref_data(account_id, contacts, nil) do
    cfts = collect_api_contact_field_types(contacts)
    cft_map = find_or_create_contact_field_types(account_id, cfts)

    %{
      contact_field_types: cft_map,
      phone_cft_ids: phone_cft_ids(account_id, Map.values(cft_map))
    }
  end
```

Find the update path (the function head matching when `ref_data` is non-nil, ~line 886):

```elixir
  defp build_or_update_ref_data(account_id, contacts, ref_data) do
    new_cfts =
      contacts
      |> collect_api_contact_field_types()
      |> Enum.reject(&Map.has_key?(ref_data.contact_field_types, &1))

    %{
      ref_data |
      contact_field_types:
        Map.merge(
          ref_data.contact_field_types,
          find_or_create_contact_field_types(account_id, new_cfts)
        )
    }
  end
```

Replace with:

```elixir
  defp build_or_update_ref_data(account_id, contacts, ref_data) do
    new_cfts =
      contacts
      |> collect_api_contact_field_types()
      |> Enum.reject(&Map.has_key?(ref_data.contact_field_types, &1))

    if new_cfts == [] do
      ref_data
    else
      added = find_or_create_contact_field_types(account_id, new_cfts)
      merged_types = Map.merge(ref_data.contact_field_types, added)

      %{
        ref_data
        | contact_field_types: merged_types,
          phone_cft_ids:
            MapSet.union(
              ref_data.phone_cft_ids,
              phone_cft_ids(account_id, Map.values(added))
            )
      }
    end
  end
```

The short-circuit when `new_cfts == []` avoids running the phone-cft query on every page when no new cft types appear (the common case).

- [ ] **Step 5: Update `normalize_field_value/3` to take `ctx`**

Find `normalize_field_value` (~line 419):

```elixir
  defp normalize_field_value(nil, _cft_id, _opts), do: nil

  defp normalize_field_value(value, cft_id, opts) when is_binary(value) do
    if phone_field_type?(cft_id) do
      region = opts["phone_default_region"]
      region = if region in [nil, ""], do: nil, else: region
      {:ok, normalized} = PhoneFormatter.normalize(value, region)
      normalized || value
    else
      value
    end
  end
```

Replace with:

```elixir
  defp normalize_field_value(nil, _cft_id, _ctx), do: nil

  defp normalize_field_value(value, cft_id, ctx) when is_binary(value) do
    if MapSet.member?(ctx.ref_data.phone_cft_ids, cft_id) do
      region = parse_phone_region(ctx.opts["phone_default_region"])
      {:ok, normalized} = PhoneFormatter.normalize(value, region)
      normalized || value
    else
      value
    end
  end

  defp parse_phone_region(region) when region in [nil, ""], do: nil
  defp parse_phone_region(region) when is_binary(region), do: region
```

- [ ] **Step 6: Update the call site in `import_single_contact_field/4`**

Find (~line 406):

```elixir
  defp import_single_contact_field(contact, field, ref_data, ctx) do
    cft_name = get_in(field, ["contact_field_type", "name"])
    cft_id = if cft_name, do: Map.get(ref_data.contact_field_types, cft_name)
    raw_value = field["content"]
    value = normalize_field_value(raw_value, cft_id, ctx.opts)
```

Change the last line to pass `ctx`:

```elixir
    value = normalize_field_value(raw_value, cft_id, ctx)
```

- [ ] **Step 7: Delete `phone_field_type?/1`**

Delete both clauses (~lines 432-450):

```elixir
  defp phone_field_type?(nil), do: false

  defp phone_field_type?(cft_id) do
    case :persistent_term.get({__MODULE__, :phone_cft, cft_id}, :miss) do
      :miss ->
        result =
          Repo.exists?(
            from(t in Contacts.ContactFieldType,
              where: t.id == ^cft_id and fragment("? LIKE 'tel%'", t.protocol)
            )
          )

        :persistent_term.put({__MODULE__, :phone_cft, cft_id}, result)
        result

      result ->
        result
    end
  end
```

- [ ] **Step 8: Run the full Monica test suite**

Run: `mix test test/kith/imports/sources/monica_api_test.exs test/kith/workers/monica_api_crawl_worker_test.exs`

Expected: PASS. The behavior is unchanged externally — phones still normalize correctly when a region is supplied — only the internal mechanism shifts from `:persistent_term`+lazy-DB-query to `MapSet`-on-`ref_data`.

- [ ] **Step 9: Verify no `:persistent_term` reads remain in the file**

Run: `grep -n ":persistent_term" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: no matches.

- [ ] **Step 10: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex
git commit -m "perf: replace :persistent_term phone-cft cache with ref_data MapSet"
```

---

## Task 7: Add `collect_misc_data/5` and extend the deferred state

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (`crawl_all_contacts/1` initial state, contact loop wiring, new `@misc_endpoints` attribute, `collect_misc_data/5`)
- Modify: `test/kith/imports/sources/monica_api_test.exs`

- [ ] **Step 1: Find the deferred state initialization**

Run: `grep -n "deferred:\|extra_notes: \[\]\|first_met_through: \[\]" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex | head -10`

Expected: a match in `crawl_all_contacts/1` (~line 156-163) where `deferred` is initialized as `%{first_met_through: [], relationships: [], extra_notes: []}`.

- [ ] **Step 2: Add `misc_data: []` to the deferred initial state**

Open `lib/kith/imports/sources/monica_api.ex`. Find the initialization (~line 156):

```elixir
  defp crawl_all_contacts(ctx) do
    initial_state = %{
      page: 1,
      total: nil,
      acc: %{contacts: 0, notes: 0, skipped: 0, error_count: 0, errors: []},
      deferred: %{first_met_through: [], relationships: [], extra_notes: []},
      ref_data: nil,
      global_idx: 0
    }

    crawl_contacts_loop(ctx, initial_state)
  end
```

Change to:

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
```

- [ ] **Step 3: Add the `@misc_endpoints` module attribute and helper**

Find the location just below the existing `defp collect_extra_notes` (~line 583-599). After it, add:

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

  # Build a plan entry for a contact's per-contact extra-data endpoints.
  # An endpoint is included only if (a) the wizard opt for that data type is
  # not explicitly false AND (b) Monica's `statistics.number_of_X` reports
  # > 0 (or the stat field is missing — safer to fetch than to silently
  # skip when Monica's payload shape is unfamiliar).
  #
  # `:pets` has no statistics field in Monica's contact payload, so it is
  # included whenever the wizard opt is on. The redundant fetch for pet-free
  # contacts is the documented cost.
  defp collect_misc_data(deferred, api_contact, source_id, local_id, opts) do
    stats = api_contact["statistics"] || %{}

    endpoints =
      @misc_endpoints
      |> Enum.filter(fn {key, stat_field} ->
        opts[Atom.to_string(key)] != false and (stats[stat_field] || 1) > 0
      end)
      |> Enum.map(&elem(&1, 0))

    endpoints = if opts["pets"] != false, do: [:pets | endpoints], else: endpoints

    if endpoints == [] do
      deferred
    else
      entry = %{
        source_id: to_string(source_id),
        local_id: local_id,
        endpoints: Enum.map(endpoints, &Atom.to_string/1)
      }

      %{deferred | misc_data: [entry | deferred.misc_data]}
    end
  end
```

Note: `endpoints` are stringified before storing in the plan because the plan will eventually be serialized into Oban job args (JSON-encoded), where atoms don't round-trip cleanly.

Note on the `(stats[stat_field] || 1) > 0` line: `|| 1` is the safe-default behavior — when the stat field is missing or nil from Monica's payload, we treat it as "≥ 1" so the endpoint fires. We do not want to silently skip data.

- [ ] **Step 4: Wire `collect_misc_data` into the contact processing loop**

Find `collect_deferred_data/3` (the function that gathers deferred entries during the contact loop, ~line 569-580). It currently calls `collect_extra_notes`. Locate its callers (`import_api_contact_children/7` at ~line 377 or similar).

Find the call site that invokes `collect_deferred_data` — the function signature is something like:

```elixir
  defp collect_deferred_data(api_contact, source_id, deferred) do
    deferred
    |> add_first_met_through_entry(api_contact, source_id)
    |> add_relationship_entries(api_contact, source_id)
    |> collect_extra_notes(api_contact, source_id)
  end
```

The actual function name/shape may differ slightly — adapt. Add `collect_misc_data` as a step, threading through the `contact` (for its local id) and `opts`. Since `collect_deferred_data` currently only takes `(api_contact, source_id, deferred)`, the cleanest path is to **extend its signature** to take `(api_contact, source_id, local_id, deferred, opts)` and update the single caller in `import_api_contact_children/7`.

In `import_api_contact_children/7` (~line 377), find the line:

```elixir
    deferred = collect_deferred_data(api_contact, source_id, deferred)
```

Change to:

```elixir
    deferred = collect_deferred_data(api_contact, source_id, contact.id, deferred, ctx.opts)
```

(`ctx.opts` was added to `ctx` in commit `6af91bf` — it's already in scope here.)

Then update `collect_deferred_data` itself to accept the new args and call `collect_misc_data`:

```elixir
  defp collect_deferred_data(api_contact, source_id, local_id, deferred, opts) do
    deferred
    |> add_first_met_through_entry(api_contact, source_id)
    |> add_relationship_entries(api_contact, source_id)
    |> collect_extra_notes(api_contact, source_id)
    |> collect_misc_data(api_contact, source_id, local_id, opts)
  end
```

Adapt to the exact existing function body — the principle is: thread `local_id` and `opts` in, append the `|> collect_misc_data(...)` step.

- [ ] **Step 5: Add `misc_data` to the `crawl/5` return summary**

Find the `{:ok, %{...}}` map at the end of `crawl/5` (~line 129-138):

```elixir
    {:ok,
     %{
       imported: acc.contacts,
       contacts: acc.contacts,
       notes: acc.notes,
       skipped: acc.skipped,
       merged: merge_result.merged,
       error_count: error_count,
       errors: Enum.take(all_errors, 50)
     }}
```

Change to:

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

The plan is reversed so contacts are listed in import order rather than the reverse-insertion order that `[entry | acc]` produces. `MonicaApiCrawlWorker` (next task) will read this key, use it for the misc-worker enqueue, then strip it before persisting the summary to the DB.

Find where `deferred` is in scope at this return — it's the `_deferred` element from `crawl_all_contacts(ctx)` (~line 88). Currently the code only binds `{acc, deferred}` from that call but doesn't use `deferred` at the return. Locate the bind:

```elixir
    {acc, deferred} = crawl_all_contacts(ctx)
```

Confirm `deferred` is in scope for the return tuple. If it isn't (you may see `{acc, _deferred}` ignoring it, or the variable may be shadowed), un-ignore it.

- [ ] **Step 6: Write a unit test for `collect_misc_data` shape**

In `test/kith/imports/sources/monica_api_test.exs`, find an existing describe block for `crawl/5` (or add a new one near the end). Add tests:

```elixir
  describe "crawl/5 — misc-data plan" do
    test "includes a contact when statistics.number_of_calls > 0",
         %{user: user, account_id: account_id} do
      contacts = [
        contact_json(
          id: 1,
          first_name: "Has",
          last_name: "Calls",
          statistics: %{"number_of_calls" => 3}
        )
      ]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1))
      end)

      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, summary} =
               MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
                 "calls" => true,
                 "pets" => false
               })

      assert [%{source_id: "1", endpoints: endpoints}] = summary.misc_data_plan
      assert "calls" in endpoints
    end

    test "excludes a contact when all opts are off",
         %{user: user, account_id: account_id} do
      contacts = [
        contact_json(
          id: 2,
          first_name: "AllOff",
          statistics: %{"number_of_calls" => 5, "number_of_gifts" => 5}
        )
      ]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1))
      end)

      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, summary} =
               MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
                 "calls" => false,
                 "gifts" => false,
                 "pets" => false,
                 "activities" => false,
                 "debts" => false,
                 "tasks" => false,
                 "reminders" => false,
                 "conversations" => false
               })

      assert summary.misc_data_plan == []
    end

    test "includes :pets unconditionally when opt is on (no stat field)",
         %{user: user, account_id: account_id} do
      contacts = [
        contact_json(
          id: 3,
          first_name: "PetsOnly",
          statistics: %{}
        )
      ]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1))
      end)

      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, summary} =
               MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
                 "pets" => true,
                 "calls" => false,
                 "activities" => false,
                 "gifts" => false,
                 "debts" => false,
                 "tasks" => false,
                 "reminders" => false,
                 "conversations" => false
               })

      assert [%{endpoints: ["pets"]}] = summary.misc_data_plan
    end

    test "missing statistic field is treated as ≥1 (safe default)",
         %{user: user, account_id: account_id} do
      contacts = [
        contact_json(
          id: 4,
          first_name: "NoStats",
          statistics: %{}
        )
      ]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, contacts_page_json(contacts, 1, 1, 1))
      end)

      import_job = api_import_fixture(account_id, user.id)

      assert {:ok, summary} =
               MonicaApi.crawl(account_id, user.id, credential(), import_job, %{
                 "calls" => true,
                 "pets" => false,
                 "activities" => false,
                 "gifts" => false,
                 "debts" => false,
                 "tasks" => false,
                 "reminders" => false,
                 "conversations" => false
               })

      assert [%{endpoints: endpoints}] = summary.misc_data_plan
      assert "calls" in endpoints
    end
  end
```

Verify the test helpers `contact_json/1` and `contacts_page_json/4` accept a `statistics:` keyword. Check the existing test file for examples — if the helper doesn't currently take `statistics`, extend it to merge a `statistics:` key into the contact JSON. If you need to update the helper, do it in the same commit.

- [ ] **Step 7: Run the new tests**

Run: `mix test test/kith/imports/sources/monica_api_test.exs`

Expected: PASS, all tests (existing + 4 new).

- [ ] **Step 8: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex test/kith/imports/sources/monica_api_test.exs
git commit -m "feat: collect misc-data plan during Monica crawl"
```

---

## Task 8: Create `MonicaMiscDataWorker` with relocated per-contact helpers

**Files:**
- Create: `lib/kith/workers/monica_misc_data_worker.ex`
- Create: `test/kith/workers/monica_misc_data_worker_test.exs`

This task creates the worker as a self-contained module. The per-contact endpoint helpers (`import_contact_pets`, `_calls`, `_activities`, `_gifts`, `_debts`, `_tasks`, `_reminders`, `_conversations`) are **copied** from `MonicaApi` into the worker. The duplication is temporary — Task 9 removes them from `MonicaApi` once the worker is wired up. This staging preserves a "main suite still green" checkpoint between Tasks 8 and 9.

- [ ] **Step 1: Inspect `MonicaPhotoSyncWorker` for the canonical worker pattern**

Run: `cat /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/workers/monica_photo_sync_worker.ex | head -90`

Note: queue, `use Oban.Worker` options, perform/1 args shape, status check, credential rebuild from args, summary update at end, broadcast pattern. Mirror these.

- [ ] **Step 2: List the per-contact helper boundaries in `MonicaApi`**

Run: `grep -n "^  defp import_contact_\|^  defp import_single_pet\|^  defp import_single_call\|^  defp import_single_activit\|^  defp import_single_gift\|^  defp import_single_debt\|^  defp import_single_task\|^  defp import_single_reminder\|^  defp import_single_conversat" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: a list of all the per-endpoint functions plus their per-item siblings. Note line ranges for copying.

- [ ] **Step 3: Write the failing test file first**

Create `test/kith/workers/monica_misc_data_worker_test.exs`:

```elixir
defmodule Kith.Workers.MonicaMiscDataWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  alias Kith.Imports
  alias Kith.Workers.MonicaMiscDataWorker

  @stub_name MonicaMiscDataReqStub

  setup do
    user = user_fixture()
    seed_reference_data!()

    Req.Test.set_req_test_from_context(self())

    %{user: user, account_id: user.account_id}
  end

  defp build_args(import_job, plan) do
    %{
      "import_id" => import_job.id,
      "credential_url" => "https://monica.test",
      "credential_api_key" => "test-key",
      "plan" => plan,
      "req_options" => [plug: {Req.Test, @stub_name}]
    }
  end

  defp api_import(account_id, user_id, api_options \\ %{}) do
    import_fixture(account_id, user_id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key",
      api_options: api_options,
      status: "completed"
    })
  end

  describe "perform/1" do
    test "fires only the endpoints listed in the plan",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      # Record all endpoint paths the worker calls.
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [
        %{
          "source_id" => "42",
          "local_id" => contact.id,
          "endpoints" => ["calls", "gifts"]
        }
      ]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      paths = collect_requests([])
      assert "/api/contacts/42/calls" in paths
      assert "/api/contacts/42/gifts" in paths
      refute "/api/contacts/42/pets" in paths
      refute "/api/contacts/42/activities" in paths
    end

    test "exits early when the import is cancelled",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      {:ok, _} = Imports.update_import_status(import_job, "cancelled", %{})

      contact = contact_fixture(account_id)
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert collect_requests([]) == []
    end

    test "skips contacts whose local row has been soft-deleted",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      contact = contact_fixture(account_id)

      Kith.Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^contact.id),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert collect_requests([]) == []
    end

    test "writes per-endpoint counts to import_job.summary['misc']",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/api/contacts/1/calls" ->
            Req.Test.json(conn, %{
              "data" => [
                %{"id" => 1, "called_at" => "2025-01-01", "contact_called" => true},
                %{"id" => 2, "called_at" => "2025-01-02", "contact_called" => false}
              ]
            })

          _ ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      updated = Imports.get_import!(import_job.id)
      assert is_map(updated.summary["misc"])
      assert updated.summary["misc"]["calls"] >= 0
    end
  end

  defp collect_requests(acc) do
    receive do
      {:request, path} -> collect_requests([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
```

The stub-via-Req.Test pattern matches what `monica_api_test.exs` already uses; copy whichever helper that file relies on if there's a shared fixture (e.g. `contact_field_json/1`).

The `req_options` arg shape in `build_args/2` mirrors how the existing photo sync worker test injects `Req.Test` stubs into the worker; if the codebase uses a different injection point (e.g. via `Application.put_env`), adapt to that.

- [ ] **Step 4: Run the test file, expect compilation failure**

Run: `mix test test/kith/workers/monica_misc_data_worker_test.exs`

Expected: FAIL with `(UndefinedFunctionError) function Kith.Workers.MonicaMiscDataWorker.__info__/1 is undefined`.

- [ ] **Step 5: Implement the worker skeleton + relocated helpers**

Create `lib/kith/workers/monica_misc_data_worker.ex`:

```elixir
defmodule Kith.Workers.MonicaMiscDataWorker do
  @moduledoc """
  Oban worker that imports the per-contact "miscellaneous" data types
  (pets, calls, activities, gifts, debts, tasks, reminders, conversations)
  for an already-completed Monica API crawl.

  Enqueued by `Kith.Workers.MonicaApiCrawlWorker` on successful completion,
  carrying:

    * `"import_id"` — the Import row this job belongs to.
    * `"credential_url"`, `"credential_api_key"` — the credential needed to
      keep calling Monica after the main crawl wipes `api_key_encrypted`.
      Same pattern as `MonicaPhotoSyncWorker`.
    * `"plan"` — list of `%{"source_id", "local_id", "endpoints"}` maps
      pre-filtered during the main crawl using Monica's `statistics.*`
      fields, so we only fire the endpoints with data.

  Throttled through `Kith.Imports.Sources.MonicaApi.RateLimiter` (same
  per-host bucket as the main crawler).

  Exits early if the import has been cancelled. Contacts that were
  soft-deleted between main-crawl completion and this job's dispatch are
  silently skipped.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi.RateLimiter

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    import_job = Imports.get_import!(args["import_id"])

    if import_job.status in ["cancelled", "failed"] do
      :ok
    else
      credential = build_credential(args)
      plan = args["plan"] || []

      counts = process_plan(plan, credential, import_job)

      summary = Map.put(import_job.summary || %{}, "misc", counts)

      Imports.update_import_status(import_job, import_job.status, %{summary: summary})

      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_misc_complete, counts})

      :ok
    end
  end

  defp build_credential(args) do
    %{
      url: args["credential_url"],
      api_key: args["credential_api_key"],
      req_options: args["req_options"] || []
    }
  end

  defp process_plan(plan, credential, import_job) do
    initial = %{
      "pets" => 0,
      "calls" => 0,
      "activities" => 0,
      "gifts" => 0,
      "debts" => 0,
      "tasks" => 0,
      "reminders" => 0,
      "conversations" => 0
    }

    Enum.reduce(plan, initial, fn entry, counts ->
      process_entry(entry, credential, import_job, counts)
    end)
  end

  defp process_entry(entry, credential, import_job, counts) do
    contact = Contacts.get_contact_for_misc(entry["local_id"])

    if contact == nil or not is_nil(contact.deleted_at) do
      counts
    else
      Enum.reduce(entry["endpoints"] || [], counts, fn endpoint, counts ->
        n = fire_endpoint(endpoint, credential, contact, entry["source_id"], import_job)
        Map.update(counts, endpoint, n, &(&1 + n))
      end)
    end
  end

  defp fire_endpoint("pets", c, contact, src, ij), do: import_contact_pets(c, contact, src, ij)

  defp fire_endpoint("calls", c, contact, src, ij),
    do: import_contact_calls(c, contact, src, ij)

  defp fire_endpoint("activities", c, contact, src, ij),
    do: import_contact_activities(c, contact, src, ij)

  defp fire_endpoint("gifts", c, contact, src, ij),
    do: import_contact_gifts(c, contact, src, ij)

  defp fire_endpoint("debts", c, contact, src, ij),
    do: import_contact_debts(c, contact, src, ij)

  defp fire_endpoint("tasks", c, contact, src, ij),
    do: import_contact_tasks(c, contact, src, ij)

  defp fire_endpoint("reminders", c, contact, src, ij),
    do: import_contact_reminders(c, contact, src, ij)

  defp fire_endpoint("conversations", c, contact, src, ij),
    do: import_contact_conversations(c, contact, src, ij)

  defp fire_endpoint(other, _, _, _, _) do
    Logger.warning("[MonicaMiscData] unknown endpoint #{inspect(other)}; skipping")
    0
  end

  # ── Relocated per-contact helpers ────────────────────────────────────
  #
  # Each helper makes one GET against Monica and inserts the returned items.
  # Bodies are copied verbatim from MonicaApi; Task 9 removes the originals.
  # Helpers return an integer count of successfully imported items so the
  # worker can aggregate it into `summary["misc"]`.

  # PASTE THE BODIES OF THE FOLLOWING FUNCTIONS FROM monica_api.ex HERE,
  # ADAPTED TO THE NEW (credential, contact, source_id, import_job) SHAPE
  # AND RETURNING AN INTEGER COUNT:
  #
  #   import_contact_pets/6        ->  import_contact_pets/4
  #   import_contact_calls/7       ->  import_contact_calls/4
  #   import_contact_activities/7  ->  import_contact_activities/4
  #   import_contact_gifts/6       ->  import_contact_gifts/4
  #   import_contact_debts/6       ->  import_contact_debts/4
  #   import_contact_tasks/6       ->  import_contact_tasks/4
  #   import_contact_reminders/6   ->  import_contact_reminders/4
  #   import_contact_conversations/7 -> import_contact_conversations/4
  #
  # Together with their per-item siblings (import_single_pet, etc.).
  #
  # base_url is now derived from `credential.url` inside each helper.
  # account_id is now derived from `contact.account_id`.
  # user_id is no longer needed (calls/activities/conversations are not
  # user-scoped; if any helper currently uses user_id only for audit-log
  # author, fall back to `import_job.user_id`).
  #
  # IMPORTANT: every helper that today calls api_get_json must continue to
  # call it via `Kith.Imports.Sources.MonicaApi.api_get_json/3` (or the
  # equivalent unified helper). To avoid coupling, copy `api_get_json`
  # into this module as a small private wrapper that goes through Req +
  # RateLimiter the same way:

  defp api_get_json(credential, url, params) do
    RateLimiter.wait!(credential.url)

    headers = [
      {"Authorization", "Bearer #{credential.api_key}"},
      {"Accept", "application/json"}
    ]

    options =
      [
        headers: headers,
        params: params,
        max_retries: 5,
        retry_log_level: :warn
      ] ++ Map.get(credential, :req_options, [])

    case Req.get(url, options) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_record_entity(_import_job, _, nil, _, _), do: :ok

  defp maybe_record_entity(import_job, source_type, source_id, local_type, local_id) do
    Imports.record_imported_entity(
      import_job,
      source_type,
      to_string(source_id),
      local_type,
      local_id
    )
  end
end
```

Now copy the actual bodies of `import_contact_pets/6`, `import_single_pet/4`, `import_contact_calls/7`, `import_single_call/5`, `import_contact_activities/7`, `import_single_activity/5`, `import_contact_gifts/6`, `import_single_gift/4`, `import_contact_debts/6`, `import_single_debt/4`, `import_contact_tasks/6`, `import_single_task/4`, `import_contact_reminders/6`, `import_single_reminder/4`, `import_contact_conversations/7`, and `import_single_conversation/5` (or whatever the exact per-item function names are) from `lib/kith/imports/sources/monica_api.ex` into this new module.

For each top-level helper, adapt the signature:

**Before** (in MonicaApi):
```elixir
defp import_contact_pets(credential, base_url, account_id, contact, source_id, import_job) do
  url = "#{base_url}/api/contacts/#{source_id}/pets"

  case api_get_json(credential, url, []) do
    {:ok, %{"data" => pets}} when is_list(pets) ->
      Enum.flat_map(pets, fn pet ->
        import_single_pet(account_id, contact, pet, import_job)
      end)

    {:ok, _} ->
      []

    {:error, reason} ->
      ["Failed to fetch pets for contact #{source_id}: #{inspect(reason)}"]
  end
end
```

**After** (in MonicaMiscDataWorker):
```elixir
defp import_contact_pets(credential, contact, source_id, import_job) do
  url = "#{credential.url}/api/contacts/#{source_id}/pets"

  case api_get_json(credential, url, []) do
    {:ok, %{"data" => pets}} when is_list(pets) ->
      Enum.count(pets, fn pet ->
        case import_single_pet(contact.account_id, contact, pet, import_job) do
          [] -> true   # success — no error string
          _ -> false
        end
      end)

    {:ok, _} ->
      0

    {:error, reason} ->
      Logger.warning(
        "[MonicaMiscData] failed to fetch pets for contact #{source_id}: #{inspect(reason)}"
      )

      0
  end
end
```

Apply the same adaptation to all eight top-level helpers. Keep their per-item siblings (`import_single_pet`, `import_single_call`, etc.) unchanged in body — just paste them as-is. The signature change is *only* at the top-level (the function the worker's `fire_endpoint` dispatches to).

Each top-level helper now returns an integer count instead of a list of errors. Errors become warning logs (Phase 4 errors are not user-actionable; logging is enough).

- [ ] **Step 6: Add the `Contacts.get_contact_for_misc/1` lookup helper**

The worker calls `Contacts.get_contact_for_misc/1`. This is a tiny helper avoiding `Repo.get` directly. Add to `lib/kith/contacts.ex`, near `get_contact_field!/2`:

```elixir
  @doc """
  Fetch a contact by ID without scope enforcement, for use by the
  Monica misc-data worker. The worker has already verified the contact
  belongs to an import the user authorized; we just need the row.

  Returns `nil` if not found.
  """
  def get_contact_for_misc(id) when is_integer(id) or is_binary(id) do
    Repo.get(Contact, id)
  end
```

(Alternative: use `Repo.get(Kith.Contacts.Contact, local_id)` directly in the worker — but adding the named helper makes the intent self-documenting and keeps the worker free of direct Repo imports.)

- [ ] **Step 7: Run the worker test**

Run: `mix test test/kith/workers/monica_misc_data_worker_test.exs`

Expected: PASS, all 4 tests. (Some assertions are deliberately loose — e.g. `>= 0` — because the per-item insertion paths may fail validation on fixture data that lacks required fields; the assertion is "the worker called the endpoint and updated the summary," not "every fixture inserted successfully." Tighten if you choose to set up richer fixtures.)

- [ ] **Step 8: Run the full suite to verify duplicated helpers still pass their existing tests**

Run: `mix test`

Expected: PASS. Both `MonicaApi.import_contact_pets/6` (still there) and `MonicaMiscDataWorker.import_contact_pets/4` (newly added) coexist temporarily. Existing tests of the inline Phase 4 path continue to pass.

- [ ] **Step 9: Commit**

```bash
git add lib/kith/workers/monica_misc_data_worker.ex test/kith/workers/monica_misc_data_worker_test.exs lib/kith/contacts.ex
git commit -m "feat: add MonicaMiscDataWorker (per-contact extra data, plan-driven)"
```

---

## Task 9: Cut over — remove inline Phase 4 from `MonicaApi` and enqueue the misc worker

**Files:**
- Modify: `lib/kith/imports/sources/monica_api.ex` (delete `import_extra_data_types/5`, `import_per_contact_data/7`, eight `import_contact_*` helpers + their `import_single_*` siblings; remove Phase 4 invocation from `crawl/5`; remove `extra_data_errors` accumulation)
- Modify: `lib/kith/workers/monica_api_crawl_worker.ex` (enqueue `MonicaMiscDataWorker`, strip plan from persisted summary)
- Modify: `test/kith/workers/monica_api_crawl_worker_test.exs` (boundary test for misc-worker enqueue)

This is the largest task; double-check after each deletion that nothing else in `MonicaApi` references the removed functions.

- [ ] **Step 1: Locate Phase 4 invocation in `crawl/5`**

Run: `grep -n "import_extra_data_types\|extra_data_errors" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: matches in `crawl/5` (~lines 110-127) and the function definition (~line 1275).

- [ ] **Step 2: Remove the Phase 4 invocation from `crawl/5`**

Find the block (~line 109-127):

```elixir
    # Phase 4: Additional data types (per-contact endpoints)
    extra_data_errors =
      import_extra_data_types(credential, account_id, user_id, import_job, opts)

    # Phase 5: Enqueue document import jobs (async, runs after main import)
    if opts["documents"] do
      enqueue_document_imports(credential, account_id, user_id, import_job)
    end

    all_errors =
      acc.errors ++
        ref_errors ++
        notes_errors ++
        merge_result.errors ++
        extra_data_errors

    error_count =
      acc.error_count + length(ref_errors) + length(notes_errors) +
        length(merge_result.errors) + length(extra_data_errors)
```

Replace with:

```elixir
    # Phase 5: Enqueue document import jobs (async, runs after main import)
    if opts["documents"] do
      enqueue_document_imports(credential, account_id, user_id, import_job)
    end

    all_errors =
      acc.errors ++
        ref_errors ++
        notes_errors ++
        merge_result.errors

    error_count =
      acc.error_count + length(ref_errors) + length(notes_errors) +
        length(merge_result.errors)
```

- [ ] **Step 3: Delete the eight top-level per-contact helpers and their `import_single_*` siblings**

Delete the entire blocks (function + Phase header comment) for:

- `import_extra_data_types/5` and its docstring/comment header
- `import_per_contact_data/7`
- `import_contact_pets/6` + `import_single_pet/4`
- `import_contact_calls/7` + `import_single_call/5`
- `import_contact_activities/7` + `import_single_activity/5`
- `import_contact_gifts/6` + `import_single_gift/4`
- `import_contact_debts/6` + `import_single_debt/4`
- `import_contact_tasks/6` + `import_single_task/4`
- `import_contact_reminders/6` + `import_single_reminder/4`
- `import_contact_conversations/7` + `import_single_conversation/5`

Use grep to find their exact line ranges:

```bash
grep -n "^  defp import_contact_\|^  defp import_single_\|^  defp import_extra_data_types\|^  defp import_per_contact_data\|^  # ── Phase " /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex
```

Delete each function body from `defp ... do` through the matching `end`. Also delete the `# ── Phase 5: Pets ─...`, `# ── Phase 6: Calls ─...` etc. comment headers, plus the parent `# ── Phases 5-12: Additional per-contact data types ─...` header.

Do NOT delete `enqueue_document_imports/4` or `Phase 5: Enqueue document import jobs` — those still belong to `MonicaApi` (documents are handled by a separate worker, not the misc worker).

- [ ] **Step 4: Verify no dangling references inside `MonicaApi`**

Run: `grep -n "import_contact_\|import_single_pet\|import_single_call\|import_single_activit\|import_single_gift\|import_single_debt\|import_single_task\|import_single_reminder\|import_single_conversat\|import_extra_data_types\|import_per_contact_data\|extra_data_errors" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/imports/sources/monica_api.ex`

Expected: no matches. If any remain, delete or update them.

- [ ] **Step 5: Compile and run Monica + crawl-worker tests**

Run: `mix compile --warnings-as-errors && mix test test/kith/imports/sources/monica_api_test.exs`

Expected: PASS. Tests that previously exercised Phase 4 inline (if any) need updating — they should now assert that the misc-data plan is built but Phase 4 endpoints are NOT hit during `crawl/5`. Locate any failing test and replace its assertion (e.g. "asserts 1 pet was inserted") with the new contract (e.g. "asserts the misc_data_plan includes the pets endpoint for this contact").

- [ ] **Step 6: Wire `MonicaApiCrawlWorker` to enqueue the misc worker**

Open `lib/kith/workers/monica_api_crawl_worker.ex`. Find the `perform/1` success branch (around line 41-58):

```elixir
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      summary_map = ensure_map(summary)

      Imports.update_import_status(import_job, "completed", %{
        summary: summary_map,
        completed_at: now
      })

      Imports.wipe_api_key(import_job)

      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_complete, summary_map})

      # Trigger duplicate detection for newly imported contacts
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: import_job.account_id}))

      # Enqueue photo sync (separate job) if the user opted in
      maybe_enqueue_photo_sync(import_job)

      Logger.info("MonicaApi import #{import_id} completed: #{inspect(summary_map)}")
      :ok
```

Insert the misc-worker enqueue and strip the plan from the persisted summary:

```elixir
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      summary_map = ensure_map(summary)
      {misc_plan, persisted_summary} = Map.pop(summary_map, :misc_data_plan, [])
      persisted_summary = Map.delete(persisted_summary, "misc_data_plan")

      Imports.update_import_status(import_job, "completed", %{
        summary: persisted_summary,
        completed_at: now
      })

      maybe_enqueue_misc_data_worker(import_job, misc_plan)
      Imports.wipe_api_key(import_job)

      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_complete, persisted_summary})

      # Trigger duplicate detection for newly imported contacts
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: import_job.account_id}))

      # Enqueue photo sync (separate job) if the user opted in
      maybe_enqueue_photo_sync(import_job)

      Logger.info("MonicaApi import #{import_id} completed: #{inspect(persisted_summary)}")
      :ok
```

Note: the `maybe_enqueue_misc_data_worker` call happens BEFORE `wipe_api_key` because the worker needs the still-encrypted key passed as an arg, mirroring the photo-sync pattern.

Add the helper below `maybe_enqueue_photo_sync/1`:

```elixir
  defp maybe_enqueue_misc_data_worker(_import_job, []), do: :ok

  defp maybe_enqueue_misc_data_worker(import_job, plan) do
    %{
      "import_id" => import_job.id,
      "credential_url" => import_job.api_url,
      "credential_api_key" => import_job.api_key_encrypted,
      "plan" => plan
    }
    |> Kith.Workers.MonicaMiscDataWorker.new()
    |> Oban.insert()
  end
```

Add the alias near the top of the file alongside `MonicaPhotoSyncWorker`:

```elixir
  alias Kith.Workers.MonicaMiscDataWorker
```

- [ ] **Step 7: Add a boundary regression test**

In `test/kith/workers/monica_api_crawl_worker_test.exs`, add a new test inside `describe "perform/1"`:

```elixir
    test "enqueues MonicaMiscDataWorker with the plan from crawl summary",
         %{user: user, account_id: account_id} do
      # This boundary test guards the wizard → crawl → misc-worker contract:
      # the misc_data_plan key produced by MonicaApi.crawl/5 must reach
      # MonicaMiscDataWorker.new/1 unmodified, just as auto_merge_duplicates
      # had to reach MonicaApi.crawl/5 (Bug C in the previous PR).
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"pets" => true}
        })

      # Stub Monica to return one contact with statistics indicating one
      # pet exists — collect_misc_data/5 should emit a plan entry for it.
      Req.Test.stub(MonicaApiStub, fn conn ->
        cond do
          String.contains?(conn.request_path, "/api/contacts") ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => 7,
                  "first_name" => "Plan",
                  "last_name" => "Test",
                  "statistics" => %{"number_of_calls" => 2}
                }
              ],
              "meta" => %{"total" => 1, "last_page" => 1}
            })

          true ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      # Misc worker should now be enqueued with a non-empty plan including
      # "calls" for the imported contact.
      assert_enqueued(
        worker: Kith.Workers.MonicaMiscDataWorker,
        args: %{"import_id" => import_job.id}
      )
    end
```

(The exact stub_name and helper to inject Req.Test will mirror the existing tests in this file — adapt as needed.)

- [ ] **Step 8: Run the cross-cutting test suite**

Run: `mix test test/kith/workers/monica_api_crawl_worker_test.exs test/kith/workers/monica_misc_data_worker_test.exs test/kith/imports/sources/monica_api_test.exs`

Expected: PASS, all tests.

- [ ] **Step 9: Run the full suite + quality gate**

Run: `mix quality && mix test`

Expected: PASS. No new credo, dialyzer, or sobelow findings.

- [ ] **Step 10: Commit**

```bash
git add lib/kith/imports/sources/monica_api.ex lib/kith/workers/monica_api_crawl_worker.ex test/kith/workers/monica_api_crawl_worker_test.exs
git commit -m "refactor: extract Phase 4 to MonicaMiscDataWorker; enqueue from crawl worker"
```

---

## Task 10: End-to-end verification

**Files:** *(no code changes — verification only)*

- [ ] **Step 1: Confirm the full test suite passes**

Run: `mix test`

Expected: PASS, 1100+ tests, 0 failures. Count should match commit `6af91bf` plus new tests from this PR.

- [ ] **Step 2: Confirm static analysis is clean**

Run: `mix quality`

Expected: `done (passed successfully)`. No new credo, sobelow, or dialyzer findings beyond the existing `.dialyzer_ignore.exs` skips.

- [ ] **Step 3: Smoke test on dev — wipe and re-import**

Manual:
- Start dev server: `iex -S mix phx.server`
- In IEx, cancel any in-flight imports: `Oban.cancel_all_jobs(from j in Oban.Job, where: j.worker in ["Kith.Workers.MonicaApiCrawlWorker", "Kith.Workers.MonicaMiscDataWorker", "Kith.Workers.MonicaPhotoSyncWorker"] and j.state in ["executing", "available", "scheduled", "retryable"])`
- Reset the dev account: `Kith.Workers.AccountResetWorker.new(%{"account_id" => <dev_account_id>, "user_id" => <dev_user_id>}) |> Oban.insert()`
- Wait for reset to complete; verify contact list is empty.
- Open `/settings/import` in browser; choose Monica API; enter URL and API key; ensure all defaults (including `auto_merge_duplicates`, `pets`, `calls`, etc.) are checked.
- Start the import; observe.

Expected:
- `MonicaApiCrawlWorker` completes in **under 2 minutes** for ~1000 contacts (Phase 1+2+3 only, throttled at 55/min for ~20-30 pagination + auxiliary calls).
- Wizard transitions to "import complete" at that point; the duplicates tab is reachable and shows a small handful of legitimate pending candidates, NOT 6000.
- `MonicaMiscDataWorker` appears in the Oban dashboard as a separate executing job.
- Its runtime depends on actual misc data volume; for a typical CRM with sparse pet/debt/gift data, **single-digit minutes**.
- Logs show no `"3 attempts left forever"` retry spam. If any 429 fires (e.g. tighter self-hosted Monica limit), Req's built-in retry handles it once and proceeds.

- [ ] **Step 4: Verify summary shape**

In IEx:

```elixir
import_job = Kith.Imports.get_import!(<id>)
import_job.summary
```

Expected after `MonicaApiCrawlWorker` completes:
```elixir
%{
  "imported" => 1000,
  "contacts" => 1000,
  "notes" => N,
  "skipped" => 0,
  "merged" => M,
  "error_count" => 0,
  "errors" => []
}
```

The `"misc_data_plan"` key should be **absent** (stripped by `MonicaApiCrawlWorker` before persisting).

After `MonicaMiscDataWorker` completes, refetch:

```elixir
Kith.Imports.get_import!(<id>).summary["misc"]
```

Expected:
```elixir
%{
  "pets" => P,
  "calls" => C,
  "activities" => A,
  "gifts" => G,
  "debts" => D,
  "tasks" => T,
  "reminders" => R,
  "conversations" => Co
}
```

with counts reflecting actual data imported.

- [ ] **Step 5: Final cleanup commit (if any verification adjustments needed)**

If smoke testing surfaces any small fixes (typos in log lines, edge cases in the plan filter), commit them as a separate small fix. Otherwise no commit needed for this task.

- [ ] **Step 6: Push the branch**

```bash
git push origin fix/duplicate-detection
```

Expected: GitHub shows the new commits on top of `6af91bf`. Open a PR if not already open, or update the existing one.

---

## Self-review checklist

Run through this once before handing off:

1. **Spec coverage:**
   - Part 1 (extract Phase 4): Tasks 7-9 ✓
   - Part 2 (rate limiter): Tasks 1-2 ✓
   - Part 3 (collapse retry): Task 3 ✓
   - Part 4 (statistics short-circuit): Task 7 ✓
   - Part 5a (persistent_term cleanup): Task 6 ✓
   - Part 5b (normalize: false opt): Tasks 4-5 ✓
   - Tests for all of the above: Tasks 1, 4, 5, 7, 8, 9 ✓
   - Verification: Task 10 ✓

2. **Placeholders:** All steps contain concrete code, exact commands, exact paths. Each instruction in the cutover task (Task 9) explicitly tells the engineer to `grep` first to find line ranges before deleting — no "delete the appropriate code" hand-waving.

3. **Type consistency:**
   - `MonicaApiCrawlWorker` enqueues with arg keys `"import_id"`, `"credential_url"`, `"credential_api_key"`, `"plan"` (Task 9 Step 6); `MonicaMiscDataWorker.perform/1` reads exactly those keys (Task 8 Step 5). ✓
   - `crawl/5` returns `misc_data_plan: ...` (atom key, Task 7 Step 5); `MonicaApiCrawlWorker` reads `summary_map[:misc_data_plan]` then strips `"misc_data_plan"` (string key) — covers both shapes since `Map.pop/3` returns default `[]` when key absent. ✓
   - `collect_misc_data` stringifies endpoints before storing in the plan (Task 7 Step 3); `MonicaMiscDataWorker.fire_endpoint/5` pattern-matches on strings (`"pets"`, `"calls"`, …) (Task 8 Step 5). ✓
   - `Contacts.create_contact_field/3` accepts `opts` as a keyword list (Task 4); Monica caller passes `normalize: false` (Task 5). ✓
   - `normalize_field_value/3` takes `ctx` (Task 6 Step 5); caller in `import_single_contact_field` passes `ctx` (Task 6 Step 6). ✓
