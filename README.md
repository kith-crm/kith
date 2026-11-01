
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
- **CardDAV/CalDAV** — sync contacts with your phone or email client
- **REST API** — bearer token auth, cursor pagination, compound documents
- **Multi-account** — account-scoped multitenancy with full data isolation
- **Background jobs** — powered by Oban with 9 queues and nightly cron tasks
- **Security** — WebAuthn/passkeys, TOTP 2FA, OAuth (GitHub, Google), encrypted sensitive fields

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
npm run test:pr44
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
