# Monica Import Deployment Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Monica imports from crashing on the worker container, route Oban jobs exclusively to the worker, and cluster the two BEAM nodes so LiveView progress broadcasts cross containers.

**Architecture:** Move `Phoenix.PubSub` + `DNSCluster` from `mode_children/0` to `base_children/0` so worker mode also starts them. In `runtime.exs` (`:prod` only), gate Oban to insert-only when `KITH_MODE=web`. In `docker-compose.prod.yml`, give each container a unique hostname plus a shared network alias (`kith-cluster`), share `RELEASE_COOKIE`, and set `DNS_CLUSTER_QUERY=kith-cluster`. Phoenix.PubSub's default PG2 adapter then fans broadcasts across both nodes automatically.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Phoenix.PubSub (PG2), DNSCluster 0.2+, Oban 2.18, Docker Compose v2.

**Reference spec:** `docs/superpowers/specs/2026-05-16-monica-import-deployment-fixes-design.md`

---

## Task 1: Move PubSub + DNSCluster to base_children

**Files:**
- Modify: `lib/kith/application.ex`

- [ ] **Step 1: Inspect the current supervisor tree**

Run: `grep -n "Phoenix.PubSub\|DNSCluster\|mode_children\|base_children" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/lib/kith/application.ex`

Expected: matches at the function heads of `base_children/0` and `mode_children/0`, plus the existing PubSub + DNSCluster child specs inside `mode_children/0`'s `_web` branch.

- [ ] **Step 2: Edit `base_children/0` and `mode_children/0`**

In `lib/kith/application.ex`, find the current block:

```elixir
  defp base_children do
    # Install fuse circuit breakers before starting supervised children
    Kith.Geocoding.install_fuse()
    Kith.Weather.install_fuse()
    # Attach Sentry telemetry handler for Oban job failures
    Kith.SentryEventHandler.attach()
    # Capture crashes via Erlang logger handler (Sentry v10+, replaces PlugCapture)
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    [
      Kith.Vault,
      Kith.Repo,
      {Finch, name: Swoosh.Finch, pools: %{:default => [size: 10]}},
      {Oban, Application.fetch_env!(:kith, Oban)},
      {Cachex, name: :kith_cache, expiration: expiration(default: :timer.hours(24))},
      {Task.Supervisor, name: Kith.TaskSupervisor}
    ]
  end

  defp mode_children do
    case System.get_env("KITH_MODE", "web") do
      "worker" ->
        []

      _web ->
        [
          Kith.PromEx,
          KithWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:kith, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Kith.PubSub},
          KithWeb.Endpoint
        ]
    end
  end
```

Replace with:

```elixir
  defp base_children do
    # Install fuse circuit breakers before starting supervised children
    Kith.Geocoding.install_fuse()
    Kith.Weather.install_fuse()
    # Attach Sentry telemetry handler for Oban job failures
    Kith.SentryEventHandler.attach()
    # Capture crashes via Erlang logger handler (Sentry v10+, replaces PlugCapture)
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    [
      Kith.Vault,
      Kith.Repo,
      {Finch, name: Swoosh.Finch, pools: %{:default => [size: 10]}},
      {Oban, Application.fetch_env!(:kith, Oban)},
      {Cachex, name: :kith_cache, expiration: expiration(default: :timer.hours(24))},
      {Task.Supervisor, name: Kith.TaskSupervisor},
      # PubSub + DNSCluster live here (not in mode_children) so worker mode
      # also starts them. Required for cross-container progress broadcasts
      # in the split-deployment topology (`docker-compose.prod.yml`).
      {Phoenix.PubSub, name: Kith.PubSub},
      {DNSCluster, query: Application.get_env(:kith, :dns_cluster_query) || :ignore}
    ]
  end

  defp mode_children do
    case System.get_env("KITH_MODE", "web") do
      "worker" ->
        []

      _web ->
        [
          Kith.PromEx,
          KithWeb.Telemetry,
          KithWeb.Endpoint
        ]
    end
  end
```

Notes:
- PubSub appears before `KithWeb.Endpoint` in startup order, because base_children precedes mode_children in `start/2`. `KithWeb.Endpoint` reads `pubsub_server: Kith.PubSub` from config — the registry is ready before it's needed.
- `DNSCluster` is harmless when its query is `:ignore` (the current default when no `DNS_CLUSTER_QUERY` env var is set).

- [ ] **Step 3: Compile and run the suite**

Run: `mix compile --warnings-as-errors && mix test`

Expected: PASS. 1138 tests, 0 failures (current baseline). `Kith.PubSub` is now running in test env too, which is invisible to test code (no test subscribes/broadcasts; the existing ones use it transparently via LiveView mounts).

- [ ] **Step 4: Manual smoke check — worker-mode startup**

Run: `KITH_MODE=worker iex -S mix`

Expected: app starts, no crash. Inside IEx, verify PubSub is running:

```elixir
Process.whereis(Kith.PubSub)
# Expected: a PID, not nil
```

Exit IEx with `:q + Enter` (twice) or Ctrl-C twice.

- [ ] **Step 5: Commit**

```bash
cd /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection
git add lib/kith/application.ex
git commit -m "fix: start PubSub + DNSCluster in base_children for worker mode"
```

---

## Task 2: Gate Oban queues by KITH_MODE in :prod

**Files:**
- Modify: `config/runtime.exs`

- [ ] **Step 1: Find the rate-limiting block (anchor for the new block)**

Run: `grep -n "Rate limiting" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/config/runtime.exs`

Expected: a match around line 208 (`# Rate limiting — optional Redis backend`).

- [ ] **Step 2: Add the Oban gating block**

In `config/runtime.exs`, find the existing rate-limiting block ending around the existing `if System.get_env("RATE_LIMIT_BACKEND") == "redis" do ... end` block. Immediately AFTER that `end`, but still inside the outer `if config_env() == :prod do` block, add:

```elixir
  # Oban — only the worker container processes jobs in production.
  # The web container can call `Oban.insert/1` to enqueue jobs, but
  # runs no queues or plugins (no cron, no pruner) — so it never claims
  # rows from `oban_jobs`. The worker container keeps the full config
  # from `config.exs`.
  #
  # Dev (`config_env() == :dev`) is unaffected: this block only runs in
  # `:prod`. Test env is pinned to `testing: :manual` in `config/test.exs`.
  case System.get_env("KITH_MODE", "web") do
    "worker" ->
      :ok

    _web ->
      config :kith, Oban, queues: false, plugins: false
  end
```

Make sure indentation matches the surrounding `:prod` block (two spaces).

- [ ] **Step 3: Verify placement is inside the `:prod` guard**

Run: `grep -n "config_env\|config :kith, Oban" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/config/runtime.exs`

Expected: the new `config :kith, Oban` line appears between the `if config_env() == :prod do` line and its closing `end`. The `case KITH_MODE` should NOT be at the top level of the file.

- [ ] **Step 4: Run the test suite**

Run: `mix test`

Expected: PASS, 1138 tests, 0 failures. Test env is `:test` (not `:prod`), so the new block is unreached.

- [ ] **Step 5: Smoke-check the prod compilation path**

Run: `MIX_ENV=prod mix compile 2>&1 | tail -20`

Expected: clean compile (the runtime.exs file is read but not evaluated at compile time, so any logical mistakes won't surface here — Step 6's IEx test is the real check).

- [ ] **Step 6: Manual IEx check (simulate prod KITH_MODE=web)**

Run: `MIX_ENV=prod KITH_MODE=web iex -S mix`

Expected: app starts, then in IEx:

```elixir
Application.get_env(:kith, Oban) |> Keyword.get(:queues)
# Expected: false
Application.get_env(:kith, Oban) |> Keyword.get(:plugins)
# Expected: false
```

Note: `MIX_ENV=prod iex -S mix` may fail if you don't have a prod DB / SECRET_KEY_BASE set. If it raises on startup before reaching IEx, switch to:

```bash
MIX_ENV=prod KITH_MODE=web mix run -e 'IO.inspect(Application.fetch_env!(:kith, Oban))'
```

(also expected to raise on missing prod env vars, but the `config :kith, Oban, ...` mutation runs before that and you'll see `queues: false, plugins: false` in the inspected value if you can get it to surface. If you can't get prod env happily booting, skip this step and rely on Step 7's separate IEx-based KITH_MODE=worker check.)

- [ ] **Step 7: Manual IEx check (simulate prod KITH_MODE=worker)**

If prod-env IEx works:

```bash
MIX_ENV=prod KITH_MODE=worker iex -S mix
```

Then:

```elixir
Application.get_env(:kith, Oban) |> Keyword.get(:queues)
# Expected: a keyword list with default: 10, mailers: 10, ... (full config)
```

If prod IEx is not bootable in your local environment, accept that Step 4's test pass + the inline code review (Step 3) suffice; the real verification will happen in the docker-compose smoke test at Task 5.

- [ ] **Step 8: Commit**

```bash
git add config/runtime.exs
git commit -m "fix: gate Oban queues by KITH_MODE in :prod (web=insert-only)"
```

---

## Task 3: Add clustering env to `docker-compose.prod.yml`

**Files:**
- Modify: `docker-compose.prod.yml`

- [ ] **Step 1: Locate the `app` service definition**

Run: `grep -n "^  app:\|^  worker:" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/docker-compose.prod.yml`

Expected: `app:` around line 61, `worker:` around line 135.

- [ ] **Step 2: Add hostname + env vars + network alias to the `app` service**

In `docker-compose.prod.yml`, find the `app:` block. Insert a `hostname:` field right after `command:` (or another visible top-level field) and add the three new env vars in its `environment:` block. Then add a `networks:` block at the same level as `environment:`.

The `app` service block should look like:

```yaml
  app:
    image: kith:latest
    command: ["start"]
    hostname: kith-app
    depends_on:
      migrate:
        condition: service_completed_successfully
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:size=64M
    environment:
      # ── BEAM distribution / clustering ──
      RELEASE_COOKIE: ${RELEASE_COOKIE}
      RELEASE_DISTRIBUTION: name
      DNS_CLUSTER_QUERY: kith-cluster
      # ── existing env vars unchanged ──
      DATABASE_URL: ${DATABASE_URL}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      # ... (leave the rest of the env block unchanged)
    networks:
      default:
        aliases:
          - kith-cluster
    volumes:
      - uploads:/app/uploads
    # ... (rest unchanged)
```

Important: the existing block does not declare a `networks:` section because Compose creates a default network automatically. The new `networks:` section attaches this service to that same default network, with the `kith-cluster` alias added. Compose accepts this without explicit network definition; if Compose complains about missing top-level `networks:` declaration, add this block at the bottom of the file (outside any service):

```yaml
networks:
  default:
    name: kith_default
```

(only add the top-level block if Compose errors without it — start with just the per-service alias block and only add the top-level if needed.)

- [ ] **Step 3: Add the same three env vars + alias + hostname to the `worker` service**

In the `worker:` block, mirror the changes from Step 2 but use `kith-worker` as the hostname:

```yaml
  worker:
    image: kith:latest
    command: ["start"]
    hostname: kith-worker
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:size=64M
    depends_on:
      postgres:
        condition: service_healthy
      migrate:
        condition: service_completed_successfully
    environment:
      # ── BEAM distribution / clustering ──
      RELEASE_COOKIE: ${RELEASE_COOKIE}
      RELEASE_DISTRIBUTION: name
      DNS_CLUSTER_QUERY: kith-cluster
      # ── existing env vars unchanged ──
      DATABASE_URL: ${DATABASE_URL}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      # ... (leave the rest unchanged)
    networks:
      default:
        aliases:
          - kith-cluster
    # ... (rest unchanged)
```

- [ ] **Step 4: Validate the compose file**

Run:

```bash
docker compose -f /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/docker-compose.prod.yml config 2>&1 | head -40
```

Expected: a parsed render of the compose file with no error. The output should include:
- `hostname: kith-app` and `hostname: kith-worker` lines
- `RELEASE_COOKIE`, `RELEASE_DISTRIBUTION: name`, `DNS_CLUSTER_QUERY: kith-cluster` env keys on both services
- `aliases: [kith-cluster]` under both `app.networks.default` and `worker.networks.default`

If `config` errors out about an undefined `RELEASE_COOKIE` env var, that's expected unless you've already added it to `.env`. Re-run with `RELEASE_COOKIE=$(openssl rand -base64 32) docker compose ... config`. The validation is about structure, not values.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.prod.yml
git commit -m "infra: cluster app + worker containers via shared cookie + DNS alias"
```

---

## Task 4: Document `RELEASE_COOKIE` in `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Find the section anchor**

Run: `grep -n "SECRET_KEY_BASE" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/.env.example`

Expected: a line introducing the SECRET_KEY_BASE entry. Use this as the anchor.

- [ ] **Step 2: Add the `RELEASE_COOKIE` entry**

In `.env.example`, find the `SECRET_KEY_BASE` block and immediately AFTER it (after any comments and the SECRET_KEY_BASE= line itself), add:

```bash
# Erlang BEAM distribution cookie. Shared between the app and worker
# containers so they can cluster for cross-container PubSub broadcasts
# (LiveView import progress). Generate with one of:
#   mix phx.gen.secret 32
#   openssl rand -base64 32
RELEASE_COOKIE=
```

The trailing empty value is intentional — `.env.example` uses empty placeholders elsewhere as a "fill this in" signal. Match the file's style; if other secrets use a placeholder like `<change-me>`, mirror that.

- [ ] **Step 3: Verify the example file**

Run: `grep -A 5 "RELEASE_COOKIE" /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection/.env.example`

Expected: see the comment + the empty assignment.

- [ ] **Step 4: Commit**

```bash
git add .env.example
git commit -m "docs: document RELEASE_COOKIE in .env.example"
```

---

## Task 5: Manual smoke verification (docker-compose.prod)

**Files:** *(no code changes — verification only)*

- [ ] **Step 1: Generate a cookie and put it in `.env`**

```bash
cd /Users/basharqassis/projects/kith/.claude/worktrees/fix-duplicate-detection
echo "RELEASE_COOKIE=$(openssl rand -base64 32)" >> .env
chmod 600 .env
```

(skip if your `.env` already has `RELEASE_COOKIE` set.)

- [ ] **Step 2: Build the prod image with the new code**

```bash
docker build -t kith:latest .
```

Expected: a successful build.

- [ ] **Step 3: Bring up the prod stack**

```bash
docker compose -f docker-compose.prod.yml up -d
```

Wait ~30 seconds for migrate + app + worker to come up. Check status:

```bash
docker compose -f docker-compose.prod.yml ps
```

Expected: `migrate` exited 0, `postgres` running healthy, `app` and `worker` both running.

- [ ] **Step 4: Verify clustering**

```bash
docker compose -f docker-compose.prod.yml exec app /app/bin/kith eval 'IO.inspect(Node.list())'
```

Expected: `[:"kith@kith-worker"]`

```bash
docker compose -f docker-compose.prod.yml exec worker /app/bin/kith eval 'IO.inspect(Node.list())'
```

Expected: `[:"kith@kith-app"]`

If either returns `[]`, wait 10 more seconds (DNSCluster polls periodically) and retry. If still empty, check the symptom matrix in the spec's "Failure modes to watch for" section.

- [ ] **Step 5: Verify Oban gating**

```bash
docker compose -f docker-compose.prod.yml exec app /app/bin/kith eval \
  'IO.inspect(Application.fetch_env!(:kith, Oban) |> Keyword.get(:queues))'
```

Expected: `false`

```bash
docker compose -f docker-compose.prod.yml exec worker /app/bin/kith eval \
  'IO.inspect(Application.fetch_env!(:kith, Oban) |> Keyword.get(:queues))'
```

Expected: `[default: 10, mailers: 10, reminders: 5, exports: 2, imports: 2, immich: 3, purge: 1]`

- [ ] **Step 6: Trigger an import via the wizard**

In a browser, open the app (URL per your local Caddy config, usually `http://localhost`), log in, go to **Settings → Import**, choose **Monica CRM (API)**, enter test credentials for your Monica instance, start the import.

Observe (using `docker compose -f docker-compose.prod.yml logs -f`):

- Worker container log shows `MonicaApiCrawlWorker` starting
- App container log does NOT show `Oban` executor logs
- Browser shows a progress bar updating in real time (PubSub crossed containers)
- On completion, the wizard shows the "import complete" UI

- [ ] **Step 7: Verify the misc worker also runs on worker**

While the import is running (or shortly after main crawl completes), check Oban's job table:

```bash
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U kith -d kith_prod -c \
  "SELECT id, worker, queue, state FROM oban_jobs ORDER BY id DESC LIMIT 10;"
```

Expected: see rows for `Kith.Workers.MonicaApiCrawlWorker` and (after main crawl completes) `Kith.Workers.MonicaMiscDataWorker`, all with `state = 'completed'` (or `executing` while in flight).

- [ ] **Step 8: Verify no PubSub crash on worker**

```bash
docker compose -f docker-compose.prod.yml logs worker | grep -i 'unknown registry\|Kith.PubSub'
```

Expected: empty output (no crashes referencing Kith.PubSub).

- [ ] **Step 9: Tear down**

```bash
docker compose -f docker-compose.prod.yml down
```

(or leave running if you want to keep iterating.)

- [ ] **Step 10: No commit for this task** (verification-only).

---

## Self-review checklist

Before handing off:

1. **Spec coverage:**
   - Bug A (PubSub crash in worker mode) → Task 1 ✓
   - Bug B (Oban race) → Task 2 ✓
   - Bug C (cross-container PubSub) → Task 1 + Task 3 ✓
   - `.env.example` documentation → Task 4 ✓
   - Verification → Task 5 ✓

2. **Placeholders:** Every step has concrete code/commands. No "TBD", "implement later", "add error handling".

3. **Type consistency:**
   - `KITH_MODE` env var spelled consistently (matches application.ex case statement)
   - `RELEASE_COOKIE`, `RELEASE_DISTRIBUTION`, `DNS_CLUSTER_QUERY` consistent across compose + spec
   - Network alias `kith-cluster` consistent on both services + `DNS_CLUSTER_QUERY` value
   - Hostnames `kith-app` / `kith-worker` consistent with Node.list() expectations in Task 5

4. **Order safety:**
   - Task 1 is safe in isolation (PubSub starts in worker mode, no behavior change in web mode)
   - Task 2 builds on Task 1 (without Task 1, gating queues to worker means jobs run there and crash on PubSub broadcast)
   - Task 3 builds on Task 2 (without clustering, gating means no LiveView progress)
   - Task 4 is metadata-only
   - Task 5 verifies the cumulative effect

   If anything stops working mid-implementation, intermediate state after Task 1 alone is strictly better than current state (crash is fixed; race remains).

5. **Backout:** Each task is a single commit. `git revert <sha>` cleanly undoes any one task without affecting the others (Task 2 depends on Task 1 for correctness but not for compile; the inverse holds for Task 3 + Task 2).
