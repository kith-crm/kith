# Monica Import Deployment Fixes — Design Spec

**Date:** 2026-05-16
**Status:** Approved (brainstorming)
**Branch:** `fix/duplicate-detection`

## Problem statement

In the production split-container deployment (`docker-compose.prod.yml`: separate `app` and `worker` services), the Monica importer crashes with:

```
** (ArgumentError) unknown registry: Kith.PubSub. Either the registry name is
   invalid or the registry is not running, possibly because its application
   isn't started
    (phoenix_pubsub 2.2.0) lib/phoenix/pubsub.ex:232: Phoenix.PubSub.broadcast/4
    (kith 0.1.0) lib/kith/imports/sources/monica_api.ex:255: ...
    (oban 2.20.3) lib/oban/queue/executor.ex:145: Oban.Queue.Executor.perform/1
```

Root cause analysis identifies **two distinct bugs** that compound each other:

### Bug A — PubSub not started in worker mode

`lib/kith/application.ex` starts `{Phoenix.PubSub, name: Kith.PubSub}` only in
`mode_children/0`, which is `[]` when `KITH_MODE=worker`. Every import job that
broadcasts progress or completion (`maybe_broadcast_progress/4`,
`MonicaApiCrawlWorker` completion, `MonicaMiscDataWorker` completion) crashes
on the worker container.

### Bug B — Oban runs on both containers without gating

`config/config.exs` configures Oban with `queues:` and `plugins:` set
unconditionally. Both `app` and `worker` containers start the same Oban
supervisor and race for jobs via Postgres row-level locks. Symptoms:

- When the **app** wins the race, the job runs to completion (PubSub works,
  LiveView gets progress) — but jobs leak into the web-facing container,
  defeating the split.
- When the **worker** wins the race, the job crashes on first broadcast
  (Bug A), retries via Oban, eventually fails or gets re-claimed by the app.

### Bug C — PubSub does not cross containers

Fixing Bug A and Bug B alone causes a regression: with `KITH_MODE=web` Oban
gated off, only the worker processes jobs; but `Phoenix.PubSub` (default
`PG2` adapter) requires connected BEAM nodes to span containers, and the
current deployment has no Erlang clustering (`RELEASE_COOKIE` unset, no
`DNS_CLUSTER_QUERY`, no `libcluster`). LiveView subscribers in the `app`
container would never receive worker-emitted broadcasts.

Three LiveViews depend on these broadcasts:

- `lib/kith_web/live/import_wizard_live.ex` (subscribes line 79)
- `lib/kith_web/live/settings_live/import.ex` (subscribes line 37)
- `lib/kith_web/live/import_history_live/show.ex` (subscribes line 19)

## Goals

1. Worker container processes Monica imports without crashing.
2. Only the worker container runs Oban jobs in production.
3. LiveView subscribers in the `app` container receive progress and completion
   broadcasts emitted by the `worker` container.
4. No regression to dev (single container via `mix phx.server` or
   `docker-compose.dev.yml`) or test (`Oban.testing: :manual`) environments.

## Non-goals

- Multi-replica scaling (multiple `app` or multiple `worker` containers). This
  design targets the user's stated 1+1 topology. The clustering approach
  (DNSCluster + shared alias) extends naturally to multi-replica, but no
  config or testing is included for that case.
- Multi-DC deployments. The PG2 adapter is single-region; cross-region would
  need a Redis or Postgres-LISTEN adapter (deferred).
- Refactoring the Monica importer or misc worker beyond what these fixes
  require.
- Replacing Phoenix.PubSub with an external broker.

## Architecture

### `lib/kith/application.ex`

`Phoenix.PubSub` and `DNSCluster` move from `mode_children/0` to
`base_children/0`. These are application-layer concerns, not HTTP-layer:

```elixir
defp base_children do
  Kith.Geocoding.install_fuse()
  Kith.Weather.install_fuse()
  Kith.SentryEventHandler.attach()
  :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

  [
    Kith.Vault,
    Kith.Repo,
    {Finch, name: Swoosh.Finch, pools: %{:default => [size: 10]}},
    {Oban, Application.fetch_env!(:kith, Oban)},
    {Cachex, name: :kith_cache, expiration: expiration(default: :timer.hours(24))},
    {Task.Supervisor, name: Kith.TaskSupervisor},
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

`KithWeb.Endpoint` references `pubsub_server: Kith.PubSub` (config.exs:79).
PubSub now starts strictly before Endpoint within `base_children` → ordering
is safe.

### `config/runtime.exs` — Oban mode gating

Added inside the existing `if config_env() == :prod do` block (near the
`# Rate limiting` section, around line 216):

```elixir
# Oban — only the worker container processes jobs in production.
# The web container can call `Oban.insert/1` (queues are still defined
# by name in config.exs so insertion validates) but runs no queues or
# plugins. KITH_MODE=worker keeps the full config from config.exs.
case System.get_env("KITH_MODE", "web") do
  "worker" ->
    :ok

  _web ->
    config :kith, Oban, queues: false, plugins: false
end
```

This is wrapped by the `:prod` env guard so dev (`mix phx.server`,
single-container `docker-compose.dev.yml`) is unaffected. Test env is
already pinned to `testing: :manual` in `config/test.exs:27`.

### `docker-compose.prod.yml` — clustering

Both `app` and `worker` services gain:

```yaml
hostname: kith-app          # or kith-worker
environment:
  RELEASE_COOKIE: ${RELEASE_COOKIE}
  RELEASE_DISTRIBUTION: name
  DNS_CLUSTER_QUERY: kith-cluster
networks:
  default:
    aliases:
      - kith-cluster
```

Mechanics:

- `RELEASE_COOKIE` (same on both): the Erlang distribution shared secret.
  Required env; if unset, BEAM generates a random one per container and
  nodes can't connect.
- `RELEASE_DISTRIBUTION: name`: long-form node names use FQDN-style hostnames,
  letting Docker DNS resolve them.
- `hostname: kith-app` / `kith-worker`: unique BEAM node hostnames. The
  resulting node names are `kith@kith-app` and `kith@kith-worker`.
- `aliases: [kith-cluster]`: both containers register this alias in Docker's
  embedded DNS. `kith-cluster` then resolves to **both** container IPs (Docker
  returns all matching A records).
- `DNS_CLUSTER_QUERY: kith-cluster`: tells `Phoenix.DNSCluster` (already a dep)
  to query that name on a periodic interval. Each result IP it doesn't already
  see as a connected node gets `Node.connect/1`. Idempotent and self-healing.

Once nodes are connected, `Phoenix.PubSub` with the default PG2 adapter
broadcasts cross-node automatically. No code changes elsewhere needed.

### `.env.example`

Add a `RELEASE_COOKIE` entry with generation instructions:

```bash
# Erlang BEAM distribution cookie (shared between app and worker containers
# so they can cluster for cross-container PubSub). Generate with:
#   mix phx.gen.secret 32
# or:
#   openssl rand -base64 32
RELEASE_COOKIE=your-shared-cookie-here
```

Place it adjacent to `SECRET_KEY_BASE` in the secrets section.

## Verification

### Automated

- Existing test suite continues to pass unchanged. PubSub is now started in
  `base_children`, which already runs in test env via `Kith.DataCase`. The
  Oban gating block is wrapped in `if config_env() == :prod` so test env is
  not affected.

### Manual (prod-like)

```bash
# 1. Generate cookie
RELEASE_COOKIE=$(openssl rand -base64 32)
# add to .env

# 2. Bring up the prod stack
docker compose -f docker-compose.prod.yml up --build

# 3. Verify clustering
docker compose -f docker-compose.prod.yml exec app \
  /app/bin/kith eval 'IO.inspect(Node.list())'
# Expected: [:"kith@kith-worker"]

docker compose -f docker-compose.prod.yml exec worker \
  /app/bin/kith eval 'IO.inspect(Node.list())'
# Expected: [:"kith@kith-app"]

# 4. Verify Oban gating
docker compose -f docker-compose.prod.yml exec app \
  /app/bin/kith eval 'IO.inspect(Oban.config().queues)'
# Expected: [] or false (web is insert-only)

docker compose -f docker-compose.prod.yml exec worker \
  /app/bin/kith eval 'IO.inspect(Oban.config().queues)'
# Expected: [default: 10, mailers: 10, ...] (full config)

# 5. Trigger an import from the wizard UI; observe:
#    - worker logs: MonicaApiCrawlWorker starts and progresses
#    - app logs: no Oban executor logs
#    - browser: LiveView progress bar updates in real time
#    - browser: completion message renders when crawl finishes
```

### Failure modes to watch for

- `RELEASE_COOKIE` unset → containers generate independent cookies → nodes
  never connect. Symptom: `Node.list()` is empty on both, progress doesn't
  cross. Fix: set the env var.
- Docker DNS returns only one IP for the alias → only one connection
  direction works. Mitigation: DNSCluster polls periodically; the other
  direction self-heals within a few seconds. Symptom of permanent breakage:
  `Node.list()` empty on one container.
- Worker container started before app container's BEAM is ready → initial
  cluster connect may fail, then succeed on the next DNSCluster poll. Not
  user-visible because no import would be running during that window.

## Trade-offs

| Aspect | Cost | Mitigation |
|---|---|---|
| New env var `RELEASE_COOKIE` | One more secret to manage | Standard Erlang/Phoenix pattern; documented in `.env.example` |
| BEAM distribution exposed inside Docker network | Increases internal attack surface if Docker network is compromised | Network is internal-only (no published ports); cookie is opaque to anyone without the secret |
| DNSCluster polling overhead | One DNS query every 5s per container | Negligible; same as existing Phoenix-stack pattern |
| Bound to 1-app-1-worker topology for now | Multi-replica needs further testing | Documented as non-goal; DNSCluster + alias extends naturally |

## Implementation order

1. `lib/kith/application.ex` — move PubSub + DNSCluster to base_children. Tests
   pass.
2. `config/runtime.exs` — add Oban gating block. Tests pass (gated by `:prod`).
3. `docker-compose.prod.yml` — add hostname, env vars, network alias.
4. `.env.example` — document RELEASE_COOKIE.
5. Manual smoke test per the verification section above.

Each step is independently committable; an intermediate state (e.g. step 1+2
without step 3) is "worker no longer crashes, race condition remains" — a
strict improvement over the current state.

## Out of scope (future work)

- Multi-replica web/worker scaling
- Replacing PG2 PubSub with Redis or Postgres for cross-DC support
- Health checks for cluster connection state (could surface a degraded mode
  indicator in the import history UI)
- Migrating `Phoenix.PubSub.broadcast` call sites in the import path to a
  thin wrapper that logs broadcasts (helpful for ops debugging, but not
  required for correctness)
