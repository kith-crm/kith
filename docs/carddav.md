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
UUID, resource name, publication revision/time/fingerprint, and an ordered rich
client document in PostgreSQL JSONB. Native tables own shared values; the document
owns client-only values, parameters, groups, repetitions and internal bindings.
Legacy `extras` are quarantined for explicit operator review and never rendered
by DAV. A lossless compact JSON storage codec keeps one authoritative document;
older rich JSON maps remain readable. `dav_document_references` is a derived,
account-scoped UUID dependency index, updated in the same transaction. It makes
visibility changes affect referring cards without creating native relationships
from unresolved client references. A merge keeps the survivor's client document
and stores each loser's pre-merge document in private `archived_document`;
that archive is never rendered, reconciled, or included in DAV validators.
New local identities are UUIDs with matching `<uuid>.vcf` names.
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

## Shared and private data

DAV shares names/nickname, trusted built-in email/phone/website fields, postal
address text, birthday, company/job title, selected processed avatar, tags and
visible forward/reverse relationships. System keys assigned by an audited
migration classify built-ins. Account-created types remain private even if their
name, protocol or vCard label mimics Email. Specialized native social-service
fields are private; incoming URL binds to generic Website.

Gender, description, custom fields, timeline notes/activities, original photos,
reminders, first-met data, aliases and integration metadata stay private to Kith.
Authorized Kith imports, screens, APIs and exports retain their access. In
particular, client NOTE and GENDER live only in the DAV document. They never map
to private Kith description/gender; explicit Kith vCard import retains its own
NOTE-to-description behavior. DAV birthday edits leave private reminder rows and
configuration unchanged; native Kith edits retain their intended reminder
reconciliation.

PUT replaces shared values and client document content while preserving private
native records. Omitted PHOTO clears selection, not source photos; omitted tags
remove memberships, not tag definitions. Unchanged rows keep IDs and subtype
metadata. Unknown relationship URI/text stays client-only; names never identify
native targets. Hidden targets and their native edges stay protected.

## Atomic publication and validators

`Kith.Contacts.Write` owns account-serialized writes. Native context facades and
DAV call the same service; nested operations queue affected contacts and publish
once at the outer transaction boundary. `Store.touch/2` marks candidates and
compares the actual shared/client representation, so no-op and private edits do
not change DAV content, revisions, ETags or timestamps. Raw maintenance writers
must enter this service rather than update first and touch afterward.

`Store.ensure_rows/1` supplies missing identities and initializes sanitized
pending documents before DAV reads. Normal reads use one repeatable-read DB
snapshot and batch relationship data; existing transaction/sandbox callers use a
bounded shared account lock instead of changing their isolation. Writes take the
account lock before contact locks. Selected avatars require a registered,
validated processed rendition; missing or legacy-original assets produce 503,
never a silently different body under the same validator.

REV and modification dates use `representation_modified_at`, independent of
`contacts.updated_at`. Strong GET tags have the form `"<revision>-v30"` or
`"<revision>-v40"`; canonical DAV:getetag uses v30, including reports containing
converted v4 address-data. Conditional writes accept a current variant tag.
Transformed PUT responses omit ETag, so clients should refetch. Collection ctag
and sync token remain the maximum of revisions and the account sync floor.

## Existing-install cutover

Use a maintenance window: disable DAV access and stop every old web instance,
worker, and administrative writer before migrating. Run migrations, the audit,
document initialization, and avatar backfill with the new build; then start only
new-build web instances and workers before enabling DAV again. Keeping DAV off
alone is insufficient: old native writers bypass document bindings and atomic
publication. Do not run mixed old/new writers. A rollback must disable DAV and
retain the new schema and documents unless the rollback build preserves this
privacy boundary.

Run migrations and the avatar backfill before enabling DAV access. The boundary
migration audits exact historical built-in definitions, stops for ambiguous or
altered global seeds, preserves all native IDs/UIDs/hrefs, initializes DAV time,
and advances existing revisions. Existing resources require a current explicit
If-Match for PUT and DELETE: old validators, wildcard-only and unconditional replacement
are rejected with 412. This prevents old unconditional clients echoing previously
exported private data into a new client-only document. New resources created
under this policy retain unconditional-write compatibility. Never clear the
migration gate merely because a client fetched a card or time has elapsed.

Audit and synchronous document initialization are available without deleting or
reclassifying candidate data:

```bash
mix kith.dav.audit --account-id 123
mix kith.dav.audit --account-id 123 --backfill
```

The report contains identifiers rather than private field values. Duplicate
candidates are not automatically deleted; identical values may be intentional.
Legacy extras cannot be assumed client-origin and remain quarantined. Lost
mapped parameters from older versions cannot be reconstructed by migration.
Keep DB/storage backups; rollback must disable DAV or retain this policy, rather
than reactivate a serializer that exposes private data. Do not downgrade the
new document column after accepting client writes without a data recovery plan.

## Sync tokens

Tokens have the form `https://kith.app/ns/sync/<revision>`.
An empty token requests an initial sync. Malformed tokens, tokens below the
floor, and future tokens receive 403 with `valid-sync-token`; clients must
restart with an initial sync. Soft deletion and archiving appear as removals;
restoration and unarchiving appear as additions at the same href.

## Request validation

PROPFIND requires exactly one of `prop`, `propname` or `allprop`; `include` is
valid only alongside `allprop`. Invalid combinations, duplicate/missing selectors
and property text values return 400. Empty bodies retain allprop semantics;
unknown extensions and their subtrees are ignored. Explicit missing properties
in an allprop/include request receive 404 propstats.

PUT with an unsupported Content-Type returns 415 with a namespaced CardDAV
`supported-address-data` XML precondition. Both vCard 3.0 and 4.0 remain supported;
this response change does not alter the native/document write boundary.

## Known gaps

- Full CardDAV compliance remains open. Account-scoped user/role principal
  discovery, protected role ACLs and required principal/expand-property reports
  are implemented, but general user/group grant-ACE support remains unresolved.
  No role receives write-acl, and no access-control compliance token is advertised.
- PROPPATCH processes ordered instructions atomically. Live properties and fixed
  book displayname remain protected; absent dead-property removal is a no-op.
  Arbitrary dead-property persistence and writable book displayname require
  separate decisions. Multiple books/extended MKCOL are not implemented.
- OPTIONS and supported-report-set describe the resource's implemented methods
  and reports. Class 2 is no longer advertised; LOCK/UNLOCK are not implemented.
  Collection GET remains optional and undefined, as does its content length.

- CDV-30: chunked request parsing happens before DAV authentication.
- TOTP-enabled users can access DAV with their password; the blocking test is
  deliberately marked `test.fixme` until app passwords or equivalent exist.
- Both vCard versions preserve client properties and metadata in source form.
  Known version-specific properties/parameters are converted; genuinely
  unrepresentable conversion returns `supported-address-data-conversion` rather
  than silently discarding data.
- Uncoordinated raw SQL remains unsupported for shared mutations. Use the write
  service so native/document/revision changes commit together.
- Unconditional writes to resources created under the new policy can still
  overwrite newer shared edits. The server cannot infer an absent base revision.
- The existing numeric sync tokens have no restore epoch; overlapping histories
  after a DB restore require operational recovery. No protocol rewrite is part
  of this boundary change.

Native relationships in vCard 3.0 include an ungrouped
`X-KITH-RELATED;TYPE=...` identity alongside the grouped Apple display
name/label. Keeping that extension on PUT preserves the native relationship;
removing it removes visible relationships. Hidden targets remain protected.
vCard 4.0 uses `RELATED`. Grouped display properties alone do not identify
relationship targets.


## Independent protocol testing

The [community testing guide](carddav-community-testing.md) runs pinned upstream
CalDAVTester scripts against the dedicated synthetic account. It retains
failures and documents where upstream fixtures/features differ from Kith's
supported policy. The [client checklist](carddav-client-checklist.md) records
the latest targeted native Thunderbird ESR acceptance and remaining client gates.


The [remaining-work plan](plan/carddav-data-boundary.md#17-remaining-correctness-and-interoperability-plan-2026-10-29)
records priorities, file scopes, dependencies, acceptance gates and current local
validation. The historical community counts remain unchanged until a separately
recorded run; corrected local behavior does not establish full conformance.


## Revised-plan operational behavior (2026-10-29)

`/dav/principals/` remains the current-user discovery alias. Canonical user
principals are `/dav/principals/users/<id>/`; derived role groups are under
`/dav/principals/roles/<admin|editor|viewer>/`. Authenticated lookup and membership
are scoped to the current account. Different real users have distinct principal
URLs. Principal search supports displayname; arbitrary search properties are not
silently treated as matches. ACL reports require Depth 0; expand-property honors
Depth 0/1/infinity, only resolves local accessible DAV resources, and limits
recursive/output expansion. Granular current privileges reflect resource and role.

PROPPATCH uses 207 per-instruction results. A protected live-property change gets
403 with cannot-modify-protected-property; other instructions receive 424 when
any instruction fails. Unsupported dead-property sets get 403 without that
protected-property precondition. No arbitrary property storage is introduced.
Actual changes to protected role ACEs fail with no-protected-ace-conflict; other
well-formed ACL updates fail need-privileges/write-acl. These restrictions do not
establish complete ACL conformance.

Whole-account contact cleanup is atomic under one account lock and advances the
sync floor once. It intentionally avoids initializing documents immediately
before deletion. To clean physical storage, enumerate keys with AccountCleanup
before contact cascades inside the **same outer Store.transaction**, preserving
post-commit deletion and rollback retention. Selected-contact purge retains
surviving-neighbor publication.

See [section 17's execution record](plan/carddav-data-boundary.md#revised-plan-execution-2026-10-29-local-uncommitted-follow-up)
for staging-regression evidence, the decision to retain staging after the D1
experiment, deferred D2 and final validation.
