# CardDAV

Kith exposes a single address book at `/dav/addressbooks/default/`.
Discovery starts at `/.well-known/carddav` or `/dav/`.
Use HTTP Basic authentication with a confirmed user's email and password.
Administrators and editors can write; viewers can read.

## Run the live checks

Prerequisites: PostgreSQL on the development-configured host/port, Elixir
and project dependencies, Node/npm, Python 3, curl and xmllint.
Install existing JavaScript dependencies with `npm ci`, then install Chromium
with `npx playwright install chromium`.

The harness uses port 4527, database `kith_carddav_task10_e2e`, and storage
inside `.carddav-task10/` in this checkout. It recreates only that dedicated
database and seeds test accounts plus 2,000 performance contacts.
Never point another application at that database.

```bash
set -e
trap 'scripts/carddav-e2e/down.sh' EXIT
scripts/carddav-e2e/up.sh
source .carddav-task10/env
npx playwright test --project=e2e test/playwright/carddav
scripts/carddav-e2e/vdirsyncer-smoke.sh
```

`down.sh` verifies the recorded process command and working directory before
stopping it. Server logs and browser artifacts are in `.carddav-task10/`.
The smoke script installs vdirsyncer in a temporary virtual environment,
compares actual local/server cards after synchronization, and cleans its cards.
Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE` before starting the harness to use an
existing compatible Chromium binary. The Playwright base URL and output
location come from the sourced environment file.

## Real-client results

See the [client checklist and recorded results](carddav-client-checklist.md)
for Thunderbird and DAVx5/Android Contacts, including the observed Thunderbird
conflict and invalid-sync-token recovery limitations. These checks use actual
application UI; the vdirsyncer smoke remains a separate scripted client run.

Yearless birthdays use `BDAY:--MMDD` in both versions. This is standard in
vCard 4.0 and an interoperability extension in 3.0, whose original date syntax
requires a year. It avoids synthetic years appearing in Thunderbird. Strict
legacy 3.0 consumers may reject it. Incoming Apple year-omission forms remain
accepted. The 3.0 output also retains `X-KITH-BDAY:--MMDD`.

## Data model and writes

`contact_dav` belongs to a contact and account. It stores an account-unique
UID, account-unique resource name, revision, and ungrouped unmapped properties
in `extras`. New local identities are UUIDs with matching `<uuid>.vcf` names;
client-supplied resource names and UIDs are retained. Discover hrefs through
PROPFIND; contact IDs do not determine DAV identity.

Trashed and archived contacts keep their identities reserved. PUT to their
href returns 409. Duplicate UIDs return `no-uid-conflict` with the holder href.

Every successful vCard-visible write must call `Kith.DAV.Store.touch/2`.
Application writes hold the account advisory transaction lock, mutate data,
and draw a sequence revision atomically. See
[`touch_coverage_test.exs`](../test/kith/dav/touch_coverage_test.exs) for coverage
of contact, child, relationship and vocabulary changes. Renaming a contact also
touches contacts whose relationship labels show that name.

ETags are quoted revisions, identical across vCard 3.0 and 4.0 representations.
The collection ctag and token revision are the maximum of stored revisions and
the account's `dav_sync_floors` revision. Hard deletion advances that floor,
invalidating older incremental state without retaining deleted contact rows.

## Sync tokens

Tokens have the form `https://kith.app/ns/sync/<revision>`.
An empty token requests an initial sync. Malformed tokens, tokens below the
floor, and future tokens receive 403 with `valid-sync-token`; clients must
restart with an initial sync. Soft deletion and archiving appear as removals;
restoration and unarchiving appear as additions at the same href.

## Known gaps

- CDV-30: chunked request parsing happens before DAV authentication.
- TOTP-enabled users can access DAV with their password; the blocking test is
  deliberately marked `test.fixme` until app passwords or equivalent exist.
- Unmapped ungrouped properties survive verbatim; grouped properties and
  parameters on mapped properties do not. Retained syntax is not converted
  between vCard 3.0 and 4.0, so some client fidelity is lost.
- Renames performed through raw SQL do not touch revisions. Use application
  functions for writes that clients must observe.
