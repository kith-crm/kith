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
for the full scenario definitions. Pixel 7 / Android 14 with DAVx5 4.5.21
and Contacts 4.8.17 passed S1–S12. Thunderbird 158 failed S9 (unconditional
PUT overwrites without If-Match) and S10 (no automatic recovery from 403
invalid token; removing and re-adding the address book was verified). S2/S5
category display was partial. These checks use actual
application UI; the vdirsyncer smoke remains a separate scripted client run.

Yearless birthdays use `BDAY:--MMDD` in both versions. This is standard in
vCard 4.0 and an interoperability extension in 3.0, whose original date syntax
requires a year. It avoids synthetic years appearing in Thunderbird. Strict
legacy 3.0 consumers may reject it. Incoming Apple year-omission forms remain
accepted. Generated cards contain only the standard `BDAY` property. Legacy
`X-KITH-BDAY` remains an import fallback; DAV updates use `BDAY`, including its
absence when a client clears the birthday, rather than a stale extension.

## Data model and writes

`contact_dav` belongs to a contact and account. It stores an account-unique
UUID, account-unique resource name, revision, and ungrouped unmapped properties
in `extras`. New local identities are UUIDs with matching `<uuid>.vcf` names.
DAV PUT accepts a hyphenated UUID or `urn:uuid:<uuid>`, including uppercase
forms, and stores the canonical lowercase bare UUID. Other supplied UID formats
are rejected with `valid-address-data`. This UUID-only restriction deliberately
does not support every UID permitted by the vCard standard. A missing UID keeps
the existing identity on update, or generates one on creation.

Generated `UID` values and identity-bearing relationship references use
`urn:uuid:<uuid>`. Equivalent bare/prefixed or case variants claim the same
identity, and an update cannot change that identity. Client-supplied resource
names stay independent of UUIDs and are preserved. Discover hrefs through
PROPFIND; contact IDs do not determine DAV identity. Database relationships
continue to use contact IDs as foreign keys.

Trashed and archived contacts keep their identities reserved. PUT to their
href returns 409. Duplicate UIDs return `no-uid-conflict` with the holder href.

Family-only contacts are accepted; at least one first or last name is required.
A missing first name is stored as an empty string.

### UUID migration

The UUID migration audits stored identities before converting the UID column
to PostgreSQL `uuid`. It stops for non-UUID values or account-scoped collisions
between equivalent bare, prefixed, or differently cased UUIDs. It does not
replace identities or rename resources. Resolve incompatible legacy data before
retrying the migration; do not silently generate replacement IDs for contacts
already synchronized to clients.

### Contact avatars

The selected avatar is served in the standard `PHOTO` property in both vCard
versions. Timeline photos are not included unless selected as the avatar.
Web uploads and selection of an existing photo provide a square crop preview.
The server applies the crop after correcting orientation, limits the output to
512 × 512 pixels without upscaling, and produces a static JPEG of at most
512 KiB. Imports without an interactive crop use a centered square. The source
photo is retained unchanged; the processed rendition has its own storage key
and crop/cache metadata on the source photo row. An account-scoped
`avatar_assets` registry records each rendition's size and digest independently
of the source row. Merges can deduplicate source photos while preserving an
avatar still referenced by a trashed contact, without losing storage accounting
or making the backfill fail.

Avatar processing happens when the avatar is assigned, not during DAV reads.
Failed processing preserves the previous avatar. Replacing or clearing the
avatar participates in DAV revision tracking. GET, multiget, sync and query
responses use the selected rendition, and PHOTO filters inspect the same
representation that the response serves.

Contact creation/update APIs reject assigning a raw avatar storage key, which
would bypass image validation. Use the web avatar picker or an embedded DAV
PHOTO to assign an avatar. Remote PHOTO URI fetching is not implemented;
unsupported PHOTO formats are rejected rather than silently accepted.

After applying the schema migrations, convert existing avatars with:

```bash
mix kith.avatars.backfill
# To limit the conversion to one account:
mix kith.avatars.backfill --account-id 123
```

The backfill is resumable and skips avatars already converted. It preserves
unreadable sources and reports failures instead of silently marking them as
processed. Resolve reported failures before considering avatar conversion
complete.

Every successful vCard-visible write must call `Kith.DAV.Store.touch/2`.
`Store.ensure_rows/1` runs before DAV reads.
`Store.transaction(account_id, fun)` acquires the account advisory lock before
contact row locks for merges, DAV writes and hard deletes; these operations keep
data changes and revisions in the same transaction. Ordinary application writes
may touch after the mutation commits. Only an enclosing transaction makes the
mutation and touch atomic; a post-commit touch can report the change one sync
later. Always touch after a successful mutation. See
[`touch_coverage_test.exs`](../test/kith/dav/touch_coverage_test.exs) for coverage
of contact, child, relationship and vocabulary changes. Renaming a contact also
touches contacts whose relationship labels show that name; merges touch incoming
relationship owners.

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

Native relationships in vCard 3.0 include an ungrouped
`X-KITH-RELATED;TYPE=...` identity alongside the grouped Apple display
name/label. Keeping that extension on PUT preserves the native relationship;
removing it removes visible relationships. Hidden targets remain protected.
vCard 4.0 uses `RELATED`. Grouped display properties alone do not identify
relationship targets.
