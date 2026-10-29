# CardDAV data boundary implementation plan

Status: local boundary implementation and recorded automated acceptance are complete. Section 17 is the active plan: simplify duplicate paths, test staging correctness, evaluate measured document refactors, then close required protocol gaps. Targeted native Thunderbird ESR 153.6 vCard 3 acceptance passed after the discovery fix recorded in section 16. Native vCard 4 preference, Android and iOS acceptance remain unverified. No deployment or publication is authorized by this document.
Original research: 2026-10-28. Active plan rewritten after simplicity review: 2026-10-29.
PR: [kith-crm/kith#46](https://github.com/kith-crm/kith/pull/46).

## 1. Baseline and evidence

This section records the original research baseline. Use section 15 for the
implemented architecture and section 17 for current work and later evidence.

The checkout was clean before this document was written. Local HEAD and the live PR head both resolve to `a0b2d3708f6d204e2853b464f68cd3a475163aa3`, the previously reviewed commit. The PR is open, from `feat/carddav-rework` into `feat/stack-40-consolidated`. No applicable `AGENTS.md` was found in this repository or its ancestor directories. The repository’s `CLAUDE.md` was also read for architecture and validation conventions. The initial research phase inspected source, tests, migrations, documentation, and the linked standards without running migrations or tests. Subsequent authorized implementation and validation are recorded in sections 14–15. Sections 2–13 retain the original proposal and its decision context; section 15 records the choices actually implemented.

The previously reported full suite result is **1,954 tests, zero failures at a0b2d37**. It is historical evidence for the current implementation, not validation of this proposal. The default test database reportedly has conflicting migration state; future implementation checks must use a separately named disposable database, following the earlier `MIX_TEST_PARTITION=_review46` approach after checking that the chosen partition is unused. Never reset the default database. Native results in `docs/carddav-client-checklist.md` predate complete UUID/avatar acceptance and must retain that qualification.

### Verified findings

- `lib/kith/vcard/serializer.ex`, `contact_field_line/1`, normalizes protocols and falls back to arbitrary `vcard_label`. `lib/kith/contacts.ex`, `dav_field_kind/1`, recognizes a narrower protocol list and only falls back to `IMPP`. A custom type with `protocol: nil, vcard_label: "EMAIL"` is emitted but is not reconciled or deleted; PUT then inserts a built-in/protocol-selected email. This code supports the reported 1 → 2 → 3 → 4 reproduction; that database reproduction was supplied by the earlier review and was **not rerun here**.
- `create_imported_contact_fields/4` searches `LIKE protocol%`, allows global and account types, orders only by `position`, and takes one row. A lower-position account-created type can receive DAV values. This helper serves both explicit import and DAV replacement today.
- `VCardAdapter.build_scalar_attrs/1` puts NOTE into `description`, and `maybe_resolve_gender/3` writes `gender_id`. The common serializer exports description and gender. Both directions violate the agreed DAV boundary.
- `VCard.Extras.extract/1` drops grouped lines and every recognized property. The parser flattens repeated scalar properties, retains only a reduced TYPE label for many mapped properties, discards group prefixes, and loses parameters in its contact map. Parameters on EMAIL/ADR/etc. cannot be reconstructed from extras.
- Serializer REV and plug `getlastmodified` derive from `contact.updated_at`. `Contacts.update_contact/2` always calls `touched_contact/2` after success; custom field/gender/type updates and original photo creation/deletion also touch DAV. Consequently private edits can change DAV bytes and/or revisions.
- General `Contacts` operations often write native rows first and call `Store.touch/2` afterward in a separate transaction. Acquiring an account lock only for the later touch does not make the native change atomic with DAV state. Display-name and phone workers also update rows before touching.
- `Store.transaction/2` already provides account-before-contact lock ordering. `AddressObject` puts identity checks, native replacement, extras, and revision into an outer transaction wrapped by `Avatar.with_cleanup/1`. Preserve this infrastructure, while removing nested publication of intermediate revisions.
- `Contacts.list_relationships_for_contact/1` displays forward and reverse relationships with reverse labels and target-level suppression; `dav_preloads/0` and the serializer use outgoing rows. v3 output includes `X-KITH-RELATED` with a UUID plus grouped Apple display properties. Its fallback relationship label can emit an arbitrary native type name. Reconciliation excludes hidden targets but serialization does not apply the equivalent target filter.
- `replace_contact_relationships/3` resolves UUIDs within an account, discards unresolved entries, and preserves excluded hidden native edges. Do not replace this with display-name matching.
- `ContactExportController` calls the same serializer and `Contacts.dav_preloads/0`. Applying DAV restrictions globally would change explicit export behavior.
- `Contacts.Cleanup.wipe_for_account/1`, used by account reset, bulk-deletes contacts without recording the DAV hard-delete floor. Full account deletion removes the account itself; account reset leaves an account with stale client state and needs separate handling.
- `CarddavPlug` obtains sync state, contact rows, and preloads in separate reads. A new design needs a consistent read snapshot as well as atomic writers; otherwise a response can combine a revision with another state of its children or return changes beyond its response token.

## 2. Ownership contract

The boundary is a purpose-specific policy, not contact authorization. DAV still requires account and role authorization. Authorized Kith screens, APIs, import tools, and full exports keep their existing access rules and private data. Never use a globally restricted Contact changeset or globally filtered preload to implement DAV policy.

### Native shared values

Expose and permit DAV mutation of only these values:

- Given, middle, family and formatted names, and nickname. `display_name` is derived under Kith's naming rules; imported FN can supply a name only through an explicit fallback when N provides none.
- Email, phone and website values on **trusted built-in types**. Include seeded Email, Phone, Mobile, Work phone, Fax and Website. Their safe standardized labels may be rendered. Account-created types remain private even if they exactly mimic a built-in's name, protocol or vCard label.
- Postal address text and its public address label, birthday and year-unknown flag, company, occupation/job title.
- Selected processed avatar; never the original photo collection or storage keys.
- Tags through CATEGORIES, and relationships through the policy in section 6.

All other native state is private by default: account-created contact fields; gender; description; notes and activities; original/timeline photos; reminders and reminder flags; first-met information; aliases; integration identifiers, statuses and URLs; favorites; deceased metadata; currencies, documents, tasks, gifts, debts and other sub-entities. Address coordinates, native row/type IDs, geocoding state, crop/source metadata, audit/import provenance and internal bindings are private too. Archive/trash are visibility controls, not vCard properties. They produce collection removals rather than revealing their Kith state.

Built-in social-service fields are not automatically websites: the seeds include Twitter, Facebook, LinkedIn, Instagram, Telegram and WhatsApp with URL-like protocols. Recommendation: exclude these specialized types under the agreed email/phone/website scope; a client URL is a generic Website. Confirm this product interpretation before implementation. Client IMPP/social extensions remain document-only and never create private native fields.

### Client document values and metadata

Client-origin NOTE, GENDER/X-GENDER, IMPP, social extensions, arbitrary X-properties, unsupported structured components, parameter lists, groups and repetitions belong to the DAV document. They may be returned through DAV and queried as client data. They must never read or write the corresponding private Kith fields. A Kith description and a client NOTE can contain different values indefinitely. The same separation applies even to a property named `X-KITH-DESCRIPTION` or a parameter purporting to contain a native row ID.

For bound properties, native tables own the mapped components; the document owns additional components and parameters. For example ADR street/city bind to an Address, while PO box and extra components that Kith cannot represent remain document metadata. ORG company binds natively while extra organizational units survive in the document. N prefix/suffix and additional list elements survive without inventing native columns. Kith edits replace the owned components only; stale raw property values never override native shared values.

UID, resource name, representation version, REV, publication timestamps and revision are server-controlled. Preserve supplied UID under the current UUID normalization rules, keep the existing resource name, and reject identity changes. Incoming REV is informational client syntax, never the source of server revision/time. VERSION determines decoding/encoding; it is not a writable Kith attribute. Preserve client PRODID without pretending it is a server-authored native field. Internal binding IDs are never trusted from the wire or serialized.

PUT replaces the current shared representation **and** client document: omitted writable shared properties clear their mapped values/rows; omitted client-only properties are removed. It preserves private native rows and metadata, including hidden relationships. DELETE has the existing explicit resource lifecycle meaning (trash), not field-level erasure. A client cannot use omission or a forged property to clear description, gender, custom fields, source photos or integration state.

## 3. Proposed modules and persistence

Use one `Kith.DAV.SharedContact` projection (proposed name) for field classification, values, relationship visibility and writable components. It returns a deliberately small immutable data structure, not an unrestricted Contact passed to the general serializer. It also defines affected-contact dependencies and normalized equality. Reads, PUT reconciliation, REPORT bodies and query evaluation consume this policy. Do not duplicate protocol checks in serializer and reconciler.

Use a `Kith.Contacts.Write` service (proposed name) for contact-affecting commands from Kith and DAV. Existing public `Contacts` APIs remain facades, preserving their result shapes. The service accepts an explicit trusted origin/command; clients cannot set origin via params. Separate authorized Kith changesets from the DAV shared command decoder. Private-only operations can use a fast path, but must be classified centrally and must never independently publish DAV state. Re-read contacts before applying commands: current changesets recompute display names even on private edits, so applying a stale struct must not inadvertently restore an old shared name or bypass the projection comparison.

Use `Kith.DAV.Document` and a small lossless content-line layer under `Kith.VCard` for document manipulation. Use the existing DB; no second database, synchronization worker, or competing writable contact JSON copy.

### Trusted field classification

Add a nullable immutable `system_key` to `contact_field_types`, with a unique index where non-null and a DB constraint that it is only set on system/global rows. Known keys include email, phone, mobile, work_phone, fax, website. A code-owned registry maps those exact keys to shared kinds and standard type tokens. Other seeded specialized types can have trusted keys without becoming shared. Ordinary create/update changesets and API controllers must not cast this field. Restrict seed/migration assignment to a privileged code path; `account_id IS NULL` alone is never sufficient.

There are no stable keys today, and seeds use `insert_all ... on_conflict: :nothing`. Backfill must audit exact known seed definitions, duplicates and ambiguous globals, not blindly mark every matching name/protocol. Do not hardcode numeric IDs. Ambiguous installations fail classification preflight or require an explicit reviewed mapping. Unclassified rows remain private. Enforce account scoping on every row/type lookup, including when retaining an existing field.

For new DAV email/phone/website rows choose a single deterministic trusted destination for each kind (Email, Phone, Website); optionally use Mobile/Work phone/Fax only through an explicit safe TYPE mapping. Recommendation: generic destinations initially, retaining client TYPE metadata in the document. Existing matched rows retain their native subtype IDs and labels regardless of generic wire type. Missing canonical types must fail with a diagnostic, never select the first account protocol match or silently drop a value.

### Document schema

Recommendation: add a one-to-one `contact_dav_documents` table, cascading from `contact_dav.contact_id`, with `account_id`, `schema_version`, `source_version`, `properties jsonb`, and a normalization/policy version. Keep `contact_dav` as the identity/revision anchor. Add `representation_modified_at` (UTC microsecond-capable) and an internal representation fingerprint there. Optional per-version byte hashes can be stored or deterministically computed. Existing extras remain temporarily available for audited migration/rollback only, never concatenated into new DAV output.

Each ordered property occurrence records:

- Server-generated opaque occurrence ID, original group/name spelling and normalized property name.
- Ordered parameter occurrences with their raw syntax and decoded values; preserve duplicate parameter keys and quoted lists rather than flattening to a map.
- Raw unfolded value and decoded typed/structured components, explicit VALUE/encoding, source version and original line syntax when reusable. Store original property syntax for unknowns; do not retain unrestricted raw input as a second rendered body.
- Optional internal binding: native kind/row ID, owned component paths, relationship direction, and prior public value fingerprint. Scalar paths bind to the owning contact; categories can bind multiple tag memberships. Related compatibility properties can be a single logical bundle.
- Provenance: client-supplied, generated shared property, or server compatibility companion. This is internal evidence, never a wire parameter.

JSONB arrays preserve ordering/repetitions; do not use a name-to-value object. JSON row references cannot enforce polymorphic FKs: enforce them in the service, verify same contact/account and trusted kind on every use, and audit dangling bindings. If that proves fragile during the first implementation slice, move bindings into a small relational table with typed nullable FKs/check constraints; do not build both schemes preemptively. A native row can have several version-specific companion occurrences, but one logical shared value must not accidentally become several native rows.

Property values may be cached for lossless syntax and matching, but are never a second authority for bound values. Rendering overlays current projected native components. The write service updates bindings and owned components in the same transaction, so subsequent reads need no background repair.

### Codec evaluation before dependency selection

The repository has no vCard dependency in `mix.exs`; existing Parser/Serializer already cover folding, escaping, date forms, UUIDs, photo data URIs and version differences. Reuse those tested semantic helpers. `Parser.split_line/1` and `split_params/1` recognize quoted delimiters; however `params/1` strips quotes/splits lists, the contact parser discards groups, and `Extras` is intentionally insufficient. `AddressQuery` contains another reduced content-line parser. None is currently a lossless document codec.

First prototype a document API around ordered content lines using the existing scanner, preserving raw syntax before decoding; make query evaluation consume that API rather than add a fourth parser. Check UTF-8 unfolding/folding, quoted colon/semicolon/comma, escaped structured/list delimiters, repeated params, parameter encoding, binary/data URI PHOTO and v3/v4 conversions with fixtures. Investigate RFC 6868 parameter escaping as needed for v4; current helpers are not proof of support. Do not expand explicit import tolerances into silent acceptance of malformed DAV documents.

A dependency is justified only if this spike fails the preservation/conversion corpus and a maintained candidate demonstrably handles both versions, unknowns and groups. No particular library is validated or recommended by this research. A lossless document layer is necessary; a replacement of unrelated DAV routing/auth/XML machinery is not.

## 4. Matching and reconciliation

Matching is scoped to one account/contact and shared kind. It is a multiset operation, consuming each prior property/native row at most once. Never match a private field just because its value equals an incoming EMAIL.

1. For v4 PID-bearing properties, match using PID plus CLIENTPIDMAP source identity, following RFC 6350 section 7. Numeric PID alone is not globally stable. Keep CLIENTPIDMAP with its references. Validate conflicting identities; do not accept a binding ID from a client extension.
2. Match unchanged properties by decoded shared value/components and compatible standard type, using the prior document's occurrence/bundle bindings. Groups help pair companions inside a document; group names alone are not stable native identity.
3. Match remaining unchanged native shared rows by the same public semantic fingerprint; use stable occurrence order/native ID order to break exact duplicate ties. Preserve multiplicity, IDs, native subtype, label and geocoding metadata. Reordering parameters or equivalent escaping cannot create rows.
4. A changed value can update the same native row if a validated prior property identity establishes the binding. Without reliable identity, a unique compatible unmatched old/new pair may be updated conservatively; document this heuristic and test ambiguity. Never guess across several equal-kind candidates. Delete/insert unmatched shared rows rather than attach metadata to an arbitrary row. Preservation of IDs is guaranteed for unchanged round trips, not for every ambiguous client edit.
5. Insert unmatched mapped values into trusted destinations. Keep unmatched client-only properties as document occurrences. Unsupported or out-of-range values for a shared property require an explicit decoder outcome: retain unbound document data when the value has no native representation, or reject the whole invalid update. Do not truncate or silently discard it. Ship an allowlist of these cases with tests, particularly long EMAIL values, partial BDAY and repeated scalar properties.
6. Delete unmatched **visible writable shared** rows, not all children. Preserve private custom fields, hidden native relationships, and private metadata on retained rows. Missing PHOTO clears selection only. Missing tags removes memberships, never other contacts' memberships or tag definitions.

Repeated EMAIL/TEL/URL/ADR occurrences each bind a row, including deliberate duplicates. Repeated legal scalar values/lists that exceed the native scalar model retain the extra client components/occurrences; designate one deterministic primary binding. Enforce vCard cardinality where the specification requires it rather than accepting competing UIDs/versions. For Kith scalar edits, update that primary and preserve client-only alternatives; clearing the shared scalar removes its mapped occurrences and owned companions so old syntax cannot resurrect it. Define component-level clear behavior for N/ORG/ADR in fixtures before coding.

## 5. Transaction flows

### Kith edit, import or bulk command

1. Authorize the Kith operation as today. Enter `Avatar.with_cleanup/1` around the outermost write result when files can change.
2. Begin the service transaction; acquire the existing account advisory lock **before** contact, child or type locks. Re-read affected rows and dependencies, lock contact IDs in deterministic order, and ensure identities/documents for new contacts within this transaction.
3. Capture the old projection/document and visibility. Apply the native command using existing validation and access. Shared and private fields may be edited together; a private-only command must not project private data.
4. Update bound property components and bindings from the new native shared values, retaining unrelated client metadata. Create/remove generated properties as necessary. Recompute dependent cards (relationship endpoints, target display companions, tag users) only when their projected output changes.
5. Compare normalized public document plus visibility, independent of `contacts.updated_at`. If unchanged, preserve document syntax/order, DAV revision, representation timestamp and ETags. If changed, publish one revision per affected object, set DAV time, and store the fingerprint atomically with native/document changes.
6. Commit before broadcasts, cache invalidation and external side effects. Preserve intended reminder creation/reconciliation for authorized native shared birthday edits; moving it inside a transaction or scheduling after commit needs explicit failure/retry semantics. DAV must not accept reminder configuration or use private reminder data to render cards.

A failed native validation, document update or revision publication rolls back all database changes. Do not leave successful native writes followed by failed DAV touches. Bulk operations may use bounded transactions, but each published contact mutation is indivisible.

### DAV PUT

1. Apply existing authentication, role checks, body limits and resource-name validation. Decode exactly one v3/v4 card into the rich document plus an allowlisted shared command; never pass a broad Parser contact map to `Contacts.update_contact/2`.
2. In the service transaction acquire the account lock, resolve and lock the current resource, then validate If-Match/If-None-Match and normalized immutable UID against the locked current representation. Keep UID conflict handling and reserved hidden identities. Do not decide from a pre-lock read.
3. Reconcile incoming shared properties with the old projection/document using section 4. Replace client document content, overlay server-owned identity/REV, and retain native private state. Do not reuse `create_imported_contact_fields/4` or general import policy.
4. Process supported selected PHOTO through the existing bounded avatar processor; stage created/retired files. Omitting PHOTO clears avatar selection, preserving source photos. Never fetch arbitrary remote PHOTO URLs as a new side effect; define URI preservation separately below.
5. Update all affected native rows, relationship counterpart documents, current document and revisions in one transaction. An unchanged GET/PUT preserves IDs and revision/time; a metadata-only client change changes DAV state without changing private native fields.
6. Keep 201/204, 409 identity/hidden-resource conflicts, 412 precondition failures and existing deadlock-to-503 behavior where applicable. Do not return a strong PUT ETag when the stored representation differs from submitted octets. Current code returns no PUT ETag; retain that conservative behavior initially.

### Deletion, hiding and restore

DAV DELETE retains current soft-delete-to-trash behavior under the write service and preconditions. It may change `deleted_at`, but cannot overwrite private field values or hard-delete private child records. This is the explicit lifecycle exception to field mutation rules. Kith trash/archive similarly publishes a removal while reserving UID/href and retaining the document. Restore/unarchive regenerates the current shared view at the same identity and publishes reappearance; account for the combined archived-and-trashed state so changing one flag does not expose a still-hidden contact.

Visibility changes must update visible relationship neighbors in the same transaction; hiding a target removes names, URI and generated companions from their cards. Omitted hidden edges on a later PUT remain native and can reappear when restored. Hard delete/empty trash/purge remove documents by cascade, update neighbors, stage files, and advance the existing account sync floor. Account reset must also advance a persistent floor while the account remains, and coordinate the whole reset/storage cleanup against DAV access. Account deletion can cascade all DAV state after access is disabled.

### Failure and rollback

Keep `Avatar.with_cleanup/1` at the actual outermost transaction boundary: remove newly created unreferenced files after rollback; retire old unreferenced assets only after commit, using current reference checks/registry. Nested operations must propagate a failed tuple/exception to that boundary; do not mistake an inner success for a committed outer transaction. Storage cleanup is compensating work, not a PostgreSQL transaction; crash recovery/orphan cleanup remains needed. Do not broaden this revision into a new storage architecture.

Rollback tests inject failures after native edits, after document writes, after avatar staging and before revision publication. Check database state, file references, original photos, quota accounting and DAV bytes/validators, not merely the returned status. A dry-run outer transaction (including import auto-merge dry runs) must not broadcast a publication, retire files or leak staged files after its deliberate rollback.

## 6. Relationships and vCard versions

### Relationship policy needing a product decision

Recommendation: expose the same forward/reverse relationship view users see in Kith, with safe standardized categories and a binding to the actual directed native edge. Do not silently assume that exporting outgoing rows satisfies the agreed relationship requirement. Confirm whether reverse relationships must be editable through DAV before implementing this slice.

If confirmed, a reverse property binds the underlying row with direction; changing/deleting it updates that row and both endpoint documents atomically. New relations are outgoing from the edited resource with a deterministic trusted relationship category. Deduplication must handle two native reciprocal rows and UI suppression without discarding private subtype metadata: represent a logical visible edge with bindings to the exact underlying row set. Specify whether removing a collapsed edge removes all contributing visible rows; recommendation: yes for the represented relationship, with hidden rows excluded. If this is too surprising, do not silently ship reverse deletion: agree a different edit contract first.

For native subtypes use an explicit code-owned standard mapping, ideally trusted `system_key`/DAV category on built-in relationship types. Existing custom labels may map to generic `contact`; never emit arbitrary native `name` or `reverse_name`. Preserve the custom native type ID on an unchanged round trip via internal bindings. Renaming a private custom label must not change DAV bytes. Only a deliberate trusted classification change can alter the public category. Safe reverse mappings (parent/child, spouse, friend, sibling, colleague) must be explicit rather than inferred from arbitrary reverse label text.

Filter targets by same-account active DAV visibility **before** rendering URI, name, groups, labels or query properties. A known local UUID targeting hidden/private data must not be reintroduced as an unbound client relationship. Preserve its native edge privately; suppress its document rendering. Unknown external URI/text RELATED remains document-only without name lookup or implicit target creation. Never resolve a cross-account UUID by querying outside the account. Decide whether an unknown URI becomes bound automatically when a matching contact is created later; recommendation: no, require an explicit later client edit/import resolution.

### Compatibility decisions

Keep v3.0 and v4.0 on all existing advertised paths. v4 uses RELATED with UUID URN, TYPE and explicit VALUE=text where needed for unresolved text; preserve PID/CLIENTPIDMAP and all client params. v3 keeps `X-KITH-RELATED` as the identity-bearing compatibility property until a replacement passes round-trip and native-client tests. Keep grouped Apple names/labels as presentation companions with safe standardized labels and opaque group names; never put raw native row IDs or arbitrary Kith subtype labels in generated groups. Client-origin groups and arbitrary labels can survive as client metadata.

Match generated compatibility bundles as one edge. A client that retains only an Apple display name cannot identify a native contact safely: retain that text client-only, do not guess by name. If it removes the identity property on a replacement PUT, the shared edge is absent under replacement semantics; test this client behavior before claiming compatibility. Do not remove UUID/URN identity handling, `Store.get_related/2`, reserved identities or conflict behavior while pursuing this redesign.

Retain the documented yearless birthday representation `BDAY:--MMDD` in both versions: standard in v4, an existing interoperability extension in v3. Do not resurrect the import-only `X-KITH-BDAY` fallback on DAV PUT. Preserve client extensions but give the current BDAY/absence precedence.

Rendering should be lossless for untouched client properties within their source version, allowing line folding and safe normalization. Cross-version conversion needs a tested mapping for TYPE/PREF, TEL URI/text, PHOTO binary/data URI, dates, RELATED and version-specific parameters. Preserve nonconvertible information in source-version document occurrences; never delete it just because a client requested another version. A converted GET followed by PUT must not create duplicate native rows.

Cross-version replacement can legitimately remove omitted client properties, but the server must not produce a silently lossy converted card that then erases them on unchanged PUT. Before rollout choose validated reversible compatibility encodings for supported cases; return the standard supported-address-data-conversion error for genuinely impossible conversions rather than fabricate invalid v3 syntax or lose metadata. This is a bounded codec decision, not permission to drop v3 support.

PHOTO URI and repetitions require a gate: current DAV accepts inline bytes but rejects URI photos. Recommendation: valid external URI-only PHOTO stays client-only without network fetch and without exposing a private original; define whether it clears or preserves the current native selection on PUT (replacement favors clearing). For a primary inline PHOTO, native ownership requires rendering the processed rendition rather than incoming original bytes. Preserve extra client photo metadata/repetitions without treating them as Kith originals, and verify the resulting cardinality/version rules. Client-supplied bytes are distinct from private Kith photo provenance; never seed document PHOTO from the native original. These details need fixtures and explicit decisions, not silent parser fallbacks.

## 7. Revisions, timestamps, ETags and concurrency

Retain the global sequence and per-account advisory lock, account-unique identity indices, sync floor and hidden identity reservations. Allocate a revision only when the published shared/client document or visibility changes. Coalesce multiple inner mutations into one publication per object. Sequence gaps on rollback are harmless. No-op Kith/DAV edits and private changes leave the complete DAV tuple unchanged.

Use `contact_dav.representation_modified_at` for REV and getlastmodified/Last-Modified. Never fall back to `contact.updated_at` after cutover. Client REV cannot move it backwards or forge it. HTTP dates have second precision; distinct revisions may share a timestamp, so preconditions rely on ETags. A metadata-only client edit changes REV/time; a private-only Kith edit changes neither. Exclude the generated REV itself from change detection to prevent self-triggering revisions.

The existing identical strong tag for different v3/v4 bytes deserves a narrow correction. Recommendation: deterministic per-version tags incorporating published revision, policy/codec version and representation hash, with v3 as the canonical default resource variant for DAV:getetag. GET variants use their own strong tag and appropriate Vary metadata. REPORT conversions may carry canonical resource getetag alongside negotiated address-data; document/test that distinction. If-Match accepts only a current server-issued representation tag for this object, validating its variant against current state; it must not accept any tag merely because it contains the same revision number. Test real clients before finalizing the exact tag shape and REPORT behavior. Do not advertise a strong tag for bytes that can vary unpredictably.

Read identities/collection token, documents, projected rows and preloads within one consistent PostgreSQL snapshot (for example a short repeatable-read transaction after any necessary identity backfill). Avoid using a token fetched before a different snapshot's rows. For large responses take a bounded immutable snapshot before streaming; do not hold the account write lock while sending network output. Existing address queries should evaluate the same rendered document, including client NOTE, without loading private Kith description as searchable data. Partial address-data/PHOTO filtering must run after full policy projection.

Selected avatar assets must be immutable and fingerprinted. A transient storage read failure must fail the response, not silently omit PHOTO while reusing an ETag for different bytes; current adapter logs and omits on read failure. The DB snapshot must identify the asset/hash that the body uses. A serializer policy update affecting bytes needs explicit revision/hash invalidation, not dependence on a deploy's current timestamp.

Preconditions are checked inside the account transaction against locked current state. Retain unconditional PUT behavior only subject to the cutover decision below; an unconditional stale write can overwrite newer **shared** data, but can never mutate private native data. Preserve the existing documented limitation rather than promise automatic conflict resolution. No background synchronizer is needed.

## 8. Mutation path inventory

This is the required integration checklist from the current source. Public facades can remain, but their shared mutations must execute inside the service; replacing only the HTTP PUT path is insufficient.

### Shared or visibility-affecting paths

- `contacts.ex`: `create_contact/2`, `update_contact/2`; `soft_delete_contact`, `restore_contact`, `archive_contact`, `unarchive_contact`; `hard_delete_contact`, `empty_trash`, and incoming relationship owner discovery. Creation must initialize DAV state atomically, including imports before a client's first read.
- Address `create_address`, `update_address`, `delete_address`. Keep coordinates/geocoding private; `perform_geocode/2` may stay a private write but must not touch DAV.
- Field `create_contact_field`, `update_contact_field`, `delete_contact_field`, including changes of type/contact association allowed by existing changesets. Classify old and new states and update all affected owners. Private custom-field operations publish nothing. Validate ownership rather than trusting contact IDs in attrs.
- `tag_contact`, `untag_contact`, `update_tag`, `rename_tag`, `delete_tag`, `delete_tag_with_removal`, `merge_tags`, including bulk join-table changes. Reproject all affected contacts in the same transaction; preserve tag IDs/memberships on unchanged PUT and avoid global tag deletion from omission.
- `create_relationship`, `delete_relationship`, trusted relationship vocabulary/classification migrations, and any future update command. Reproject both endpoints under the agreed reverse policy. `update_relationship_type` only publishes if its trusted public projection changes; custom private label edits do not.
- `set_avatar`, `clear_avatar`, `Avatar.set/3`, selected-source `delete_photo`, avatar rendition/backfill updates that change selected bytes. `create_photo` and unselected `delete_photo` are private and should lose their unconditional touches. Retain AvatarProcessor/AvatarAsset/cleanup infrastructure and storage quota enforcement.
- `import_contact/2`, its raw contact/field/address inserts and photo import helpers; `replace_contact_children/3` must become DAV-specific reconciliation under the service or be removed from external use. Keep explicit import policy distinct from DAV policy.
- `contacts/merge.ex`: `run/4`, `build_multi`, scalar resolution, field/address/tag dedupe/remap/drop, relationship remap, loser soft deletion, selected rendition restoration, and updates to incoming owners. All direct Multi/SQL steps remain within one service publication transaction. `merge_cluster` and legacy `merge_contacts` facades must converge here.
- `workers/display_name_recompute_worker.ex`: bulk native display-name updates and affected relationship companions; read current account preference/rows under the command and avoid publishing unchanged results. This worker is an authorized native edit, not background DAV synchronization.
- `workers/phone_renormalize_worker.ex`: raw field updates. Preserve intended normalization of private custom phone types if still required by Kith; publish only when a trusted shared field changes. Do not narrow Kith's normalization behavior merely to fit DAV.
- `imports/sources/monica_api.ex`: raw `contact_tags` insertion/Store.touch, plus Contacts-based create/field/address/relationship calls; `imports/duplicate_automerge.ex` and Monica auto-merge route through merge service. Follow-up photo worker uses `create_photo` then `set_avatar`; only selection publishes.
- `dav/address_object.ex`: PUT/DELETE and all new-resource identity setup; `dav/store.ex`: `ensure_rows`, identity/extras/document writes and publication helpers. Restrict direct `touch` calls to the service/migrations. `carddav_plug.ex` routes all reads/reports through the snapshot/projection.
- `contacts/cleanup.ex`, `workers/account_reset_worker.ex`, `workers/contact_purge_worker.ex`, account deletion/storage cleanup: reset/purge must publish removals/floor appropriately; account deletion disables access and cascades rather than preserving inaccessible sync state. Do not make reset's file enumeration race with contact writes.
- `lib/mix/tasks/kith.avatars.backfill.ex` and Avatar's backfill path: selected legacy originals become processed shared renditions through the service; keep resumability, asset accounting and no-op detection. Seed/migration/admin repair scripts changing public state need explicit service or locked backfill publication rules.

### Private paths that must remain functional without DAV publication

`Contacts.update_contact` for description, gender, aliases, first-met, favorite, deceased, currency and integration metadata; gender/type creation, rename, reorder and deletion; custom field type CRUD; original photo create/delete; Immich link/unlink and `workers/immich_sync_worker.ex` direct integration status writes; notes/documents/reminders; `activities.ex` raw `last_talked_to` updates; Monica miscellaneous/private imports. These do not all need a heavyweight DAV transaction. They need an explicit private classification and negative coverage ensuring they cannot change the public document/time/revision. A mixed command still uses the unified service.

UI/API controllers and LiveView contact forms, bulk actions, trash, fields, tags, relationship and photo components already call Contacts APIs in the traced paths. Preserve those facades and return types rather than duplicating DAV publication in each caller. Audit all `Repo`, `Multi`, `insert_all`, `update_all`, `delete_all` and raw SQL contact mutations during implementation; add a maintained allowlist of private/raw maintenance paths. A text search alone is not a proof that future writers comply.

## 9. Import/export, merge and lifecycle details

Explicit Kith vCard import can still put NOTE into private description under its existing import intent; DAV PUT cannot. Keep `Parser.parse` contact-map mode for those callers. Full Kith exports use explicit export preloads/policy instead of `dav_preloads`; preserve current gender, description and custom field export behavior and any other authorized full-export formats. A vCard export does not automatically represent all private Kith entities; do not imply it is a full backup. Decide whether a named DAV-format download includes client document metadata; recommendation: expose that separately from the existing Kith export, whose mapping rules must not silently change. Test exports and re-imports independently.

For merge, keep the survivor's UID/href, reserve loser identities while trashed, and retain each loser's document for restore/history without rendering private snapshots. Move/rebind shared native rows according to the actual merge resolution and dedupe map; dangling JSON bindings must not follow deleted row IDs. The survivor retains its client-only document by default. Recommendation: do not silently combine conflicting loser NOTE/GENDER/unknown properties or PID source spaces; preserve loser documents and require explicit merge policy/selection if metadata is to move. Shared values chosen from losers get rebound into the survivor, and relationships targeting losers are remapped atomically with affected cards. If client metadata union is later chosen, remap CLIENTPIDMAP/group namespaces and preserve provenance; never concatenate raw lines blindly.

Trash/restore and merge restore use current native shared state plus preserved document metadata, never an old serialized card containing private fields. Original photos remain private even when source rows move/dedupe. Changing/clearing the selected avatar updates PHOTO; deleting an unselected source does not. Restored/merged rendition references continue to use AvatarAsset registry and existing reference checks. A shared PHOTO omission must not delete timeline source images.

## 10. Migration and rollout

1. Add classification keys, document table and DAV timestamp/fingerprint fields additively. Do not rewrite historical migrations or change existing UUIDs/hrefs. Audit deployed state even though ADR-008 describes a fresh-install target; no production/client-state assumption is established by this research.
2. Build an offline/read-only audit report first: ambiguous system types; custom protocol/label impostors; per-contact duplicate shared fields grouped by trusted type/value/label; untrusted types selected by prior DAV imports; hidden relationship leaks; legacy avatars; extras/property counts. The supplied duplication case is a detector fixture. Identical values are not proof of accidental duplicates, and there is no reliable DAV-origin provenance today. Do not automatically deduplicate/reclassify private rows or delete data. Produce candidates with row IDs for authorized review; retain IDs on unchanged migration.
3. Backfill documents in bounded per-account transactions using **only the new shared projection**, trusted current values and audited client extras. Never bootstrap by serializing the old unrestricted card: it contains private description/gender/custom fields. Existing extras have lost mapped metadata irreversibly; document that it cannot be recovered without client-owned copies. Audit legacy extras before preserving them: old persistence does not prove client provenance if earlier code allowed native custom labels to masquerade as extras. Quarantine ambiguous data rather than expose it.
4. Initialize DAV times at the cutover publication time (or an explicitly proven prior DAV publication time), not a private-updated contact timestamp. Advance revisions for affected representations, retaining IDs/hrefs. Keep floor monotonic and sequence ahead of restored/imported revisions. Prefer changed-object revisions so incremental clients can fetch sanitized cards; do not force floor invalidation without need, given historical Thunderbird recovery failure.
5. Gate reads/writes until each account is fully classified/backfilled. One serving policy per account; no background dual-write sync and no partially upgraded reader falling back to old serializer/extras. Deploy writers before activating new reads, or use a maintenance window with workers paused; mixed old writers would bypass bindings and atomic publication.
6. Resolve stale clients before enabling writes. New revision/tag rejects stale conditional PUTs, but current Thunderbird can send unconditional old cards containing former private exports. Server provenance cannot distinguish an echoed old description from a newly authored identical client NOTE. **Recommendation:** at privacy cutover require a current new-format If-Match on existing-resource PUT (and assess DELETE), with a documented refetch/reconnect procedure; retain If-None-Match creation checks. This changes compatibility for unconditional clients and needs explicit product approval. Removing the gate while allowing unconditional PUT reopens the echo ambiguity. A one-time token bump, successful GET or elapsed time does not prove an unconditional payload is current. Never promise that a migration can erase already downloaded private copies.
7. Exercise sanitized reads, write paths, scripted sync and native clients on an isolated staged account before rollout. Record wire versions, preconditions, repeated sync behavior, private-field negatives, relationships and selected avatar behavior. Keep historical results separate. Measure serialized-document size, query/multiget latency and write-lock contention with the existing 2,000-contact harness; enforce existing request limits and reasonable document/property limits without silent truncation.
8. Retain old extras and reversible schema for a bounded review window, plus database/storage backup. After successful cutover and audits, remove legacy DAV call paths and update ADR-008/docs. Backfill can resume idempotently; checkpoints must distinguish complete accounts from failed transactions.

Deployment rollback must preserve the privacy boundary: disable DAV writes/serving or roll back to a build that understands the new policy, not the old serializer that leaks private fields. Keep the new schema/documents in place. Native DB restore may overlap old numeric sync histories; the existing no-epoch design remains a known limitation. Do not reset revision counters or silently reuse validators. A schema downgrade discarding client metadata is a data-loss operation requiring a separate backup/recovery plan; it is not the default rollback.

## 11. Staged implementation slices and acceptance gates

Each slice should be reviewable and gated; intermediate code must not activate a partial public contract.

### A. Boundary characterization and codec spike

Scope: `test/kith/dav`, `test/kith/vcard`, existing parser/serializer/extras tests; proposed document fixture corpus. Depends only on the current baseline.

Add regressions for the reported custom EMAIL accumulation, account type chosen before system type, NOTE/gender isolation, metadata/group/repetition preservation, and private-edit DAV invariance. Record currently failing cases clearly. Prototype document decoding/rendering without altering DAV serving. Acceptance: v3 and v4 fixtures preserve groups, parameter occurrences, structured extra components, unknowns and multiplicity; repeated unchanged reconciliation has stable row counts/IDs. Decide existing-code extension versus dependency with evidence.

### B. Trusted registry, schema and projection

Scope: new migrations; `contacts/contact_field_type.ex`, `priv/repo/seeds.exs`; proposed `dav/shared_contact.ex`, `dav/document.ex`; `contact_dav.ex`/Store persistence. Depends on A's document contract.

Acceptance: account/global impostors remain private, generic destinations deterministic, ambiguous seeded installs fail preflight, no user changeset can set trusted keys, and backfill contains no native private values. Up/down behavior tested on a disposable DB, including backup-preserving rollback limits. No new serving path activated yet.

### C. Unified native write service

Scope: proposed `contacts/write.ex`, `contacts.ex`, `contacts/avatar.ex`, Store transaction/publication helpers; core Kith callers through unchanged facades. Depends on B.

Acceptance: Kith shared edits update native/document/revision atomically; private/mixed/no-op updates have correct selective publication; failed operations leave all state unchanged. Birthday reminders and existing return shapes retain intended behavior. Account lock is acquired before row/type locks. Two simultaneous writers and a concurrent snapshot reader never observe mismatched native/document/tag states.

### D. DAV PUT and read/report/query cutover

Scope: `dav/vcard_adapter.ex`, `address_object.ex`, `carddav_plug.ex`, `address_query.ex`, Document codec; explicitly separated export preloads/controller. Depends on B/C and codec decisions.

Acceptance: GET/PUT in both versions repeated at least four times retains shared/native subtype IDs, private fields and metadata. Omission clears only shared/document state. Metadata-only PUT changes validator; private edits preserve exact GET bytes, REV, ETag, DAV dates, query results and sync membership. Query by private description/gender/custom value finds nothing unless a separate client-owned property contains it. Test PROPFIND, multiget, query, sync, partial address-data/PHOTO exclusion and version negotiation against one policy. Validate stale If-Match, If-None-Match *, wrong UID/account, hidden identities and rollback after PHOTO failure. Seed every private field with a distinct sentinel; assert that reads/reports/queries cannot discover them and PUT cannot change them. Test client NOTE and GENDER alongside different native description/gender values, plus forged native binding/type IDs, cross-account relationships and private fields with identical values to shared ones. Verify snapshot/token consistency and no PHOTO omission under a reused strong tag on storage error.

### E. Relationship semantics and compatibility

Scope: SharedContact relationship projection; relationship bindings/reconciliation; parser/serializer compatibility helpers and tests; native relationship facades. Depends on D and the reverse-edit decision.

Acceptance: forward/reverse mapping, reciprocal rows, custom subtype preservation without custom-label leakage; hidden target suppression and hidden-edge preservation; unresolved URI/text survival without name guessing; v3 X-KITH-RELATED/Apple bundles and v4 RELATED conversions do not multiply edges. Endpoint rename/hide/delete/restore updates precisely the affected cards, atomically. Do not remove existing identity support before these pass.

### F. Bulk writers, imports, merge and lifecycle

Scope: `contacts/merge.ex`, workers listed in section 8, `imports/sources/{vcard,monica_api}.ex`, duplicate auto-merge, Contacts.Cleanup/reset/purge and avatar backfill. Depends on C–E.

Acceptance: shared rows moved/deduped in merges leave valid bindings and stable survivor identity; loser private data/documents survive trash/restore; inbound relationships and selected avatars stay consistent. Original photos and client-only metadata follow the documented merge policy. Native imports retain private NOTE intent; DAV does not. Full exports retain current authorized fields. Phone/display workers update only changed public representations; private operations publish nothing. Reset invalidates stale sync tokens correctly while other accounts remain unchanged. Test failures after each Multi/file stage and resumable backfill retries.

### G. Migration, client acceptance and documentation

Scope: additive backfill/audit tooling; `docs/carddav.md`, `docs/carddav-client-checklist.md`, `docs/adr/adr-008-carddav-state-in-app-code.md`; relevant `test/playwright/carddav/{03-crud,04-reports,05-vcard,06-ui-crossover,07-perf}.spec.ts` and scripted client harness. Depends on all previous slices and cutover policy approval.

Acceptance: fresh and existing-state migrations, duplicate/ambiguous classification audits, stale clients, rolling-deploy gate and privacy-safe rollback rehearsed. Run focused ExUnit then full ExUnit on the disposable partition; run repository-required quality checks for the actual code change. Run the isolated Playwright and vdirsyncer harness, then native Thunderbird and DAVx5/Contacts UI scenarios, including UUID/avatar retests, NOTE independence, private changes and relationship metadata. Record failures as failures; do not inherit historical acceptance. Never use personal profiles or normal development DBs. No architecture acceptance claim until all agreed gates pass.

## 12. Decisions open at the end of research

- Confirm specialized built-in social types remain private while generic Website is shared. Recommendation: yes.
- Confirm reverse relationship exposure/edit/delete semantics and reciprocal collapse. Recommendation: match the UI view with explicit underlying-edge bindings; block that slice until the destructive semantics are agreed.
- Approve stale-client cutover precondition policy. Recommendation: require a current new-format validator for existing-resource writes at cutover; unconditional compatibility and guaranteed rejection of historical private echoes cannot both be promised with the current protocol state.
- Validate document codec preservation and reversible conversion corpus before selecting a dependency. Exact JSON shape and relational binding alternative depend on that spike.
- Finalize valid-but-unrepresentable shared values, repeated scalar ownership and remote/repeated PHOTO behavior. Recommendation: preserve client-only components, reject invalid updates atomically, never silently truncate, fetch remote images or overwrite private records.
- Validate per-version strong ETags and canonical getetag/REPORT behavior against standards and actual clients. Exact wire tag format is not settled; immutable bytes and private-edit invariance are mandatory.
- Confirm survivor-only client document behavior on merge and whether full Kith exports include DAV-only metadata. Recommendation: preserve loser documents without implicit union; use a separate explicitly named DAV download if needed.
- Deployment topology and existing synchronized accounts are unverified. ADR fresh-install language is not sufficient evidence to skip existing-state migration, stale-client handling or rollback planning.

## 13. Standards and community grounding

[RFC 6352, sections 5.1/5.1.1](https://www.rfc-editor.org/rfc/rfc6352.html#section-5.1) grounds single-card resources, identity scope and negotiated conversion. [Sections 6.3.2.2–6.3.2.3](https://www.rfc-editor.org/rfc/rfc6352.html#section-6.3.2.2) require extension preservation and strong resource validators, with restrictions on returning a strong PUT ETag after transforming submitted bytes. These support the document layer and conservative PUT responses; they do not prescribe Kith's private-field boundary.

[RFC 6350, sections 3–6 and 7](https://www.rfc-editor.org/rfc/rfc6350.html) supplies content-line, parameter, structured value, RELATED and PID/source identity rules. Internal native bindings are an application mechanism; client PID metadata is not permission to address arbitrary Kith rows.

[Sabre's CardDAV client guide](https://sabre.io/dav/building-a-carddav-client/) explains discovery, validators, refetch after transformed writes and stable identities. Its interoperability advice supports retaining both v3/v4 and testing actual client behavior. The architecture, rollout gate and module/schema recommendations above are Kith-specific proposals inferred from the inspected code, not requirements quoted from that guide.


## 14. Implementation log — slice A foundation

Implementation began after the research-only session, on the user's subsequent instruction to use subagent-driven development. Local HEAD and live PR head were rechecked at `a0b2d37`. Two implementation subagents owned disjoint files, followed by an independent review and parent integration/validation. No commits, pushes or PR comments were made.

Added:

- `lib/kith/vcard/document.ex`: an ordered source-version document and property/parameter structures. It preserves groups, raw structured values, repetitions, parameter ordering/spelling and unknown content lines; uses the existing parser's quote-aware scanners; decodes v4 parameter caret escapes; and serializes with CRLF and UTF-8-safe folding. It checks single-card envelopes and version syntax without mapping to native contact fields. Independent review corrected VERSION ordering: v3 may place VERSION later; v4 requires it first. See [RFC 2426 section 4](https://www.rfc-editor.org/rfc/rfc2426.html#section-4).
- `test/kith/vcard/document_test.exs`: 18 tests covering preservation, source versions, quoted separators, repeated parameters, structured values, PHOTO syntax, UTF-8 folds, literal quotes in text values, and malformed input.
- `test/kith/dav/data_boundary_characterization_test.exs`: seven tests reproducing current behavior, including repeated v3/v4 GET/PUT-like cycles growing one custom field to five native fields, custom destination selection, NOTE/gender coupling, private-edit revisions and extras loss. These intentionally passing defect characterizations must be inverted as fixes land; they are not desired product behavior.

Validation used a newly created and migrated `kith_test_boundary_a_20261028` database with `MIX_TEST_PARTITION=_boundary_a_20261028`, after verifying that name did not already exist. Full ExUnit passed **1,979 tests, zero failures**. After a final helper extraction for static analysis, the focused codec/parser/serializer/extras/characterization suite passed **112 tests, zero failures**. Warning-free test compilation, formatting checks and strict Credo for the changed files passed. The disposable database was dropped after validation. Native clients, browser tests and Dialyzer were not run for this non-serving foundation.

This is the codec spike and characterization portion of slice A, not completion of the data-boundary architecture. There is no new dependency, schema migration, serving-path activation, or change to existing imports/exports. Cross-version conversion, persistent occurrence IDs, trusted bindings, shared-field classification and reconciliation remain for later slices. Raw parameter syntax is authoritative for untouched rendering; decoded parameter values are a read view, not a mutation API. Typed value editing and validated property constructors must be designed with the binding layer before it is connected to DAV writes.

The evidence supports extending the existing scanners for a source-version document layer. It does not yet prove that all cross-version conversions can use them without another codec/dependency. The next implementation slice is trusted classification, persistence and projection (B); activation remains gated on unified writes and the open product decisions in section 12.


## 15. Remaining-slice execution record (2026-10-28–29)

The user subsequently requested continued subagent-driven development through the entire plan. Implementation workers owned disjoint registry/schema, rich-document/reconciliation, and relationship scopes; independent review added separate mutation/rollback/snapshot/cutover regressions. Everything remains local and uncommitted. PR head remains the reviewed `a0b2d37`; no push or PR comment was made.

The implemented schema keeps the rich document in `contact_dav.document` JSONB rather than a separate one-to-one table. It includes opaque occurrence IDs, source-version syntax, internal row/PID bindings, group ownership and dormant hidden relationship metadata. A lossless compact array storage codec is exposed as rich maps through `DocumentType`; it also reads older rich JSON documents, with no second authoritative copy. Additional columns hold publication time, representation fingerprint and the existing-install precondition gate. This avoids a new storage owner without changing the ownership contract. Native values remain authoritative; there is no background synchronization.

Trusted immutable system keys, audited historical-seed classification, deterministic destinations and account-scoped projection are implemented. Generic Website is shared; specialized native social types remain private. Forward/reverse relationships use safe trusted categories; equivalent reciprocal rows have a shared view with exact internal bindings. Visible omission removes represented rows, while hidden edges/metadata remain dormant and restore at the same identity. Client-only URI/text relationships never resolve by name. A derived account-scoped `dav_document_references` table tracks UUID dependencies without creating native edges, so later target creation/hiding/restoration updates referring cards atomically. Its migration accepts both rich and compact stored documents.

`Contacts.Write` now coordinates contact/child/tag/avatar operations, native workers/import tag writes, merge, purge/reset/deletion, and DAV PUT/DELETE. Nested operations publish once, after shared comparison. Staged accepted documents avoid persisting an intermediate competing copy; subsequent native commands first flush staged state inside the same transaction, then invalidate it before final recapture. Post-commit callbacks defer geocoding/cache effects and account file deletion, with rollback tests for original/rendition retention. Native reminder reconciliation stays enabled for Kith; DAV-origin birthday changes leave private reminder rows unchanged. New display-name jobs carry the requesting user ID and read the persisted preference under the write lock; pending jobs replace obsolete arguments, while an executing job cannot suppress a follow-up. Legacy jobs without a user ID keep their explicit format rather than guessing an account member.

PUT replaces shared values and client document data, including PHOTO selection, without deleting source photos or private native records. Multiset/PID/type-aware matching preserves unchanged native row IDs/subtypes and additional client metadata. Native field inserts/deletes and property matching are batched/indexed rather than per-row scans. Per-row field validation retains the native changeset while shared SQL constants are supplied once. For fingerprint conversion only, fresh trusted field/address baselines avoid regenerating every native row; actual rendering still reads native values. Explicit authorized imports/exports retain description, gender and custom field access through a separate policy. Merge keeps the survivor document, remaps retained child bindings after native deduplication, and privately archives each loser's pre-merge document. The archive is never a DAV source or validator input and is not unioned into the survivor.

GET/report/query paths use the same sanitized document and a consistent read snapshot with batched relationship/avatar metadata. REV and modification dates use DAV publication time; per-version strong tags distinguish representations. The fingerprint covers the actual syntax of both rendered version views, masking only REV values; lexical-only changes that affect either version therefore advance the revision. A conversion failure is reported per resource during REPORT, while supported resources still return normally. Existing migrated resources permanently require a current explicit variant If-Match for PUT/DELETE, including rejection of wildcard-only and legacy validators. This is a deliberate privacy cutover choice; unconditional-only clients are incompatible with those migrated resources. New-policy resources retain unconditional compatibility and its documented shared-edit overwrite limitation.

`mix kith.dav.audit` provides read-only legacy/current classification and duplicate-candidate diagnostics. `--backfill` synchronously initializes sanitized documents under account locks after migration. Legacy extras remain quarantined, not automatically promoted or deleted. Equal-valued fields are never automatically deduplicated. Unknown original metadata lost by the old codec cannot be recovered. Rollback must retain the new privacy policy or disable DAV; schema downgrade is not an approved recovery shortcut.

Implementation decisions from section 12 are now recorded in code: generic Website is shared while specialized social types stay private; reverse/reciprocal relationship edits operate on represented internal edges and preserve hidden ones; existing rows require current explicit validators; the existing scanners were extended without adding a codec dependency; extra structured/scalar metadata remains client-owned, and unsupported PHOTO updates roll back; version-specific tags use canonical v3 getetag; merge preserves survivor-only client data and private loser archives. Full native exports keep their existing native-field contract rather than silently adding DAV-only metadata. Deployment topology, production classification, and native-client interoperability remain unverified.

Maintained mutation exceptions and entry points:

| Writer | Boundary rule |
|---|---|
| Contacts facades, DAV PUT/DELETE, merge/import, phone/display workers, Monica tag inserts, reset/purge/deletion, avatar backfill | Enter `Contacts.Write` before native shared mutations. Bulk SQL is an implementation detail inside that command, followed by one outer publication. |
| Native private contact/field/type/photo edits through Contacts | Existing authorized APIs remain available; shared comparison suppresses publication when the projection is unchanged. |
| Activities' `last_talked_to`, address geocoding, Immich integration status, notes/reminders/documents and original-photo metadata | Private native maintenance; these values are neither document sources nor DAV revision inputs. Adding a shared field here requires moving its mutation into the coordinator. |
| Account user display preference | Private preference persists normally; the native recompute worker applies resulting shared display-name changes through the coordinator using current persisted preference. |
| Physical file/cache/geocoding side effects | Deferred through `Write.after_commit`; rollback discards callbacks and does not delete account files. Avatar staging keeps its existing rollback cleanup. |
| Classification migrations/seeds and sanitized audit backfill | Offline new-build maintenance under the documented no-mixed-writer cutover. User changesets cannot assign trusted system keys; backfill uses account locks. |

This is the reviewed allowlist for the current tree, not permission for future direct shared writes. Review new `Repo`, `Multi`, SQL, and worker call sites against it.

Execution/validation status:

- Slices A–F: implemented, including regression fixes found by independent review and live browser testing.
- Slice G automated checks: final full ExUnit on the finished source **2,109 tests, zero failures** in 83.4 seconds, using only disposable `MIX_TEST_PARTITION=_boundary_all_20261028`. Before that final run, focused field validation (7), worker/touch coverage (49), and the final codec/validator batch (147) all passed. Standard development-environment `mix quality` **passed, exit 0**, including warning-free compilation, formatting, strict Credo, Sobelow and Dialyzer. The two existing Dialyzer skips remain, with zero unnecessary skips; Sobelow retains existing findings, so this is not a zero-finding security scan. A prior test-environment quality invocation reported existing Wallaby-helper unknown calls; the standard run passed without adding suppressions. The disposable ExUnit database was dropped after validation; the default test database was not reset or migrated.
- Scripted vdirsyncer: final expanded smoke **passed, exit 0**, including private native description/custom-field invariance, client NOTE independence, repeated sync, conflicts, native edits, merge/hide/restore and empty-trash recovery. Evidence: `.carddav-task10/boundary-vdirsyncer-final.log`. The task-owned server, synthetic live-test DB and current temporary storage were safely removed after acceptance; diagnostic/native artifacts remain ignored.
- Live browser: discovery/auth/CRUD/reports and normal read budgets passed; grouped-label and metadata binding issues found live were fixed. The original 987,845-byte large-card test passed after the final canonical-template optimization: first PUT **3,947 ms**, unchanged PUT **4,109 ms**, GET **1,470 ms**, each below the unchanged five-second limit. The final full live suite then passed **106 tests, one expected TOTP skip, zero failures** in 2.8 minutes. In that full run the dense-card first/unchanged PUTs took **4,237/3,675 ms**, GET **1,368 ms**; all original read budgets also passed (PROPFIND 172 ms, initial sync 2,377/2,275 ms, 200 multiget 123 ms, single-match query 437 ms, single GET 88 ms). Performance measurements use warning-level server logging; payloads and assertions were not weakened. Earlier 7,224/5,045 ms failures remain recorded, rather than being counted as passes.
- Fresh native attempts on 2026-10-29: Thunderbird's shared-app updater path was stopped safely; a disposable application copy then stalled before profile initialization. The personal profile/process and shared installation were preserved. Pixel_7/Android 14 booted, but System UI repeatedly ANRed over DAVx5 4.5.21; UI Automator returned no root node. A bounded Wait/relaunch failed, and the emulator was stopped without wiping/saving over its state. No new native scenario is marked passed. Evidence is retained under ignored `.carddav-task10/boundary-native/`.

Native-client acceptance is an external release gate still open. Historical client tables do not establish acceptance of this revision. Production classification/data review, backup and explicit deployment remain operator work; this session changes no production state.


## 16. Thunderbird recovery and independent community testing (2026-10-29)

The user requested repairing Thunderbird and retesting, or running an existing
community CardDAV harness. A fresh official, signed Thunderbird **153.6.0esr**
ran from a read-only DMG with an isolated profile and native Marionette automation.
The shared Thunderbird 158 installation/personal process remained untouched.
The original copied-158 dyld stall's exact cause is still unproven; the successful
recovery uses a clean ESR build rather than claiming that shared 158 was repaired.

Actual native discovery uncovered a server defect: the Depth 1 home listing's
address-book child returned an empty `current-user-privilege-set` in a 404
propstat. Thunderbird interpreted that node as ACL metadata and hid the book.
`CardDAVPlug.handle_home_propfind` now advertises the same existing privileges
as the direct book response. This changes discovery metadata, not authorization.
The new regression compares the child's 200/read/write metadata with the direct
book. The focused PROPFIND suite passed **64 tests, zero failures**, and standard
`mix quality` passed with the existing two Dialyzer skips and existing Sobelow
findings. The disposable test partition was recreated for those checks and
dropped afterward; the default database was not reset or migrated.

Fresh targeted native scenarios then passed: normal root-URL discovery and
initial two-card sync; canonical UUID/href and selected-photo preservation;
forward/reverse relationship references; native UI name/phone/NOTE edits;
two no-op syncs preserving exact bytes/ETag/unchanged row identities; private
Kith description/custom EMAIL-mimic edits preserving exact DAV state and NOTE
independence; shared Kith phone/company edits appearing in Thunderbird; and
native deletion followed by Kith restore at the same UUID/href without duplicates.
The selected photo decoded in the native UI at 480 × 480. Evidence, launch
commands, signed-download provenance, assertions and screenshots are in ignored
`.carddav-task10/boundary-native/esr-retry/RESULTS.md`. This is native vCard 3
acceptance on ESR 153.6, not a rerun of the historical full conflict/auth/sync-floor
matrix or proof for vCard 4 preference, Thunderbird 158, Android or Apple Contacts.

The new [community runner](../../scripts/carddav-e2e/community-test.sh) executes
pinned, **unmodified** Apple CalDAVTester scripts using official private PyPy 2.7.
It guards the dedicated local endpoint/account and preserves original assertions,
logs, JSON results and failure exit status. The actual reproduced baseline is
**26 passed, 62 failed, 5 setup errors, 22 ignored; exit 67**. Many failures stem
from CalendarServer-specific facilities and non-UUID fixtures outside Kith's
agreed policy; two malformed PROPFIND cases are separate validation gaps left
open. Full conformance is not claimed. See [reproduction and triage](../carddav-community-testing.md).

## 17. Remaining correctness and interoperability plan (2026-10-29)

This is the active implementation plan, rewritten after the read-only simplicity
review. Section 15 describes the implemented architecture. Sections 2–13 are
historical proposals and alternatives; they are not additional requirements or
authority to add the separate document table originally proposed there. Sections
14–16 and the execution records below retain actual evidence. At the time of
the rewrite, no cleanup or architectural simplification had been implemented. The execution record at the end of this section supersedes
that status for the slices explicitly listed there.

HEAD remains `a0b2d3708f6d204e2853b464f68cd3a475163aa3` with substantial local,
uncommitted implementation. Preserve all existing work. No commit, push,
deployment or PR comment is authorized. The two confirmed request defects are
already fixed; they are completed work, not the next implementation slice.

### Scope and retained design

Keep both vCard 3.0 and 4.0, the explicit shared/private boundary, native shared
ownership, one authoritative PostgreSQL client document, account-before-row
locking, atomic publication, private/no-op byte and validator invariance,
replacement PUT semantics, unchanged native row IDs/subtypes, identity reservation,
preconditions, sync floors and compensating avatar cleanup. Client NOTE/GENDER
remain independent of native private fields. No CalDAV or background copy sync.

Retain `SharedContact`, the trusted registry, native bindings and merge remaps,
private loser archives, dormant hidden-relationship metadata and the derived
reference index. Their responsibilities follow existing requirements. Retain
`DocumentIndex`, fingerprint templates, compact persistence and occurrence-ID
preservation until measurements justify a change. In particular, dropping the
occurrence-ID preservation pass alone would generate new IDs and unnecessary
JSONB writes on unchanged PUTs; category/group bindings and codec compatibility
also depend on those IDs. A shorter implementation must preserve behavior.

### Execution order

1. Remove duplicate mutation tracking and unused paths.
2. Consolidate PID/source identity interpretation.
3. Add the staging/dependency regression; fix any reproduced correctness issue.
4. Evaluate transactional document persistence and direct property generation
   separately, adopting either only after its correctness and performance gates.
5. Implement the minimum required ACL/report and property-processing behavior,
   with truthful capability discovery and a correctly configured test profile.

A reproduced correctness defect takes precedence over cleanup. Optional measured
refactors must not delay required compliance fixes if they fail their gates.

### A. One owner for mutation tracking — first cleanup

**Scope:** `contacts/write.ex`, `contacts.ex`, phone/display-name workers and
`address_object.ex`; existing write, touch, lifecycle and concurrency tests.
No schema change. Depends on verifying each call site's coordinator coverage.

`Write.run/3` already prepares affected contacts and discovers dependencies before
and after mutations. Remove superseded `touched`, `touched_rows`, `touched_contact`
and manual relationship-owner queries from paths fully owned by that command.
Remove repeated prepare/touch calls inside coordinated workers. Keep preparation
of newly discovered current owners when stale child structs can have moved;
that is not redundant. Keep explicit marking for raw/bulk `Store.transaction`
paths until their coverage is demonstrated. Do not remove `Store.touch` globally.

Flatten redundant wrappers such as `clear_avatar` while retaining necessary
fresh reads/row locks, return shapes and file handling. Delegate identical
`delete_tag_with_removal` behavior to one implementation. Remove the unused
`relationships_only` projection branch and the unused address-object `extras`
argument. Avoid a new generic command framework for these local cleanups.

**Acceptance:** existing native-write/touch coverage passes for creates, moves,
deletes, tags, workers, reverse relationships and hidden targets. Shared changes
publish once at outer commit; private/no-op edits preserve bytes, ETag, REV and
DAV time. Rollback leaves DB and files unchanged. Verify affected IDs before
removing a query; fewer queries alone does not establish correct coverage.

### B. One PID/source identity implementation — next cleanup

**Scope:** `property_identity.ex`, `document.ex`, `field_reconciler.ex` and their
existing tests. Independent of A; land as a separate reviewable slice.

Share CLIENTPIDMAP source-table construction and PID extraction through the
existing `PropertyIdentity` module. Return explicit errors that callers translate
to their transaction outcomes. Today reconciliation rejects conflicting source
indexes while document matching uses last-value-wins `Map.new`; eliminate that
inconsistency. Keep native row matching and document occurrence matching separate.
Avoid another public representation or a general-purpose identity framework.

**Acceptance:** conflicting source indexes fail atomically; equivalent URI/UUID
sources, renumbered/reordered PIDs, duplicate values and ambiguous identities
retain correct behavior. Unchanged native rows and client metadata remain bound
to the same values. Exercise both source versions and conversion round trips.
The review established inconsistent code paths, not an externally reproduced
mutation defect.

### C. Staging correctness regression — before changing cache design

**Scope:** `contacts/write.ex`, `store.ex`, native relationship commands and
`data_boundary_write_test.exs` / `write_service_review_test.exs`.

Add this transaction regression: accept/stage B's DAV document, then create a new
A→B relationship when no prior edge connects them. Preparation for A cannot find
B through the new edge yet; post-mutation discovery currently marks new dependencies
without necessarily invalidating their staged documents. Check that B's committed
document, both rendered versions and fingerprint represent the final native
state. A subsequent private/no-op B edit must publish nothing. Check rollback
and the analogous creation of a client-reference dependency where applicable.

This is a **source-derived hypothesis, not a confirmed bug**. If it reproduces,
fix the smallest dependency/invalidation boundary first. Retain the regression
even if a later simplification removes the cache. Do not change assertions to
accept a spurious publication.

### D. Two measured document simplifications — optional implementation choices

**D1: accepted document persistence.** Scope `contacts/write.ex`, `contacts.ex`,
`store.ex`. After C, evaluate writing the accepted client document inside the
existing account-locked transaction, then capturing current native values at
final publication. This could remove process-local staged contact/document pairs
and their invalidation/flush lifecycle while retaining one committed authority.
Do not add a second document table or a background reconciliation process.

Gate on nested DAV/native commands, metadata survival, new/deleted dependencies,
rollback, exact no-op state and original first/unchanged-PUT budgets. Measure
extra JSONB writes and regeneration. If the simpler lifecycle misses those
budgets, retain staging with explicit invalidation rules and the new regressions.

**D2: generate properties directly.** Scope `dav/document.ex`,
`vcard/serializer.ex`, `vcard/document.ex` and serializer/document/export tests.
The current generated path serializes native values to folded text, reparses
that text and reconstructs positional binding queues. Evaluate a shared property
builder beneath the existing serializer so native properties carry bindings
without that intermediate wire round trip. Keep the existing full-export API
and its private-field policy; do not introduce a second native serializer.

Gate on exact output parity in both versions, ordering, groups, TYPE/PID metadata,
PHOTO, categories, relationships, private-field negatives and conversion errors.
Benchmark against the original 987,845-byte, 50,000-EMAIL payload and unchanged
thresholds. Evaluate D1 and D2 separately so results identify which change helped
or regressed. Neither change is preapproved as an improvement without evidence.

### E. Dedicated account wipe — bounded lifecycle cleanup

**Scope:** `contacts/cleanup.ex`, account-reset/deletion workers and existing
cleanup/storage/floor tests. Coordinate with A; keep separate from document refactors.

Evaluate one account lock and one floor advance for an entire successful wipe,
with direct batched deletion. Avoid preparing/capturing documents immediately
before deleting every contact. Reset already has an outer account transaction;
make the standalone cleanup contract explicit so the shortcut cannot leave
partial state or expose concurrently created contacts. Preserve storage-key
enumeration before cascades and physical deletion after commit. Ordinary purge
of selected contacts still needs surviving-neighbor publication.

**Acceptance:** standalone cleanup and reset are account-scoped and atomic;
rollback preserves original/rendition files, old tokens become invalid, other
accounts are unchanged, and reset/delete races remain serialized. Verify removal
of all same-account contacts before omitting neighbor work. Do not extend this
into a storage subsystem rewrite.

### F. Minimum required protocol compliance — bounded feature work

**ACL, principals and reports:** scope existing auth/policy, DAV routing/XML and
new ACL/principal/report tests. Inventory RFC 3744 requirements and RFC 6352
`DAV:expand-property`, then implement them against existing account roles.
Evaluate role-derived protected ACEs first. An editable ACL database, sharing,
delegation and arbitrary inheritance are separate product decisions; they are
not prerequisites to begin principal discovery and required report work. Verify
whether each proposed restriction is permitted before claiming conformance.

Audit OPTIONS and resource-level capability properties against implemented
methods. Class 2 is currently advertised without LOCK/UNLOCK support. Correct
unsupported claims; do not implement locks just to preserve that token. CardDAV
requires class 3 and ACL support. Existing privilege discovery does not establish
full ACL support. Test admin/editor/viewer, a second real user, an unrelated
account, unauthenticated access, protected ACE errors and resource-specific reports.

**PROPPATCH processing:** scope existing parser/dispatcher/builder and tests.
First specify protected/live/writable properties and implement proper instruction
processing, document order, atomicity and dependent failures on DAV resources.
Preserve existing policy. Arbitrary dead-property storage is SHOULD under RFC
4918 §9.2; decide whether to implement it separately before adding its persistence
schema. Book display-name editing needs an explicit product/storage contract.
If storage is added, preserve namespaces/XML values, account isolation and
PROPFIND readback. A blanket error stub is not proof of complete processing.

### G. Reliable evidence and deferred decisions

Before using the Apple suite to assess a new feature, reserve exclusive ownership
of the dedicated harness and start with fresh/resettable DB/storage. Keep the
pinned untouched baseline. Any Kith-specific profile must be separately named
and list capability, path and setup adaptations. Use distinct real users/accounts
for ACL coverage; same-account aliases cannot establish those semantics. Preserve
upstream assertions and fixtures. Record setup failures and cascades explicitly.
The U+FFFD fixture is valid UTF-8; test malformed bytes separately.

Keep these separate from implementation defects:

- **Recommended expansion:** extended MKCOL, dependent on deciding multiple books,
  membership, permissions, default-book deletion and token scope. No new book schema yet.
- **Optional functionality:** collection GET/HEAD representations and associated
  size properties, dependent on defining an actual representation.
- **Intentional restrictions:** UUID-only UIDs and the fixed book. General vCard
  permits opaque/Apple ABPerson UIDs; changing that restriction needs an identity,
  reference and migration decision. Preserve new-resource unconditional PUT and
  numeric sync-floor/restore limitations until explicitly revisited.
- **Client/release gates:** native v4 preference, Android/Apple Contacts, Thunderbird
  158 and the full conflict/auth/sync-floor matrix. Historical native acceptance
  remains scoped to its recorded scenarios. TOTP/app-password work and pre-auth
  chunked parsing remain separate security/auth backlog, not removed by simplification.

### Validation and completion rules

Run focused existing tests for each slice, adding regressions for newly identified
behavior rather than tests that mirror helper structure. After the chosen changes,
run full ExUnit on a newly verified unused disposable partition and normal dev
`mix quality`. Never reset or migrate default dev/test databases. Verify database
name/ownership before creation/removal and coordinate all live-harness use.

For D, rerun original dense-card and applicable read budgets; preserve payloads
and thresholds. For shared protocol/write changes, rerun appropriate Playwright
and vdirsyncer checks, then native gates where relevant. Record actual results,
remaining failures and limitations. Existing passes below are historical evidence
for the current implementation, not acceptance of this revised plan.

Standards: [RFC 4918 §§14.20/17](https://www.rfc-editor.org/rfc/rfc4918.html#section-14.20)
for the completed selector fix; [RFC 6352 §6.2.2](https://www.rfc-editor.org/rfc/rfc6352.html#section-6.2.2)
for the completed media precondition; [RFC 6352 §§3/8.1](https://www.rfc-editor.org/rfc/rfc6352.html#section-3)
and [RFC 3744](https://www.rfc-editor.org/rfc/rfc3744.html) for required ACL/report
support; [RFC 4918 §9.2](https://www.rfc-editor.org/rfc/rfc4918.html#section-9.2)
for property processing versus recommended dead-property storage. No full
conformance claim follows from plan completion without the corresponding evidence.

### Implemented result and current evidence

The completed request-validation/error-response slice (formerly P0) is implemented
locally in the request layer and tests. The selector parser
uses the existing safe namespace-aware tree parser to validate only direct
recognized selectors; unknown extension subtrees cannot inject instructions.
It rejects missing/conflicting/duplicate selectors, invalid include combinations
and direct text values, while preserving empty-body behavior, property namespaces
and extension tolerance. `allprop`/`include` renders available properties once
and explicit missing properties in 404 propstats. PUT media rejection now uses
the existing XML precondition builder and DAV response helper.

HTTP **415 is retained deliberately**. RFC 6352 §§6.2.2/6.3.2.1 requires
`supported-address-data` without fixing the status at 403. RFC 4918 §16 says the
error body does not replace correct HTTP semantics, and [RFC 9110 §15.5.16](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.16)
defines 415 for unsupported Content-Type. The original upstream verifier still
expects 403; its structured-error defect is fixed, but a new upstream pass is
not claimed and its assertions remain untouched.

Recorded validation on the completed request slice's final source:

- Focused parser/PROPFIND/address-object suite: **161 tests, zero failures**,
  7.4 seconds, exit 0. Covers invalid requests at all five supported resource
  paths, extensions/include, v3/v4 and legacy media acceptance, rejected creation,
  and rejected update preserving the stored native/DAV record and exact GET
  bytes/ETag. Log: `.carddav-task10/correctness-focused-20261029.log`.
- Full ExUnit: **2,118 tests, zero failures**, 43.3 seconds, exit 0, using only
  `MIX_ENV=test MIX_TEST_PARTITION=_carddav_correctness_20261029`. Normal wallaby,
  external and slow exclusions remain. Log:
  `.carddav-task10/correctness-full-exunit-20261029.log`.
- Normal development-environment **`mix quality` passed, exit 0**: compilation,
  formatting, strict Credo, Sobelow and Dialyzer. The existing two Dialyzer skips
  remain, with zero unnecessary skips. Sobelow still reports existing findings;
  this is not a zero-finding security scan. Log:
  `.carddav-task10/correctness-quality-20261029.log`.
- `git diff --check` passed. Independent read-only review checked selector
  cardinality, extension subtrees, include rendering and remaining compliance
  priorities. Review identified direct property text acceptance; the narrow text
  validation/regression was added before the final focused/full checks.
- An initial new media regression sent vCard bytes as `application/json` and
  failed in Phoenix's JSON parser before reaching DAV. It now sends the same
  valid vCard as unsupported `text/plain` to exercise the intended DAV rejection;
  assertions on status and unchanged state were retained. No upstream fixture,
  verifier, performance payload or threshold was modified.

The new disposable database was verified absent before creation. After tests,
its exact name/owner and absence of active connections were verified before
removal. Neither the default database nor the live harness was reset/migrated.
No new Playwright, native client, performance or community run occurred; prior
passes remain historical. The revised follow-up slices above are not completed
features or claims of full conformance. All changes remain uncommitted; no PR write,
push or deployment occurred.


### Subsequent requested Apple rerun

On 2026-10-29 at 12:50 UTC the pinned unmodified Apple CardDAV baseline was
rerun against fresh dedicated harness DB/storage: **28 passed, 60 failed,
5 setup errors, 22 ignored; exit 65**. Both PROPFIND error checks now pass.
The media check now receives the required XML precondition but still rejects
Kith's 415 because its verifier expects 403. The three valid-U+FFFD fixture
checks still fail, now on accepted 201/204/204 rather than reserved-href 409s.
All other result/failure details match the historical baseline. No verifiers,
fixtures, feature flags or path/user substitutions were changed. The existing
same-account alias/path/capability limitations remain; full conformance is not
claimed. See the [rerun evidence](../carddav-community-testing.md#fresh-state-apple-baseline-rerun-2026-10-29-1250-utc).
Task-owned server/database/current temporary storage were cleaned up afterward.
This supersedes the preceding statement that no new community run occurred;
no new native, Playwright or performance run is claimed.


### Revised-plan execution (2026-10-29, local uncommitted follow-up)

Workers used disjoint ownership for A, B, account wipe, and protocol modules;
the primary agent integrated shared Write/Store/request paths and exclusively
managed all test databases and live clients. Independent read-only reviews
covered A/B, C, wipe/property processing, and protocol behavior. All pre-existing
uncommitted implementation remains present. HEAD is unchanged; no commit, push,
deployment, PR comment or personal Thunderbird change occurred.

Completed slices and bounded protocol work:

- **A:** coordinated contact/child/tag/relationship/avatar commands and phone/
  display-name workers no longer duplicate tracking already owned by Write.run.
  Tag membership is discovered once under the account lock; identical deletion
  paths delegate. Stale moved child owners still receive preparation. Raw/bulk
  explicit marks remain. Avatar fresh locking/return shapes and file callbacks
  remain; unused address-object extras and relationships-only projection removed.
- **B:** PropertyIdentity now constructs source tables and extracts PIDs for both
  document and native matching. Conflicting source indexes reject atomically,
  including real v3/v4 PUTs with unchanged native/document state. Matching remains
  separate for native rows and occurrence IDs. Existing codec, indexes, reference
  metadata, private archives and merge remaps remain intact.
- **C confirmed and fixed:** accepting B then creating a previously absent A→B
  edge reproduced a stale **stored** B document (27-test reproduction: one
  failure). Newly discovered post-mutation dependencies now invalidate staged
  representations while retaining accepted client metadata inside the transaction.
  Regression coverage checks stored documents, both versions, fingerprint,
  ETags/REV/time invariance on subsequent private/no-op edits, rollback, moved
  children, and unknown URI references followed by hidden-target creation. The
  URI scenario did not reproduce a second defect. An unchanged PUT regression
  also verifies no document JSONB UPDATE, preserving occurrence-ID behavior.
- **E:** standalone account wipe is one account-locked transaction with one floor
  advance and direct batched deletion, without initializing doomed documents.
  Tests cover multiple batches, isolation, rollback/files, atomic visibility and
  serialized concurrent creation. Storage enumeration must precede cascades in
  the same outer transaction; physical deletion stays after commit. Ordinary
  selected-contact purge still publishes surviving neighbors.
- **F implemented subset:** distinct account-scoped user principals and derived
  role-group principals; protected role ACE/property discovery; granular current
  privileges; ACL principal-property, principal-match, principal-property-search,
  principal-search-property-set and expand-property reports. Searches support
  displayname; unsupported fields return an explicit extension error. Local-only
  nested expansion is bounded and honors Depth 0/1/infinity; ACL reports require
  Depth 0. Descendant matching includes cards beneath home/root collections.
  Report advertising is resource-specific. Class 2/locking claims are removed;
  no access-control compliance token is claimed. Permission errors name the
  actual property/content/bind/unbind/ACL privilege and appropriate resource.
  PROPPATCH parses ordered set/remove instructions and XML values, preserves
  repeated instructions, reports protected failures plus atomic dependent 424s,
  and treats absent dead-property removal as a successful no-op. Unsupported
  dead-property sets fail without falsely calling them protected live properties.
  All existing DAV resources receive existence/role checks and unchanged-state
  tests. Book displayname and live properties remain protected.

**D1 evaluated; staging retained.** An isolated direct-persistence prototype
passed 96 focused tests and the original dense-card five-second limits, but
first/unchanged PUT took 4,060/4,492 ms, GET 1,110 ms. Restoring staging with C's
fix, on the same task-owned PostgreSQL/server setup and warning-level logging,
took 3,253/3,249 ms, GET 1,122 ms. These are single-run observations, not a
statistical benchmark; the prototype reduced write headroom materially. Its
additional accepted-document persistence and final regeneration were not adopted.
The exact pre-prototype source was restored. Logs:
`.carddav-task10/revised-d1-focused.log`, `revised-d1-performance.log`,
`revised-retained-performance.log`. Payload remained 987,845 bytes with 50,000
EMAIL properties; thresholds/fixtures were untouched.

**D2 deferred separately.** Source review identifies the wire serialization/
parse/positional-binding round trip, but replacing it requires a shared serializer
property-construction API and full native-export/privacy and version-conversion
parity. No direct-builder prototype or improvement is claimed. Existing generation,
fingerprint templates, compact codec and occurrence preservation are retained;
the original live gates validate that retained path, not the optional design.

**Remaining F/product/release decisions:** protected derived ACLs do not establish
all RFC 3744 requirements, including general user/group grant-ACE support. No role
receives write-acl; actual protected-role changes report no-protected-ace-conflict,
other well-formed ACL requests report need-privileges/write-acl. Editable ACLs,
sharing/delegation, generic dead-property storage, writable book displayname and
multiple books were not invented. Full ACL/CardDAV conformance and production
acceptance remain open. Native v4 preference, Thunderbird 158, Android/Apple and
the full native conflict/auth/sync-floor matrix remain release gates. Existing
TOTP/app-password, chunked-auth and numeric-token limitations are unchanged.

Validation of the final retained implementation:

- Focused A/B/C: 149 tests, zero failures; protocol/wipe batch: 137, zero failures.
  Subsequent URI/move/HTTP PID/Depth/JSONB regressions are included in the final run.
- **Full ExUnit: 2,175 tests, zero failures**, 34.2 seconds; normal wallaby/external/
  slow exclusions. Log `.carddav-task10/revised-full-exunit-final.log`.
- **Normal development mix quality passed**, including strict Credo and Dialyzer.
  Two existing Dialyzer skips, zero unnecessary skips; existing Sobelow findings
  remain. This is not a zero-finding security scan. Log
  `.carddav-task10/revised-quality-final.log`. Formatting/diff whitespace checks pass.
- Initial live run: 94 passed, one failed, 11 not run, one expected TOTP skip;
  the failure was Kith's obsolete global-Allow assertion. Kith-only discovery
  assertions now verify resource methods and canonical distinct-user principal
  URLs; no upstream assertions or performance thresholds changed. Initial
  performance gates all passed. Final live/client results are recorded below.

The Docker development PostgreSQL was unhealthy and could not fork connections;
read-only diagnostics showed VM process exhaustion in unrelated containers. It
was neither restarted nor altered. A separate task-owned Homebrew PostgreSQL 17
instance bound to 127.0.0.1:55439 supplied only a newly verified unused
`kith_test_carddav_revised_20261029_01` partition and the dedicated live-harness
`kith_carddav_task10_e2e` database. Exact names/owners were checked before creation.
No default development/test database was reset or migrated. The normal-dev
quality command used its ordinary environment. Database teardown and final live
results are recorded below once complete.


Final live validation and teardown:

- **Playwright: 106 passed, one expected TOTP skip, zero failures**, 2.5 minutes,
  exit 0. `.carddav-task10/revised-playwright-final.log`. All original budgets
  passed: PROPFIND 198 ms; initial sync 1,395/1,444 ms; 200 multiget 103 ms;
  single-match query 392 ms; single GET 77 ms. The unchanged 987,845-byte dense
  card with 50,000 EMAILs took **2,850/3,232 ms** first/unchanged PUT and
  **1,113 ms** GET. No threshold or performance fixture changed. Repeated dense
  runs left trashed performance cards during this task; these observations are
  same-task threshold checks, not a controlled improvement over historical Docker
  measurements. Final server logging was warning-level.
- **Vdirsyncer passed, exit 0**, including private native invariance, independent
  client NOTE, repeat synchronization, conflicts, native shared edits, hide/
  restore and hard-delete-floor recovery. `.carddav-task10/revised-vdirsyncer.log`.
- No new native or Apple community run occurred. The original pinned tester and
  PyCalendar repositories still match their documented revisions and have clean
  tracked worktrees; untouched baseline artifacts remain. No existing native
  client result is promoted to acceptance of the changed principal discovery.
- Verified task-owned server command/cwd before stopping it. After all test and
  live clients exited, verified both exact database names, owner `postgres` and
  **zero connections**, then dropped only those two databases. Current newly
  allocated harness storage was removed and the task-owned PostgreSQL instance
  stopped. The shared Docker stack and default app databases remain untouched.
  Homebrew PostgreSQL 17 was installed for this isolation workaround; its package
  and Homebrew-managed dependencies remain installed, with no login/background
  service enabled by this task. The separately created task cluster was removed.

All final checks above ran against the restored staging implementation with the
C fix and completed protocol changes. D1's rejected trial is not in the final
source. D2, complete ACL conformance, writable-property/product choices and native
release gates remain explicitly deferred rather than counted as implemented.


### Subsequent publication authorization

After the implementation and validation above, the user explicitly authorized
committing and pushing the preserved working tree to the existing PR branch.
Earlier no-commit/no-push statements record the boundaries of the implementation
session; they are superseded by this subsequent authorization. The deferred
features and validation limitations remain unchanged.
