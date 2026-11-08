# Playwright E2E Tests

Browser-based end-to-end tests for Kith. These tests run against a live Phoenix
server using real Chromium, covering authentication flows, contact management,
settings, and integrations.

## Prerequisites

```bash
# Install Playwright browsers (one-time)
npx playwright install chromium
```

## Running Tests

```bash
# 1. Start the Phoenix server (dev or test mode)
mix phx.server
# or: MIX_ENV=test mix phx.server

# 2. (Optional) Seed test data for pre-populated tests
MIX_ENV=test mix run test/playwright/seed.exs

# 3. Run the E2E test suite
npx playwright test --project=e2e

# Run a single spec file
npx playwright test --project=e2e test/playwright/auth.spec.ts

# Run with headed browser (visible)
npx playwright test --project=e2e --headed

# Run the separate smoke tests (e2e/ directory)
npx playwright test --project=smoke
```

## Mobile viewport regression

`mobile-layout.spec.ts` checks the real authenticated app shell on the long
Account settings page, including content scroll boundaries and extra outward
scroll gestures. It runs in the maintained `npm run test:regressions` CI harness.
That harness provisions fresh users with email double opt-in disabled.

For an already running local development server with double opt-in enabled,
use a confirmed **test** account:

```sh
MOBILE_LAYOUT_EMAIL=playwright@test.local \
  npx playwright test --project=e2e --workers=1 test/playwright/mobile-layout.spec.ts
```

The default password is the test fixture password from `helpers/auth.ts`;
`MOBILE_LAYOUT_PASSWORD` can override it. Do not target production.

The normal viewport is a control. The 57px browser-toolbar case models the
physical Xiaomi capture (visible viewport about 802px, large viewport about
859px). A test-only stylesheet adapter resolves legacy `vh`/`lvh` lengths
against the large viewport, leaving `dvh`/`svh` at their normal visible sizes.
This is a deterministic simulation of the measured browser-sizing contract,
not full Android toolbar/touch emulation. No app class or component height is
overridden. Ordinary Playwright viewport resizing makes `vh` and `dvh` equal
and cannot catch this failure by itself.

Assertions require the header and bottom menu to stay inside the visible
viewport and the outer document to remain unscrollable. The content must still
scroll. Retain physical Android verification for native touch, browser toolbar,
safe-area, and keyboard behavior. The 57px case guards against restoring a
large-viewport shell height; do not skip it or mark it as expected failure.

## CardDAV live harness

The harness recreates its dedicated fresh database and seeds 2,000 performance
contacts. PostgreSQL, project dependencies, npm dependencies (`npm ci`), Python 3,
curl, xmllint and Chromium are required.

```bash
set -e
trap 'scripts/carddav-e2e/down.sh' EXIT
scripts/carddav-e2e/up.sh
source .carddav-task10/env
npx playwright test --project=e2e test/playwright/carddav
scripts/carddav-e2e/vdirsyncer-smoke.sh
```

`scripts/carddav-e2e/up.sh` fixes `DB_NAME=kith_carddav_task10_e2e`, port 4527
and a fresh `STORAGE_PATH` under `.carddav-task10/`; these override normal dev
configuration. They are not configurable harness inputs. For a separately
managed server, `DB_NAME` and `STORAGE_PATH` select its database/storage, and
`PLAYWRIGHT_BASE_URL` overrides Playwright's default `http://127.0.0.1:4000`.
Source the generated environment before running harness tests; it also sets
`PLAYWRIGHT_OUTPUT_DIR` and serializes shared-account DAV specs.
`PLAYWRIGHT_CHROMIUM_EXECUTABLE` can select an installed compatible Chromium.
`down.sh` stops the recorded server; `vdirsyncer-smoke.sh` runs a scripted sync
client in a temporary virtual environment. See [client results and limitations](../../docs/carddav-client-checklist.md).

## Test Data Setup

Playwright tests run outside the Elixir test harness — they hit the running
application over HTTP. Most tests self-provision by registering a fresh user
via the registration form (see `helpers/auth.ts`). For tests that need
pre-existing data:

- **Seed script** — `MIX_ENV=test mix run test/playwright/seed.exs`
  Creates a known user (`playwright@test.local` / `ValidP@ssword123!`)
  with sample contacts, notes, and reference data.

## Architecture

Tests are self-isolating: each test registers a unique user with a timestamped
email address, so tests can run in parallel without cross-contamination. The
shared `helpers/auth.ts` module provides `registerUser()`, `loginUser()`, and
`logoutUser()` helpers.

## Directory Structure

```
test/playwright/
├── README.md              # This file
├── carddav/               # DAV protocol, browser and performance specs
├── carddav_seed.exs        # Dedicated live-harness accounts and fixtures
├── helpers/
│   └── auth.ts            # Shared auth helpers (register, login, logout)
├── auth.spec.ts           # Authentication flows (21 tests)
├── contacts.spec.ts       # Contact CRUD, search, notes (10 tests)
├── reminders.spec.ts      # Reminder management (3 tests)
├── settings.spec.ts       # Account/user settings, tags (10 tests)
├── immich.spec.ts         # Immich photo integration (4 tests)
├── import-export.spec.ts  # vCard import/export (4 tests)
├── screenshots/           # Screenshot baselines for visual regression
└── seed.exs               # Elixir script to seed test data
```

## Conventions

- One `.spec.ts` file per feature area
- Tests use resilient selectors: `getByRole`, `getByLabel`, `getByPlaceholder`
- Optional UI elements are guarded with `count() > 0` checks to avoid
  flakiness when features are toggled off
- Each `beforeEach` registers a fresh user to avoid state leakage

## Relationship to Other Test Suites

| Suite | Runner | Scope | Isolation |
|-------|--------|-------|-----------|
| ExUnit (`mix test`) | ExUnit | Unit + integration | Ecto sandbox |
| Smoke (`e2e/`) | Playwright | Unauthenticated pages | None (stateless) |
| **E2E** (`test/playwright/`) | Playwright | Full user flows | Per-user registration |
