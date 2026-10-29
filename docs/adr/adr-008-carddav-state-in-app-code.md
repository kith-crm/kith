# ADR-008: CardDAV State in App Code

**Status:** Accepted
**Date:** 2026-10-23

## Context

CardDAV needs stable identities, conditional writes and incremental synchronization
for changes made through both DAV and the CRM. PR #45 proposed database triggers
and a change log. This branch targets fresh installations with no production
identities or existing client state to preserve.

## Decision

Keep DAV state in `contact_dav`, keyed by contact with cascading contact/account
foreign keys, rather than adding columns to `contacts`. Store account-unique UID
and resource name, sequence revision and unmapped extras. Generate UUID identities
and matching `<uuid>.vcf` names for local contacts; reserve identities while
contacts are archived or trashed. PUT to hidden identities returns 409.

DAV-supplied identities are restricted to UUIDs. Normalize bare UUIDs and UUID
URNs, including case variants, to a PostgreSQL UUID before storage, uniqueness
checks and relationship lookup. Generated cards emit UUID URNs consistently.
Resource names remain independent of identities. This deliberately rejects
non-UUID identities allowed by the general vCard specification. The migration
audits incompatible or colliding legacy identities rather than replacing them,
and advances revisions to invalidate representations changed by serialization.

Use application-level `Kith.DAV.Store.touch/2` calls instead of triggers.
`Store.ensure_rows/1` lazily supplies missing identities before DAV reads.
Account advisory transaction locks serialize revision allocation and commits
within an account. `Store.transaction(account_id, fun)` acquires the account
lock before contact row locks for merges, DAV writes and hard deletes, avoiding
inverted lock order. Merges also touch incoming relationship owners.

ETags are quoted sequence revisions shared by vCard versions. Collection state
is the maximum of contact revisions and the account's `dav_sync_floors` revision.
Hard deletes advance that floor rather than retaining a commit-time change log.
Tokens are `https://kith.app/ns/sync/<revision>` with no epoch. Malformed tokens,
values below the floor and values above current state return 403
`valid-sync-token`; clients must restart with an initial sync.

## Consequences

### Positive

- DAV identity and metadata stay separate from the CRM contact schema.
- No database triggers or PL/pgSQL functions are needed.
- Per-account revision ordering avoids exposing a token before an earlier
  revision commits; accounts can progress independently.
- Hard-delete invalidation needs one floor row per account, with cascading cleanup.

### Negative

- Every successful change to anything shown in a vCard must call `Store.touch/2`.
  `test/kith/dav/touch_coverage_test.exs` guards contact, child, relationship and
  vocabulary paths. Raw SQL bypasses this rule and is invisible until touched.
- The account lock serializes writes within an account; callers must preserve
  account-before-contact lock ordering.
- Hard deletion invalidates older tokens for the whole account. Clients must
  recover from 403 with an initial sync. DAVx5 passed the recorded recovery test;
  Thunderbird 158 did not recover automatically and required removing/re-adding
  the address book. Future tokens after a database restore are also rejected;
  no epoch distinguishes histories whose numeric revisions overlap.
- Unconditional PUT remains allowed: Thunderbird's observed writes without
  If-Match overwrite newer data. See the [client checklist](../carddav-client-checklist.md).

## Data-boundary revision (2026-10-28)

The original decision above describes the baseline implementation. The boundary
revision replaces post-commit touches with `Contacts.Write`: all shared writes
acquire the account lock, change native rows and document bindings, then publish
one revision per affected representation inside the same transaction. Private
and no-op edits publish nothing. `contact_dav` now stores the rich client document
in JSONB alongside identity, DAV-specific time and fingerprint; legacy extras
are quarantined. Native tables own shared values, with no background copy sync.

An immutable audited system-key registry grants shared email/phone/website
classification. Private Kith description/gender/custom fields never enter the
projection; client NOTE/GENDER/IMPP remain document-only. Explicit Kith export
and import policy is separate. Forward and reverse relationships share safe
standard categories, retain native subtype bindings and suppress hidden targets.

GET validators distinguish v3/v4 bytes (`revision-v30`/`revision-v40`); canonical
getetag is v30 and conditional writes recognize current variants. DAV time no
longer uses contact.updated_at. Read snapshots include collection state and all
native/document data together. Existing resources are marked to require a
current explicit validator for PUT/DELETE after migration; new-policy resources retain existing
unconditional compatibility. This intentionally limits old unconditional clients
whose cached cards may contain formerly exposed private data.

The account lock, UUID identity restrictions, reserved hidden identities,
hard-delete floor and compensating avatar cleanup are retained. Account reset
also advances the floor. Existing warnings about hard-delete recovery and
numeric histories after database restore still apply. Schema downgrade is not a
privacy-safe deployment rollback. See [the implementation plan](../plan/carddav-data-boundary.md)
and [CardDAV operations](../carddav.md) for cutover, audit and acceptance details.

## Alternatives Considered

| Alternative | Reason Rejected |
|---|---|
| PR #45 trigger-based design and change log | Adds hidden database behavior and retained change state; application touches and coverage tests keep ownership explicit |
| DAV columns on `contacts` | Couples protocol state to the CRM schema |
| Commit-time change log | More machinery and cleanup than account-serialized revisions plus a hard-delete floor |
| Sync epoch | Additional persistent state and token complexity outside the fresh-install scope |
