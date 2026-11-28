
> [!WARNING]
> This repo is in development and is NOT considered prodution ready.

# Kith

A personal CRM for maintaining meaningful relationships. Built with Elixir, Phoenix LiveView, and PostgreSQL.

Kith helps you keep track of the people who matter most — their birthdays, how you met, conversations you've had, gifts you've exchanged, and when you last reached out. Think of it as a personal relationship manager that respects your privacy and runs entirely on your own infrastructure.

## Features

- **Contact management** — addresses, tags, notes, custom fields, relationships, pets, and more
- **Activities and life events** — track calls, meetings, and milestones
- **Conversations and journal** — log interactions and personal reflections
- **Reminders** — birthday alerts, stay-in-touch nudges, and recurring reminders
- **Photo sync** — read-only integration with [Immich](https://immich.app) photo servers
- **Import/export** — vCard and Monica CRM import support
- **CardDAV** — sync contacts with your phone or email client
  Set up `https://<host>/dav` (or discovery via `/.well-known/carddav`) with Basic auth using your account email and password; see [setup and client limits](docs/carddav.md).
- **REST API** — bearer token auth, cursor pagination, compound documents
- **Multi-account** — account-scoped multitenancy with full data isolation
- **Background jobs** — powered by Oban with 9 queues and nightly cron tasks
- **Security** — WebAuthn/passkeys, TOTP 2FA, OpenID Connect, encrypted sensitive fields

## Prerequisites

- **Erlang** 26+ and **Elixir** 1.15+
- **PostgreSQL** 15+
- **Node.js** 18+ (for asset compilation and Playwright tests)

## Local Development Setup

1. **Clone the repo**

   ```bash
   git clone https://github.com/yourusername/kith.git
   cd kith
   ```

2. **Copy the environment file**

   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

   Edit `.env` and fill in at minimum:
   - `SECRET_KEY_BASE` — generate with `mix phx.gen.secret`
   - `DATABASE_URL` — your local PostgreSQL connection string (e.g., `ecto://postgres:postgres@localhost:5432/kith_dev`)
   - `CLOAK_KEY` — generate a 32-byte base64 key: `openssl rand -base64 32`

3. **Install dependencies and set up the database**

   ```bash
   mix setup
   ```

   This runs `deps.get`, `ecto.setup` (create + migrate + seed), `assets.setup`, and `assets.build`.

4. **Start the dev server**

   ```bash
   mix phx.server
   ```

   Or with an interactive Elixir shell:

   ```bash
   iex -S mix phx.server
   ```

   Visit [localhost:4000](http://localhost:4000) in your browser.

## Docker Setup

For production or isolated local development, Docker Compose files are provided:

```bash
# Development
docker compose -f docker-compose.dev.yml up

# Production
docker compose -f docker-compose.prod.yml up -d
```

## Running Tests

```bash
# All tests
mix test

# Single file or line
mix test test/path/to_test.exs
mix test test/path/to_test.exs:42

# Playwright E2E (requires a running server in another terminal)
mix phx.server                              # Terminal 1
npx playwright test --project=e2e           # Terminal 2

# Isolated browser regressions (starts its own fixture server)
npm run test:regressions
```

### Test Tags

| Tag | Purpose | How to run |
|-----|---------|------------|
| `:integration` | DB-touching tests (most tests) | `mix test` (default) |
| `:external` | Hits real APIs (Immich, LocationIQ) | `EXTERNAL_TESTS=true mix test --only external` |
| `:slow` | Large dataset performance tests | `mix test --only slow` |

## Code Quality

```bash
mix format                        # Format code
mix compile --warnings-as-errors  # Strict compilation
mix precommit                     # All checks: compile + format + test
```

## Architecture Overview

```
lib/kith/           # Domain layer — contexts and schemas
lib/kith_web/       # Web layer — LiveView, controllers, components
config/             # Environment configs (dev/test/prod/runtime)
priv/repo/          # Ecto migrations
test/               # ExUnit tests
test/playwright/    # Playwright E2E specs
```

Key architectural decisions are documented in `docs/adr/`.

## Environment Variables

See `.env.example` for the full list. Key variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `SECRET_KEY_BASE` | Yes | Phoenix secret key |
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `CLOAK_KEY` | Yes | Encryption key for sensitive data |
| `KITH_HOSTNAME` | No | Hostname for URL generation (default: `localhost`) |
| `KITH_MODE` | No | `web` (full app) or `worker` (Oban only) |
| `MAILER_ADAPTER` | No | `smtp`, `mailgun`, `ses`, or `postmark` |
| `IMMICH_ENABLED` | No | Enable Immich photo sync integration |

### Retiring legacy social login

The web process needs password login, generic OIDC, or an explicit
`PASSKEYS_ENABLED=true` declaration for passkey-only installations. Existing
passkeys remain available. Worker processes do not serve a login page.

Deploy the runtime removal first. Normal release migrations leave
`user_identities` available to older instances. After every old instance is
retired, inventory affected accounts with the following read-only query.

```sql
SELECT u.account_id, i.user_id, i.provider, count(*)
FROM user_identities i JOIN users u ON u.id = i.user_id
GROUP BY u.account_id, i.user_id, i.provider;
```

Have each affected user demonstrate a working password, passkey or linked
identity at the configured issuer. Legacy registration generated a random
password, so the existence of a password hash does not establish access.
Obtain separate deletion authorization and take a recoverable backup before
running the deferred migration with
`bin/kith eval "Kith.Release.retire_user_identities()"` in the release.
The historical creation migration remains in the normal migration directory.
