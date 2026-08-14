# Kith

Personal CRM built with Elixir, Phoenix LiveView, PostgreSQL, and Oban.
Account-scoped multitenancy — all data is isolated per account.

## Commands

```bash
# Setup
mix setup                    # deps.get + ecto.setup + assets.setup + assets.build

# Development
mix phx.server               # Start dev server on localhost:4000
iex -S mix phx.server        # Start with IEx shell attached

# Database
mix ecto.migrate             # Run pending migrations
mix ecto.reset               # Drop + create + migrate + seed

# Code quality
mix format                   # Format all .ex/.exs/.heex files
mix compile --warnings-as-errors
mix credo --strict           # Static analysis (style/consistency)
mix dialyzer                 # Type-based static analysis (first run builds PLT ~5-12 min)
mix quality                  # All static analysis: compile + format + credo + sobelow + dialyzer
mix precommit                # compile + unlock unused + format + credo + test

# Tests — ExUnit
mix test                     # All unit/integration tests
mix test test/path/to_test.exs              # Single file
mix test test/path/to_test.exs:42           # Single test at line
mix test --only integration                 # Tagged tests only
MIX_TEST_PARTITION=1 mix test               # Partitioned (CI)

# Tests — Playwright E2E (requires running server)
mix phx.server                              # Terminal 1
npx playwright test --project=e2e           # Terminal 2
npx playwright test --project=e2e test/playwright/auth.spec.ts  # Single spec
npx playwright test --project=e2e --headed  # Visible browser
npx playwright test --project=smoke         # Smoke tests (e2e/ dir)

# Tests — Wallaby browser
WALLABY=1 mix test --only wallaby
WALLABY_HEADLESS=false WALLABY=1 mix test --only wallaby  # Headed

# Assets
mix assets.build             # Compile tailwind + esbuild
mix assets.deploy            # Minified build + phx.digest
```

## Test Tags

```elixir
@tag :integration   # DB-touching tests (most tests, Ecto sandbox)
@tag :external      # Hits real APIs (Immich, LocationIQ). Skipped unless EXTERNAL_TESTS=true
@tag :wallaby       # Browser E2E. Run with: WALLABY=1 mix test --only wallaby
@tag :slow          # Large dataset perf tests. Run with: mix test --only slow
```

## Architecture

```
lib/kith/              # Domain layer (contexts + schemas)
  accounts/            # Users, accounts, OAuth, WebAuthn, invitations, scopes
  activities/          # Activities, life events, calls
  audit_logs/          # Audit trail for contact operations
  contacts/            # Core: contacts, addresses, tags, notes, fields, relationships,
                       #   debts, gifts, photos, documents, pets, emotions, duplicates
  conversations/       # Conversations + messages
  dav/                 # CardDAV/CalDAV integration
  immich/              # Immich photo server read-only integration
  imports/             # Import records + source tracking (vCard, Monica CRM)
  journal/             # Journal entries
  reminders/           # Reminders, rules, instances (birthday, stay-in-touch, recurring)
  storage/             # File storage abstraction (local disk / S3)
  tasks/               # Personal tasks
  vcard/               # vCard parser + serializer
  workers/             # 16 Oban workers across 7 queues

lib/kith_web/          # Web layer
  controllers/api/     # REST API controllers (bearer token auth, cursor pagination)
  live/                # Phoenix LiveView pages
  components/          # Reusable UI components
  plugs/               # CSP, rate limiting, API auth, locale
  api/                 # Includes + pagination helpers

config/                # Environment configs (dev/test/prod/runtime)
priv/repo/migrations/  # Ecto migrations
test/                  # ExUnit tests
test/playwright/       # Playwright E2E specs
e2e/                   # Playwright smoke tests
specs/                 # Product specification
docs/adr/              # Architecture Decision Records (7 ADRs)
docs/plan/             # Implementation phase plans
```

## Key Patterns

### Scope-based multitenancy
All queries are scoped through `Kith.Accounts.Scope` which carries `user` + `account`.
Context functions receive `scope` as first argument. Never query without scope.

### Soft-delete
Contacts use `deleted_at` timestamp (nullable). Deleted contacts are excluded from
default queries. 30-day trash before permanent purge via `ContactPurgeWorker`.

### Oban background jobs
Workers live in `lib/kith/workers/`. Queues: default, mailers, reminders, exports,
imports, immich, purge. Four cron jobs run nightly/weekly.
Tests use `Oban.Testing` — Oban is disabled in test env.

### REST API conventions
- Bearer token auth (POST /api/auth/token to create)
- Cursor pagination (not offset) — see ADR-005
- `?include=` for compound documents (e.g., `?include=addresses,tags`)
- RFC 7807 error responses via `FallbackController`
- API lives at `/api` (no version prefix; future breaking changes use `/api/v2`)

### LiveView
Pages use `live_session` blocks with `on_mount` auth hooks. Routes require both
authenticated user and confirmed email. All LiveView routes are in the
`:require_authenticated_user` live session.

## Database

PostgreSQL 15+. 27 tables. Bigserial PKs. UTC timestamps everywhere.
Cloak encryption vault for sensitive fields (API keys).

## Environment

See `.env.example` for all env vars. Key ones:
- `DATABASE_URL` — PostgreSQL connection string
- `SECRET_KEY_BASE` — Phoenix secret (generate with `mix phx.gen.secret`)
- `KITH_MODE` — `web` (full app) or `worker` (Oban only, no HTTP)
- `PHX_HOST` — hostname for URL generation
- `CLOAK_PRIMARY_KEY` — encryption key for sensitive data

## Commit Rules

- Never add `Co-Authored-By` lines to commits. All commits should be attributed solely to the git user.
- Always run `mix test` before every commit and ensure 0 failures. If tests fail, fix them before committing.

## Gotchas

- MIME types: `.vcf` registered as `text/vcard` in config.exs (needed for LiveView uploads)
- `mix format` uses `Phoenix.LiveView.HTMLFormatter` plugin for `.heex` files
- Wallaby tests need `WALLABY=1` env var — they're excluded by default
- Playwright tests run outside Elixir test harness — they hit the running server over HTTP
- Soft-deleted contacts: always check `deleted_at IS NULL` in custom queries
- The Scope struct must have `account` preloaded — `Scope.for_user/1` extracts it from user
- Display names are computed fields — `DisplayNameRecomputeWorker` recomputes them async
- Immich integration is read-only (ADR-007) — never write to Immich
- Rate limiting uses ETS by default; set `RATE_LIMIT_BACKEND=redis` for multi-node

## ADRs

| # | Decision |
|---|----------|
| 001 | Elixir over Rails/Django |
| 002 | REST over GraphQL |
| 003 | PKCE OAuth via Assent |
| 004 | Oban for background jobs |
| 005 | Cursor pagination over offset |
| 006 | Soft-delete with scope |
| 007 | Immich read-only integration |
