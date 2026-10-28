# PR44 regression E2E harness

Runs six Playwright tests covering all five agreed fixes against real Phoenix UI,
Postgres, importer/worker contexts, and SMTP delivery to Mailpit. The Monica source
is a deterministic HTTP server, not a mocked importer: it returns ten notes and
an exchange with identical sent/received messages at the same timestamp.

Use a local development checkout only. The harness requires `PR44_E2E=1`, disables
automatic Oban execution, and explicitly controls dispatch/delivery. Each test
creates its own account through `Accounts.register_user`; login, duplicate
rejection, import submission, deletion, snoozing, and archival use the actual UI.
The disabled-reminder test uses the actual authenticated REST API. Message
contents and direction are also checked through the REST API.

## Prerequisites

- Elixir/OTP from `.tool-versions`, `mix deps.get`, root `npm ci`.
- PostgreSQL at `DB_PORT` (default development compose port 5434).
- Mailpit SMTP at `127.0.0.1:1025` and HTTP at `127.0.0.1:8025`.
- Playwright Chromium: `npx playwright install chromium`.

Use a separate test partition so browser data cannot contaminate ExUnit tests:

```sh
export MIX_ENV=test
export MIX_TEST_PARTITION=pr44_e2e
export DB_PORT=5448
export PR44_E2E=1
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
mix assets.setup
mix assets.vendor
mix assets.build
```

Start the HTTP fixture in another terminal:

```sh
python3 test/playwright/fixtures/pr44/monica.py --port 8094
```

Start Phoenix with the same exports as above:

```sh
mix run --no-start test/playwright/fixtures/pr44/server.exs
```

Run the tests with the same exports:

```sh
npx playwright test --project=e2e --workers=1 test/playwright/pr44-regressions.spec.ts
```

The spec defaults to `http://127.0.0.1:8094` for Monica and
`http://127.0.0.1:8025` for Mailpit. Override with `PR44_MONICA_URL` and
`MAILPIT_URL`. Its bearer token is the fixed local fixture value
`pr44-fixture-token`. No external Monica account or production credentials are
used. The normal Playwright configuration targets Phoenix on port 4000.

## Test coverage

1. Mark A/C **Not duplicates** through the merge wizard, add strong A/B and B/C
   candidates, run auto-merge twice, and verify A/C still map to different live
   survivors and that the contacts UI shows both.
2. Import through the wizard; verify all ten notes. Move to Trash, confirm mappings
   remain, click **Delete Forever**, confirm child mappings are gone, then import
   again and verify all ten notes under a new contact ID.
3. Dispatch a reminder, disable it through the REST API, then execute its queued
   email worker and verify discard plus zero SMTP messages to that test user.
4. Verify a deceased contact's **Visit grave** reminder appears in Upcoming and
   dispatches/delivers a real email to Mailpit.
5. Snooze through the UI, archive through the contact menu, expire the snooze's
   timestamp, and dispatch: it must remain snoozed with no new email job. Unarchive
   and dispatch twice: it wakes once. Drain the real reminder queue: the old
   pre-snooze job is discarded and the new job delivers exactly one SMTP email.
6. Import the two opposite-direction “OK” messages, retry the misc worker, and
   verify both records remain stable and appear through the actual messages API.

`control.exs` is a test-only CLI, invoked with `execFileSync` and separate argv
values (no shell interpolation). It uses real contexts and workers. CLI and web
server are separate BEAM nodes, so import completion is asserted from persisted
status and rendered contact data rather than relying on a cross-node PubSub
broadcast. CLI actions never start a web listener, cron, or background queues.

## Verification (2026-10-28)

- Full ExUnit suite: 1,763 tests, zero failures.
- `mix quality`: passed in the normal development environment.
- This regression spec: six passed, including draining the actual reminder queue.
- Existing contact, reminder, and import/export specs: sixteen passed.
- `mix test --cover`: 54.06% application-wide, below the unchanged 90% threshold;
  the command exits nonzero for coverage despite all tests passing. The new
  `Kith.Imports.ContactCleanup` module has 100% coverage.
