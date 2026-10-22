# CardDAV End-to-End Regression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Kith's CardDAV server works end to end with no bugs. Probe every protocol area against an isolated live instance, fix every defect test-first (one commit per bug), and publish a results matrix, bug log and rulings in `docs/carddav-e2e.md`.

**Architecture:** A dedicated live dev server (own DB, port, storage) is exercised by Playwright specs under `test/playwright/carddav/`. These are HTTP-level DAV specs plus browser specs for UI↔DAV crossover. Each failing live assertion becomes a bug: it gets a failing ExUnit regression test in `test/kith_web/dav/`, then a minimal fix in `lib/kith/dav/` (or the context it exposes), then one commit. A real client (vdirsyncer) is the last smoke test.

**Tech Stack:** Elixir/Phoenix (Plug-based `Kith.DAV.CardDAVPlug`), Ecto/PostgreSQL, ExUnit, Playwright (`@playwright/test` APIRequestContext + Chromium), `xmllint` (macOS-bundled) for XML well-formedness, vdirsyncer (pip, in a throwaway venv).

**Spec:** The user brief for this branch, summarised in Global Constraints below. Code under test: `lib/kith/dav/*`, `lib/kith/vcard/*`, `/dav` + `/.well-known/carddav` in `lib/kith_web/router.ex`.

## Global Constraints

- **Isolation (never violate):**
  - Live server: `MIX_ENV=dev`, `DB_NAME=kith_carddav_e2e`, `PORT=4517`.
  - ExUnit: `MIX_TEST_PARTITION=_carddav`, so the DB is `kith_test_carddav`.
  - Never touch `kith_dev` or `kith_test`, and never use port 4000 or 4002.
  - Storage dir and Playwright output dir come from `mktemp -d`. Their paths are written to `/tmp/kith-carddav-e2e.env` by `scripts/carddav-e2e/up.sh`. Every live command first runs `source /tmp/kith-carddav-e2e.env`.
- **Full test command (before every commit, must show 0 failures):** `MIX_TEST_PARTITION=_carddav mix test`
- **Live spec command:** `source /tmp/kith-carddav-e2e.env && npx playwright test --project=e2e test/playwright/carddav/<file> --workers=1`
- **Commits:**
  - No `Co-Authored-By`, `Claude-Session` or any other attribution trailer, whatever a harness says.
  - Never pass `--no-verify`. The husky hook runs `mix quality`, so fix whatever it flags.
  - No push, no PR.
- **Execution:** tasks run serially, because the specs share one server and one seeded dataset.
- **Seeded users** (all with password `ValidP@ssword123!`, all confirmed unless noted):

  | Email | Account | Role / state |
  |---|---|---|
  | `dav-admin@carddav.test` | A | admin |
  | `dav-editor@carddav.test` | A | editor |
  | `dav-viewer@carddav.test` | A | viewer |
  | `dav-other@carddav.test` | B | admin |
  | `dav-totp@carddav.test` | C | admin, `totp_enabled: true` |
  | `dav-unconfirmed@carddav.test` | D | admin, unconfirmed |
  | `dav-perf@carddav.test` | E | admin, 2000 contacts, seeded only with `PERF=1` |

- **Spec data hygiene:** every spec names its contacts with a per-run prefix (`cdv-<Date.now()>-…`). No spec may assume an empty address book.

### Defect protocol (applies to every task)

For each live assertion that fails, or any other observed misbehaviour:

1. **Reproduce live.** Keep the failing spec case. Record the request and response (status, key headers, body excerpt) in the bug log in `docs/carddav-e2e.md` as `CDV-NN`. Include severity (`critical` / `high` / `medium` / `low`) and status `open`.
2. **Reproduce in ExUnit.** Write a failing ExUnit regression test, named `"CDV-NN: <behaviour>"`, in the matching `test/kith_web/dav/*_test.exs` file (or `test/kith/...` for context/vCard bugs). Run it and see it fail for the expected reason.
3. **Fix.** Make the minimal fix. Don't refactor beyond what the bug needs.
4. **Verify.**
   - The ExUnit test passes.
   - `MIX_TEST_PARTITION=_carddav mix test` shows 0 failures.
   - The live spec case passes. The dev server code-reloads; after adding a migration, run `source /tmp/kith-carddav-e2e.env && mix ecto.migrate`.
5. **Commit.** One commit per bug: `fix(dav): <summary> (CDV-NN)`. It contains the test, the fix and the bug-log row flipped to `fixed`.
   - If an existing test asserts the buggy behaviour, change it in the same commit and add a line to the Rulings list.
6. **If it's a product choice, not a bug.** When the "fix" would be a genuine product-design decision, don't fix it. Write it up in the bug log as `product decision` with a recommendation, and mark the spec case `test.fixme` with the CDV id.

The spec file and doc updates that aren't tied to one bug are committed at the end of each task as `test(e2e): carddav <area> specs`.

### Pre-made rulings (apply them; add new ones to the doc's "Rulings I made" list)

- **R1 — TOTP and Basic auth.** CardDAV Basic auth for TOTP-enabled users is a product decision. Recommend per-user app passwords; don't block 2FA users from DAV. Log it, don't fix it.
- **R2 — Client-chosen resource names.** A resource PUT to any `<name>.vcf` must afterwards be served at exactly that href, by GET, PROPFIND, multiget and sync. RFC 6352 §6.3.2 doesn't let the server relocate it. Store the client name per contact (nullable, unique per account). Look it up first, then fall back to the `kith-contact-N.vcf` pattern. Report hrefs using the stored name when present.
- **R3 — Sync tokens.**
  - An unparseable or unknown sync-token returns `403` with `<d:error><d:valid-sync-token/></d:error>` (RFC 6578 §3.2). This replaces the current full-sync fallback and its tests.
  - Sync must never *miss* a change. Re-reporting an unchanged member is acceptable.
  - A hard delete (trash purge / empty trash) that a token cannot express invalidates older tokens, using the same 403. Implementation choice is free, but it must cover every hard-delete path.
- **R4 — ETag.** The ETag changes on every successful write to the contact *or* its DAV-visible children: fields, addresses, tags, relationships, avatar, whether the write came from DAV or from the UI. Two writes in the same second must yield different ETags.
- **R5 — Archived contacts.** They are hidden from DAV everywhere (PROPFIND, GET, all REPORTs). This matches the existing `list_contacts` behaviour and its test. Archiving shows up as a deletion in incremental sync; unarchiving shows up as an addition.
- **R6 — Roles.** `viewer` is read-only over DAV: PUT, DELETE and PROPPATCH return `403`. `editor` and `admin` can write. Use `Kith.Policy.can?/3`.
- **R7 — Brute-force protection.** Failed Basic-auth attempts on `/dav` are rate-limited per IP+email: 10 failures per 5 minutes, then `429` with `Retry-After`. Successful requests are never throttled (sync clients are chatty).
- **R8 — Request size.** Any body over the advertised `max-resource-size` (1 048 576 bytes) returns `413` (a PUT may instead return `403` with `<card:max-resource-size/>`). It must never return a 500.
- **R9 — Anything else ambiguous.** Choose the RFC-compliant behaviour (RFC 4918, 6352, 6578, 6764, 7232, 2426, 6350). Record the choice in Rulings and mention it in the task report.

## Review Focus

1. **Real-client resource names.** Apple Contacts, DAVx5 and Thunderbird PUT to `<UUID>.vcf`. The contact must be GET-able at that same href and keep its UID. Pinned in Task 4, cases C3–C5.
2. **Non-`d:` XML prefixes.** Apple sends `A:`, and some clients use a default `xmlns="DAV:"`. Results must be identical to the `d:` form. Pinned in Task 2, case P6, and Task 5, case R2.
3. **Same-second edits.** Two edits inside one second, or an edit in the same second a sync token was issued, must change the ETag and be reported by the next sync. Pinned in Task 4, case K6, and Task 5, case S4.
4. **Child-only UI edits.** Adding a phone or tag in the UI must change the ETag and ctag and appear in incremental sync. Pinned in Task 7, case U3.
5. **Lossless round trip.** A client that GETs a vCard (or takes it from sync, which has no PHOTO) and PUTs it back unchanged must lose no Kith data: avatar, tags, relationships, notes, the fields of a vCard 4.0 body. Pinned in Task 6, case V5.

---

### Task 1: Isolated environment and live-test harness

**Files:**
- Modify: `config/dev.exs`. Set `database: System.get_env("DB_NAME", "kith_dev")`. Make the dev storage path honour `STORAGE_PATH` with the current value as default, wherever dev storage is configured (`config/dev.exs` or `config/config.exs`).
- Modify: `playwright.config.ts`. Set `baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4000"` and `outputDir: process.env.PLAYWRIGHT_OUTPUT_DIR ?? "test-results"`.
- Create: `scripts/carddav-e2e/up.sh`, `scripts/carddav-e2e/down.sh`.
- Create: `test/playwright/carddav_seed.exs` (seeded users from Global Constraints; idempotent; `PERF=1` adds account E).
- Create: `test/playwright/helpers/dav.ts`.
- Create: `test/playwright/carddav/00-harness.spec.ts`.
- Create: `docs/carddav-e2e.md` (skeleton: How to run, Results matrix, Bug log table, Rulings I made, Real-client smoke).

**Interfaces:**
- Produces, from `helpers/dav.ts`:
  - `USERS: Record<"admin"|"editor"|"viewer"|"other"|"totp"|"unconfirmed"|"perf", {email: string; password: string}>`
  - `dav(request: APIRequestContext, method: string, path: string, opts?: {user?: keyof typeof USERS | null; body?: string; headers?: Record<string,string>}): Promise<{status: number; headers: Record<string,string>; body: string}>`. `user: null` sends no auth; the default is `"admin"`.
  - `hrefs(xml: string): string[]`
  - `responseFor(xml: string, href: string): string | undefined` (the `<response>` block)
  - `propText(block: string, localName: string): string | undefined` (prefix-agnostic)
  - `assertWellFormedXml(xml: string): void` (pipes to `xmllint --noout -` and throws on non-zero exit)
  - `vcard(fields: {fn: string; email?: string; tel?: string; uid?: string; version?: "3.0"|"4.0"; extra?: string[]}): string` (CRLF line endings)
  - `runPrefix(): string`
- Produces, from `up.sh`: `/tmp/kith-carddav-e2e.env`, which exports `MIX_ENV=dev DB_NAME=kith_carddav_e2e PORT=4517 STORAGE_PATH=<mktemp> PLAYWRIGHT_OUTPUT_DIR=<mktemp> PLAYWRIGHT_BASE_URL=http://127.0.0.1:4517 DAV_SERVER_PID_FILE=/tmp/kith-carddav-e2e.pid`.

- [ ] **Step 1: Install deps (fresh worktree).** Run `mix deps.get && MIX_ENV=dev mix compile && MIX_ENV=test mix compile && npm ci && npx playwright install chromium`. Expected: exit 0.
- [ ] **Step 2: Baseline the test partition.** Run `MIX_TEST_PARTITION=_carddav MIX_ENV=test mix ecto.create && MIX_TEST_PARTITION=_carddav mix test`. Expected: 0 failures. If there are failures, record them as pre-existing in the doc and report them to the controller before continuing.
- [ ] **Step 3: Apply the config overrides** (dev.exs, storage, playwright.config.ts) as described under Files. Defaults stay byte-identical.
- [ ] **Step 4: Write `up.sh`.** It must:
  - refuse to run if `DB_NAME` resolves to `kith_dev` or `kith_test*`;
  - abort if `lsof -iTCP:4517 -sTCP:LISTEN` shows a listener that isn't ours;
  - create the two mktemp dirs and write the env file;
  - run `mix ecto.create`, `mix ecto.migrate`, `mix run test/playwright/carddav_seed.exs`;
  - start `mix phx.server` with `nohup`, logging to `/tmp/kith-carddav-server.log` and writing the pid file;
  - poll `http://127.0.0.1:4517/health` for up to 120 s.

  `down.sh` kills the pid from the pid file.
- [ ] **Step 5: Write the seed** (seeded users from Global Constraints). Use the existing `Kith.Accounts` APIs where they exist (registration, then role/account changes), with direct `Repo` changes for `confirmed_at`, `role`, `account_id` and `totp_enabled`/`totp_secret`. Running it twice must not error.
- [ ] **Step 6: Write `helpers/dav.ts`** per Interfaces, and `00-harness.spec.ts`. Cases:
  - H1: GET `/health` returns 200.
  - H2: an authed PROPFIND on `/dav/` returns 207 and `assertWellFormedXml` passes.
  - H3: the same request without auth returns 401.
- [ ] **Step 7: Run it.** `scripts/carddav-e2e/up.sh && source /tmp/kith-carddav-e2e.env && npx playwright test --project=e2e test/playwright/carddav/00-harness.spec.ts --workers=1`. Expected: 3 passed.
- [ ] **Step 8: Run the full partition** `MIX_TEST_PARTITION=_carddav mix test`. Expected: 0 failures. Commit with `chore(e2e): isolated CardDAV live-test harness (DB_NAME/STORAGE_PATH overrides, seed, helpers)`.

### Task 2: Discovery, OPTIONS and PROPFIND chain

**Files:**
- Create: `test/playwright/carddav/01-discovery.spec.ts`
- Bug fixes in: `lib/kith/dav/{carddav_plug,xml_parser,xml_builder,well_known_carddav_plug}.ex`
- Tests in: `test/kith_web/dav/{well_known,propfind}_test.exs`, `test/kith/dav/xml_parser_test.exs` (create if needed)

**Interfaces:** Consumes the Task 1 helpers. Produces nothing new.

- [ ] **Step 1: Write the live cases.** Every 207 response must also pass `assertWellFormedXml` and carry `Content-Type: application/xml; charset=utf-8`.

  | # | Request | Expected |
  |---|---|---|
  | W1 | `GET` and `PROPFIND /.well-known/carddav` (unauthed) | 301 or 308, `Location` ends with `/dav/` or `/dav/principals/` |
  | W2 | `/.well-known/carddav/` with trailing slash | same as W1 |
  | O1 | `OPTIONS` on `/dav/`, `/dav/addressbooks/default/`, and a contact href | 200 (or 401 when unauthed); `DAV` header contains `addressbook`; `Allow` lists every implemented method including PROPPATCH |
  | P1 | `PROPFIND /dav/` Depth 0, `<d:prop><d:current-user-principal/></d:prop>` | href `/dav/principals/` |
  | P2 | `PROPFIND /dav/principals/` asking `addressbook-home-set` and `principal-URL` | `/dav/addressbooks/` and `/dav/principals/` |
  | P3 | `PROPFIND /dav/addressbooks/` Depth 0 | exactly 1 response. Depth 1: 2 responses, the child has `resourcetype` ⊇ `addressbook` |
  | P4 | `PROPFIND /dav/addressbooks/default/` Depth 0, asking `getctag`, `sync-token`, `supported-report-set`, `displayname`, `resourcetype` | every requested prop is in a 200 propstat; `sync-token` is a URI |
  | P5 | Same collection, Depth 1 | one response per active contact, plus a 404 propstat listing exactly the unknown props when you ask for `<x:bogus xmlns:x="urn:x"/>`; Depth `infinity` returns 403 with `propfind-finite-depth` |
  | P6 | P1–P4 repeated with an `A:` prefix and with default `xmlns="DAV:"` / `xmlns="urn:ietf:params:xml:ns:carddav"` | results identical to the `d:` form; `allprop` / `propname` recognised whatever the prefix |
  | P7 | Malformed XML body, and a non-UTF-8 body | 400, never 500 |
  | P8 | `PROPFIND` on a contact href, Depth 0 | 207, href equals the request path, `getetag` equals the ETag returned by GET |
  | P9 | `PROPFIND` on a non-existent contact or an unknown collection | 404 |
  | P10 | `PROPPATCH` on the collection with `displayname` | 207 multistatus with 403 propstat |

- [ ] **Step 2: Run it** against the live server and list the failures. Expected: some failures (P4 `sync-token`, P6 prefixes and P7 are suspected).
- [ ] **Step 3: Apply the Defect protocol to each failure** (one commit per bug).
- [ ] **Step 4: Re-run.** All cases pass (or `fixme` with a CDV id), and `MIX_TEST_PARTITION=_carddav mix test` shows 0 failures. Commit the spec and doc.

### Task 3: Authentication, rate limiting, roles and multitenancy

**Files:**
- Create: `test/playwright/carddav/02-auth.spec.ts`
- Bug fixes in: `lib/kith/dav/{auth,carddav_plug}.ex`, possibly `lib/kith_web/plugs/rate_limiter.ex` (reuse it, don't fork it)
- Tests in: `test/kith_web/dav/{auth,access_control}_test.exs`

- [ ] **Step 1: Write the live cases.**

  | # | Case | Expected |
  |---|---|---|
  | A1 | no auth, wrong password, unknown email, malformed base64, `Bearer` scheme, password containing `:` | 401 with `WWW-Authenticate: Basic realm=…`; no body leak |
  | A2 | unconfirmed user | 401 |
  | A3 | email in different case (`DAV-Admin@…`) | same result as the web login for that case |
  | A4 | TOTP user, password only | log the actual behaviour as R1 product decision; mark the case `fixme` |
  | A5 | 11 wrong passwords for a throwaway email | 11th returns 429 with `Retry-After`; correct credentials for **another** email from the same IP still return 207 (R7) |
  | M1 | `other` doing GET, PUT, DELETE, PROPFIND and multiget on account-A contact hrefs | 404 / 404-propstat, and A's data unchanged |
  | M2 | `other` doing sync-collection or addressbook-query | never returns A's contacts |
  | M3 | `other` PUT to A's `kith-contact-N.vcf` href | must not overwrite A's contact; whatever is created lives only in B |
  | RL1 | `viewer`: PROPFIND, GET, REPORT | allowed |
  | RL2 | `viewer`: PUT (new and existing), DELETE, PROPPATCH | 403, data unchanged (R6) |
  | RL3 | `editor`: PUT and DELETE | allowed |

- [ ] **Step 2: Run, then apply the Defect protocol to each failure.** Suspected: RL2, A5, possibly A3.
- [ ] **Step 3: Re-run green, run the full partition, commit the spec and doc.**

### Task 4: Address-object CRUD and conditional requests

**Files:**
- Create: `test/playwright/carddav/03-crud.spec.ts`
- Bug fixes in: `lib/kith/dav/carddav_plug.ex`, `lib/kith/contacts.ex`, `lib/kith/contacts/contact.ex`, plus a migration under `priv/repo/migrations/` if R2 or R4 needs one
- Tests in: `test/kith_web/dav/address_object_test.exs`

**Interfaces:**
- Produces, if R2 needs a column: a field on `Kith.Contacts.Contact` named `dav_resource_name :: String.t() | nil`, with a unique index on `(account_id, dav_resource_name)`. Also produces `Kith.Contacts.get_contact_by_dav_name(account_id :: integer, name :: String.t()) :: Contact.t() | nil`. Tasks 5–9 rely on hrefs being stable per R2.

- [ ] **Step 1: Write the live cases.**

  | # | Case | Expected |
  |---|---|---|
  | C1 | PUT a new `kith-contact-<new>.vcf` with `If-None-Match: *` | 201 + strong `ETag`. GET at the same URL returns 200 with the same ETag, `Content-Type: text/vcard; charset=utf-8` |
  | C2 | GET → PUT an edit with `If-Match: <etag>` | 204 (or 200/201) + new ETag; GET reflects the edit |
  | C3 | PUT a new `<uuid>.vcf` (`UID:<uuid>`) | 201. GET `<uuid>.vcf` returns 200 and keeps `UID:<uuid>`; PROPFIND Depth 1 lists `<uuid>.vcf` (R2) |
  | C4 | PUT the same `<uuid>.vcf` again with an edit | updates the same contact: the count is unchanged, no duplicate |
  | C5 | DELETE `<uuid>.vcf` | 204; GET returns 404 |
  | K1 | PUT on an existing href with `If-None-Match: *` | 412 |
  | K2 | PUT or DELETE with a stale `If-Match` | 412, data unchanged |
  | K3 | PUT with `If-Match` on a non-existent href | 412, nothing created |
  | K4 | GET with `If-None-Match: <current etag>` | 304, no body |
  | K5 | `If-Match` lists (`"a", "<etag>"`) and `W/` weak tags on PUT | match per RFC 7232 strong comparison |
  | K6 | two PUTs to the same contact inside one second | three distinct ETags (create, edit 1, edit 2) (R4) |
  | E1 | PUT `Content-Type: text/x-vcard` | accepted. `application/json` returns 415 |
  | E2 | PUT an invalid vCard (no BEGIN, no FN/N) | 4xx (`valid-address-data` precondition), never 500 |
  | E3 | PUT with a 2 MB body | 413 or 403 `max-resource-size` (R8), never 500 |
  | E4 | DELETE an already-trashed contact href | 404. GET on a trashed contact returns 404 |
  | E5 | PUT to a trashed contact's href | doesn't silently resurrect a duplicate. Record the behaviour and choose per R9 |
  | E6 | href with `%20` / non-ASCII / `..` / extra path segment | 404 or correct handling; never 500; hrefs in responses are percent-encoded |
  | E7 | DELETE on the collection or on `/dav/addressbooks/` | 403 or 405, never 204 / data loss |

- [ ] **Step 2: Run, then apply the Defect protocol to each failure.** Suspected: C3–C5, K3, K4, K6, E3.
- [ ] **Step 3: Re-run green, run the full partition, commit the spec and doc.**

### Task 5: REPORTs (multiget, query, sync-collection)

**Files:**
- Create: `test/playwright/carddav/04-reports.spec.ts`
- Bug fixes in: `lib/kith/dav/{carddav_plug,xml_parser,xml_builder}.ex`, `lib/kith/contacts.ex` (`list_contacts_modified_since/2`, `list_contacts_deleted_since/2`, hard-delete paths)
- Tests in: `test/kith_web/dav/report_test.exs`

- [ ] **Step 1: Write the live cases.**

  | # | Case | Expected |
  |---|---|---|
  | R1 | REPORT dispatch uses the **root element**: a query whose text-match is `sync-collection` or `addressbook-multiget` is still a query; an unknown root returns 403 `supported-report` or 501; malformed XML returns 400 | as stated |
  | R2 | multiget with `D:` / `A:` / default-namespace hrefs, absolute-URL hrefs, percent-encoded hrefs | identical results |
  | R3 | multiget for a missing href | a response with `<d:status>HTTP/1.1 404 Not Found</d:status>` for that href; the others are 200 with `address-data` and `getetag` matching GET |
  | R4 | multiget mixing `kith-contact-N.vcf` and `<uuid>.vcf` hrefs | both resolve (R2) |
  | Q1 | addressbook-query on FN / EMAIL / TEL with each `match-type`, `negate-condition`, `test="anyof"` vs `allof`, `<card:limit>` | correct sets; any prefix works; an unsupported filter returns 403 `supported-filter`, not silently "match all" |
  | Q2 | query requesting only `<d:getetag/>` | no `address-data` in the response |
  | S1 | initial sync (empty token) | every active contact, plus a URI `sync-token` |
  | S2 | create, edit and DELETE (DAV) after a token | incremental sync shows exactly those (deleted as `<d:status>` 404 response, no propstat) |
  | S3 | trash via context, restore, archive, unarchive after a token | correct remove/add per R5 |
  | S4 | edit in the same second the token was issued | reported by the next sync (R3) |
  | S5 | hard delete (empty trash) after a token | the next sync with the old token returns 403 `valid-sync-token`, or reports the 404 (R3) |
  | S6 | garbage token, or a token from another server | 403 `valid-sync-token` (R3, update the existing tests) |
  | S7 | `sync-token` from PROPFIND (P4) works as a sync-collection token, and ctag changes after every S2/S3 mutation, including a delete of a non-newest contact | as stated |
  | S8 | sync-level `infinite` | 403 or handled; `<d:limit>` handled or `507` per RFC 6578 |

- [ ] **Step 2: Run, then apply the Defect protocol to each failure.** Suspected: R1 (substring dispatch), R2, R3 status shape, S4, S5, S6, S7 ctag on delete.
- [ ] **Step 3: Re-run green, run the full partition, commit the spec and doc.**

### Task 6: vCard 3.0 / 4.0 round-trip fidelity

**Files:**
- Create: `test/playwright/fixtures/carddav/{v30-full,v40-full,apple-ios,davx5-android,thunderbird,unicode-folding}.vcf`
- Create: `test/playwright/carddav/05-vcard.spec.ts`
- Bug fixes in: `lib/kith/vcard/{parser,serializer}.ex`, `lib/kith/dav/vcard_adapter.ex`, `lib/kith/contacts.ex` (`replace_contact_children/3`)
- Tests in: `test/kith/vcard/*_test.exs`, `test/kith/contacts_dav_test.exs`

- [ ] **Step 1: Write the fixtures.**
  - The full fixtures carry FN, N (all 5 parts), NICKNAME, ORG, TITLE, NOTE (with `\n`, `,`, `;`, `\\`), BDAY (full date and `--MMDD` without a year), several EMAIL/TEL/ADR/URL with TYPEs and PREF, IMPP, CATEGORIES, RELATED (4.0), GENDER (4.0), PHOTO (3.0 `ENCODING=b` and 4.0 `data:` URI, ~2 KB PNG), and an `X-` property.
  - The client-style fixtures copy each client's typical shape: `item1.EMAIL` + `item1.X-ABLabel`, `X-ABUID`, `PRODID`.
  - `unicode-folding` has CJK, emoji and RTL names, with lines folded at 75 octets mid-UTF-8 sequence.
- [ ] **Step 2: Write the live cases.**

  | # | Case | Expected |
  |---|---|---|
  | V1 | PUT each fixture, GET as 3.0 and as 4.0 (`Accept: text/vcard; version=4.0`) | every supported property survives semantically (a values table per fixture in the spec); output passes as valid vCard (CRLF, folded ≤75 octets, `VERSION` first after BEGIN, exactly one FN, correct escaping); the 4.0 output contains no 3.0-only syntax and vice versa |
  | V2 | GET → PUT the identical body → GET | byte-identical apart from REV, and the ETag may change; no duplicated EMAIL/TEL/ADR, no growing tag list |
  | V3 | unicode names | appear correctly in GET, multiget and the web UI contact page (browser check) |
  | V4 | PHOTO | stored as the avatar; GET returns it; the multiget/sync policy is consistent with GET |
  | V5 | PUT back the vCard taken from **sync-collection** (no PHOTO) and from a 4.0 GET | avatar, tags, relationships, notes, reminders and Kith-only fields untouched |
  | V6 | unsupported properties | record each one the fixtures carry that Kith drops; each is a `low` CDV unless it's data the UI shows, in which case it's `medium` |

- [ ] **Step 3: Run, then apply the Defect protocol to each failure.**
- [ ] **Step 4: Re-run green, run the full partition, commit the fixtures, spec and doc.**

### Task 7: UI ↔ DAV crossover in a real browser

**Files:**
- Create: `test/playwright/carddav/06-ui-crossover.spec.ts` (Chromium; log in with `helpers/auth.ts` `loginUser` as `dav-admin@carddav.test`; reuse the selectors in `helpers/contacts.ts`)
- Bug fixes wherever the cause lies (often `lib/kith/contacts.ex` write paths not bumping `updated_at`)
- Tests in: `test/kith/contacts_dav_test.exs`, `test/kith_web/dav/*`

- [ ] **Step 1: Write the live cases.** Each starts from a fresh sync token and ETag.

  | # | Case | Expected |
  |---|---|---|
  | U1 | create a contact in the UI | it appears in PROPFIND Depth 1, incremental sync and GET, with the UI's values |
  | U2 | edit the name, then birthday, in the UI | ETag changes, ctag changes, sync reports it, GET shows the new values |
  | U3 | add a phone, an email, an address and a tag in the UI; then delete one | each step changes the ETag and sync, and GET matches the UI |
  | U4 | PUT an edit over DAV, then reload the UI | the UI shows it, with no stale cache |
  | U5 | trash the contact in the UI | DAV GET returns 404, it's absent from Depth 1, sync reports a 404. Restore from Trash in the UI: present again with the same href |
  | U6 | merge A into B in the UI | A's href is gone (sync 404); B's vCard contains the merged fields; B's href is unchanged |
  | U7 | archive and unarchive in the UI | follows R5 |
  | U8 | DELETE over DAV | the contact shows in the UI Trash and can be restored |
  | U9 | a contact created over DAV with a `<uuid>.vcf` name, then edited in the UI | GET at `<uuid>.vcf` returns the UI edit (R2) |

- [ ] **Step 2: Run** with `--workers=1`, then apply the Defect protocol to each failure.
- [ ] **Step 3: Re-run green, run the full partition, commit the spec and doc.**

### Task 8: Performance cliffs

**Files:**
- Create: `test/playwright/carddav/07-perf.spec.ts` (account E; requires a seed with `PERF=1`)
- Create: `test/kith_web/dav/query_count_test.exs`
- Bug fixes in: `lib/kith/dav/carddav_plug.ex`, `lib/kith/contacts.ex`

- [ ] **Step 1: Seed account E.** Run `source /tmp/kith-carddav-e2e.env && PERF=1 mix run test/playwright/carddav_seed.exs`. That's 2000 contacts, each with 2 fields, 1 address and 1 tag.
- [ ] **Step 2: Write the live budgets** (median of 3 runs, after one warm-up request). Each budget miss is a `medium` CDV unless it exceeds the budget 5×, which makes it `high`.

  | Request | Budget |
  |---|---|
  | PROPFIND Depth 1 | < 1.5 s |
  | initial sync-collection | < 6 s |
  | multiget of 200 hrefs | < 2 s |
  | addressbook-query matching 1 contact | < 1.5 s |
  | single GET | < 200 ms |

- [ ] **Step 3: Write the ExUnit query-count test.** Attach a `[:kith, :repo, :query]` telemetry handler and count queries. Assert that the counts for multiget and for sync-collection with 5 contacts equal the counts with 50 contacts, so there's no N+1. Call it `"CDV-NN: multiget query count is independent of href count"` once a CDV exists, otherwise `"multiget query count is independent of href count"`.
- [ ] **Step 4: Run, then apply the Defect protocol to each failure.**
- [ ] **Step 5: Re-run green, run the full partition, commit.**

### Task 9: Real-client smoke (vdirsyncer)

**Files:**
- Create: `scripts/carddav-e2e/vdirsyncer-smoke.sh`. The venv and the sync dirs live in `mktemp -d`, never in the repo. Run pip with `python3 -I -m pip`.
- Modify: `docs/carddav-e2e.md`, Real-client smoke section

- [ ] **Step 1: Install vdirsyncer.** Run `python3 -m venv "$D/venv" && "$D/venv/bin/python" -I -m pip install vdirsyncer`. If it fails, write "vdirsyncer: **not run** — <exact reason>" in the doc, commit, and stop this task.
- [ ] **Step 2: Write the script.**
  - Configure a pair between a `carddav` storage (`url = "http://127.0.0.1:4517/dav/"`, user `dav-admin@carddav.test`) and a `filesystem` storage (`fileext = ".vcf"`).
  - Run `discover`, then `sync`.
  - Then: edit a local .vcf, add a local .vcf with a UUID filename, delete a local .vcf, and `sync`.
  - Then: change a contact over DAV (curl PUT), and `sync`.
  - Then: a conflicting edit on both sides, and `sync` with `conflict_resolution = "a wins"`.
  - Assert after each step: the server state (via curl PROPFIND/GET) and the local dir agree. Exit with a non-zero status on any mismatch.
- [ ] **Step 3: Run it, then apply the Defect protocol to each failure.** Record the script output summary (pass/fail per step) in the doc.
- [ ] **Step 4: Run the full partition, commit.**

### Task 10: Results doc and final verification

**Files:**
- Modify: `docs/carddav-e2e.md`

- [ ] **Step 1: Re-run everything from a clean slate.** `scripts/carddav-e2e/down.sh`, drop and recreate `kith_carddav_e2e` (`mix ecto.drop` with the env sourced; it refuses unless `DB_NAME=kith_carddav_e2e`), `up.sh`, the `PERF=1` seed, then `npx playwright test --project=e2e test/playwright/carddav --workers=1`. Expected: everything passes except `fixme` cases with CDV ids.
- [ ] **Step 2: Run the full partition.** `MIX_TEST_PARTITION=_carddav mix test`. Expected: 0 failures.
- [ ] **Step 3: Finalise `docs/carddav-e2e.md`.**
  - **Results matrix:** rows are every case id from Tasks 1–9; columns are area, case, result (`pass` / `fixed CDV-NN` / `open CDV-NN` / `product decision CDV-NN` / `not run`).
  - **Bug log:** columns are id, severity, title, repro, root cause, fix commit SHA, and status (`fixed` / `open` / `product decision`).
  - **Rulings I made:** R1–R9 plus every ruling added during execution.
  - **Real-client smoke:** the result.
  - **How to run:** the commands.
- [ ] **Step 4: Commit** `docs(carddav): e2e results matrix, bug log and rulings`, then run `scripts/carddav-e2e/down.sh`.
