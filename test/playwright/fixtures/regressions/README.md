# Browser regression harness

Runs maintained browser regressions against real Phoenix UI, PostgreSQL,
importer/worker contexts, and SMTP delivery to Mailpit. The deterministic Monica
HTTP source returns ten notes and opposite-direction messages with the same
content and timestamp. The runner also includes image-fallback and editor
security specs.

Use a local development checkout only. The harness requires `KITH_E2E=1`,
disables automatic Oban execution, and explicitly controls dispatch/delivery.
Each test creates its own account through `Accounts.register_user`; login,
duplicate rejection, import submission, deletion, snoozing, and archival use the
actual UI. Reminder state and imported message contents are checked through the
authenticated REST API.

Reminder scenarios capture a single `dispatch_at` timestamp when prepared and
carry it through each CLI call. Dispatch and forced snooze expiry use that same
clock, including runs after 23:00 UTC or across midnight. Keep real wall-clock
time out of forced expiry operations.

## Prerequisites

- Elixir/OTP from `.tool-versions`, `mix deps.get`, and root `npm ci`.
- Node.js 22 or newer.
- PostgreSQL at `DB_PORT` (default development compose port 5434).
- Mailpit SMTP at `127.0.0.1:1025` and HTTP at `127.0.0.1:8025`.
- Playwright Chromium: `npx playwright install chromium`.

## Automated local and CI run

Prepare assets and run from the repository root:

```sh
MIX_ENV=test mix assets.setup
MIX_ENV=test mix assets.vendor
MIX_ENV=test mix assets.build
npm run test:regressions
```

The runner starts Phoenix, Monica, and fake S3, seeds an isolated database, and
requires all fixture-dependent specs to run. PostgreSQL and Mailpit must already
be running. To focus a scenario while retaining the same setup:

```sh
npm run test:regressions -- --grep 'permanent deletion'
```

Override `DB_PORT`, `MIX_TEST_PARTITION`, `PORT`, `KITH_TEST_MONICA_PORT`,
`KITH_TEST_S3_PORT`, `SMTP_HOST`, `SMTP_PORT`, or `MAILPIT_URL` when needed.
`PORT` defaults to 4000, Monica to 8094, and S3 to 9000. The runner sets
`PLAYWRIGHT_BASE_URL` and `KITH_TEST_MONICA_URL` from those local ports and
refuses occupied Phoenix/fixture ports. It verifies owned fixture processes with
`/__kith_fixture__` and a fresh `KITH_TEST_FIXTURE_TOKEN` before running tests.
The Monica API bearer value is the synthetic `kith-fixture-token`; no external
Monica account or production credentials are needed.

## Isolation and diagnostics

The default `MIX_TEST_PARTITION` starts with `browser_regressions_` and includes a
per-run suffix, producing a database named `kith_testbrowser_regressions_*`.
An explicitly supplied partition reuses its database. Use a separate browser
partition to keep its data out of ExUnit tests. Databases remain for debugging
and are never dropped by the runner.

One Playwright worker is required because control commands drain whole Oban
queues; parallel execution needs queue isolation first. The CLI sets
`KITH_TEST_SERVER=0`; `server.exs` sets it to `1` before loading `boot.exs`.
`KITH_E2E=1` remains required for either entry point.

Servers started by the runner stop on exit. Logs are under
`tmp/browser-regressions/`, and Playwright stores failure traces under
`test-results/`. Inspect `phoenix.log`, `monica.log`, `s3.log`, and the seed logs
for startup failures. Browser checks are separate from the existing ExUnit
coverage metric and do not change its 90% threshold.

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
7. Exercise paste/drop injection payloads in the shipped note editor, preserve
   inline formatting and paragraph boundaries, then save, query and reload the
   server-sanitized note.
8. Edit and reload a legacy multiline plain-text note without losing line breaks
   or turning escaped markup into executable HTML.

`control.exs` is a test-only CLI, invoked with `execFileSync` and separate argv
values (no shell interpolation). It uses real contexts and workers. CLI and web
server are separate BEAM nodes, so import completion is asserted from persisted
status and rendered contact data rather than relying on a cross-node PubSub
broadcast. CLI actions never start a web listener, cron, or background queues.

The suite also covers authenticator and recovery-code submission, native entry
animations, contact-search recovery after a LiveView reconnect, and mobile shell
visibility across content scroll boundaries and browser-toolbar size changes.
The mobile spec includes a deterministic model of Android's large-vs-visible
viewport height difference; see [mobile viewport regression](../../README.md#mobile-viewport-regression).
Focus it with `npm run test:regressions -- --grep 'mobile shell'`.

The mobile navigation suite also verifies Home/Contacts/Settings/More at narrow
widths, the Reminders/Journal menu and its keyboard behavior, named logout,
responsive timeline actions, wrapped Contacts tabs and mood filters, plus
desktop sidebar navigation and responsive resizing. Focus these checks with
`npm run test:regressions -- --grep 'Mobile navigation|desktop navigation'`.

Historical execution counts and point-in-time validation are preserved in the
[immutable harness history](https://github.com/kith-crm/kith/blob/be8259183cfe0b61e639b9fd2eb4b4604e7df969/test/playwright/fixtures/pr44/README.md).

The birthdate picker regression covers desktop and mobile calendar selection,
yearless February 29, form validation patches, restoring a known year, rejecting
non-leap-year February 29, clearing the date, and keyboard dismissal. Run it with
`npm run test:regressions -- --grep 'yearless birthday'`.
