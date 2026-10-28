# Real CardDAV client checklist

Historical native run on 2026-10-23 against a fresh isolated harness at port 4527, never the
normal development database. Scripted vdirsyncer results are separate from
actual application UI observations below. Local screenshots and request logs
are ignored under `.carddav-task11/`. Follow-up validation for the UUID and
avatar changes is recorded at the end; the historical native results do not
establish native-client acceptance of those later changes.

## Setup

1. Run `scripts/carddav-e2e/up.sh` and source `.carddav-task10/env`.
2. Thunderbird: launch the installed application with a new explicit disposable
   `-no-remote -profile <test-directory> --marionette --remote-allow-system-access`.
   Open Address Book → Add CardDAV Address Book. Enter only
   `http://127.0.0.1:4527/`, the seeded admin email and password. Use no personal
   profile. The bundled legacy CardDAV setup dialog was used in this run.
3. Android: start the existing Pixel_7 AVD without wiping it. Install the free
   official DAVx5 OSE APK if absent. Grant Contacts permission. Add an account
   with URL `http://10.0.2.2:4527/`, select categories for contact groups, enable
   Kith Contacts synchronization, and select that account in Android Contacts.
4. Use dedicated contacts for destructive/conflict scenarios. Record actual
   request status and UI behavior, including client limitations.

Thunderbird UI was controlled through its own Marionette chrome DOM and native
prompt controls. Nested XUL address-book controls required DOM click/input
interaction because Marionette cannot switch into that browser. No address-book
storage API populated or edited contacts. Screenshots are Gecko-rendered window
captures. Android used actual UI Automator locators, ADB taps/text input and
native emulator screenshots. Kith-side UI actions used Playwright browser forms.

## Versions

| Client | Version / build | Date |
|---|---|---|
| Thunderbird | 158.0, build 20261008005236 | 2026-10-23 |
| Android | 14 / API 34, Pixel_7 AVD, ARM64 Google Play image | 2026-10-23 |
| DAVx5 OSE | 4.5.21-ose, versionCode 405210002 | 2026-10-23 |
| Google Contacts | 4.8.17.529259023, versionCode 3016392 | 2026-10-23 |
| vdirsyncer (scripted) | 0.21.0 | 2026-10-23 |

Earlier prerequisite inspection found Thunderbird 153.0.3; the installed bundle
reported 158.0 when launched for this run. No application update was requested
by this test. The already-running personal Thunderbird process was preserved.

## Scenario results

All scenarios below were executed. PARTIAL records a native UI limitation;
FAIL records an unmet expectation, including observed client behavior.

| Scenario | Expected | Thunderbird 158.0 | DAVx5 + Contacts |
|---|---|---|---|
| S1 root URL discovery | One book discovered and added | PASS: Kith Contacts only | PASS: Kith Contacts only |
| S2 rich seed | Names, phones, emails, address, yearless birthday, photo, tags; hidden absent | PARTIAL: birthday originally showed 1604; fixed export and UI retest shows July 14. Photo loaded; native category display unavailable, categories retained in cards. Hidden absent. | PASS: July 14 without year, labels, photo, address, phone/email; hidden absent |
| S3 client create | Same fields appear in Kith UI | PASS: Thunderbird UI Test, email/phone verified | PASS: Android UI Test, email/phone verified |
| S4 client edit | Changed phone/note; unmapped properties survive GET | PASS: phone/note in Kith UI; separate Related Seed custom-property UI write retained X-CUSTOM1 on GET and refetch | PASS: phone/note in Kith UI; no unmapped property emitted by this edit |
| S5 Kith phone and tag rename | Client shows changes after sync | PARTIAL: phone visible; renamed CATEGORIES retained on wire, native category display unavailable | PASS: changed phone and Client Friends Final label visible |
| S6 client delete | Kith trash contains contact | PASS: DELETE 204; Kith trash row | PASS: native Delete confirmation, DAVx5 DELETE 204, Kith trash row |
| S7 Kith trash and archive | Both disappear | PASS: both removed after normal sync | PASS: Archived Seed trashed and Related Seed archived; Contacts list changed from three to one |
| S8 edit stale trashed contact | 409, no recreation; describe conflict UI | PASS: PUT 409, no recreation; local stale edit remained visible until sync, no explicit conflict dialog | PASS: stale changed-phone PUT received 409, contact remained in Kith trash. No explicit conflict dialog in account screen; notifications disabled |
| S9 concurrent edits | 412/refetch or visible conflict, no silent loss | FAIL: unconditional PUT omitted If-Match, returned 204 and overwrote Kith phone without warning | PASS: stale If-Match PUT received 412; client refetched server card |
| S10 empty trash | Full resync; no duplicates/resurrection | FAIL: receives 403 valid-sync-token but repeats the stale token; no automatic full resync, new server contacts remain absent | PASS: token 118 received 403, empty-token initial REPORT received 207; one Archived Seed remains, deleted contact absent and no duplicates |
| S11 restore | Reappears at same identity | PASS: Kith restore then normal sync before floor invalidation | PASS: Kith restore then normal sync reappeared once at same UID |
| S12 wrong then correct password | 401, after 10 failures 429, recovery after window | PASS: 401/429 through setup UI; after natural five-minute window correct password authenticated (existing book already added) | PASS: viewer-only setup produced 401 and 429; after fixed window expired, correct password reached account Finish screen |

Thunderbird S10 also fails: its installed sync implementation only restarts on
HTTP 400 and does not recover from the standards-required 403 `valid-sync-token`.
Repeated synchronization reused the rejected token. Removing and re-adding
only the isolated test book through the UI recovered the current server data.
One book remained after removing an extra local setup result; this manual
recovery does not satisfy automatic full-resync expectations.

Thunderbird S9 is a client limitation: the captured request contains no
`If-Match`. The server supports standard unconditional PUT and cannot infer the
revision the client edited. Kith enforces 412 when a client supplies a stale
precondition. Enforcing a new mandatory precondition would prevent all edits
from this Thunderbird version.

## Scripted client

Run `scripts/carddav-e2e/vdirsyncer-smoke.sh`. It covers discovery, local
create/edit/delete, application phone/tag changes, trash/archive, restore,
empty trash and idempotent repeated synchronization. The application helper
refuses any database except the isolated harness database and uses Contacts
functions, including DAV revision touches. The empty-book deletion safeguard
requires `--force-delete` only for the explicitly emptied isolated test book.
The CLI's configured local-wins conflict resolution is not a UI conflict test.

## Local evidence and validation

The ignored `.carddav-task11/` directory retains the stopped dedicated
Thunderbird profile, UI harnesses, native screenshots, `clients-wire.log` and
`clients-status.log`. `android-s10-wire.log` and `android-s10-status.log`
isolate the final 403 → empty-token 207 recovery. Screenshots include
`tb-s2-birthday-fixed.png`, `tb-s9-after-save.png`,
`tb-s10-stuck-old-token.png`, `tb-s10-manual-single-book-recovered.png`,
`android-s9-contact-after-sync.png` and `android-s10-full-resync-final.png`.
Auth recovery evidence is `tb-s12-natural-recovery.png` and
`android-s12-natural-recovery.png`.

The Thunderbird birthday screenshot crops the full field; it is supporting
evidence for the recorded UI observation and corrected wire format, not
standalone proof of the complete displayed birthday. The final fix wave did
not rerun native-client UI scenarios.

Prior validation on fresh isolated seed: affected Playwright `05-vcard` **19
passed**, expanded vdirsyncer **all steps passed**, full ExUnit **1897 tests,
0 failures**. `mix quality`, format checks and warning-free compilation passed.
These automated results do not change the recorded Thunderbird failures.

## UUID and avatar follow-up (2026-10-28)

The follow-up restricts DAV identities to UUIDs, removes duplicate birthday
output, fixes PHOTO filtering, and processes selected avatars into bounded
square JPEGs. Original timeline photos remain unchanged. A rendition registry
preserves accounting and backfill behavior when merges deduplicate source rows.

- Final ExUnit run: **1954 tests, 0 failures**. Tests cover identity and birthday
  regressions, PHOTO filtering, real image decoding/cropping/orientation,
  transactional file cleanup, quotas, both merge choices, source deletion,
  restored snapshots and resumable backfill.
- `mix quality`: exit 0, including warning-free compile, formatting, strict
  Credo and Dialyzer. Two existing Dialyzer warnings remain skipped, with zero
  unnecessary skips. Sobelow still reports existing findings; this is not a
  zero-finding security scan.
- Fresh disposable database creation and all migrations passed; the disposable
  database was dropped. UUID migration up/down and invalid/colliding identity
  preflight have separate regression coverage.
- Production Docker build and an in-container image-processing smoke passed:
  a 1200 × 800 source produced a 512 × 512 JPEG of 4708 bytes.
- Real-browser acceptance exercises keyboard repositioning, EXIF orientation,
  upload, selection of an existing timeline photo, save/reload, cancel without
  mutation, preservation of original dimensions, and the decoded DAV PHOTO.
- A separate collaborative-browser session also uploaded and saved an avatar;
  an existing 24 × 24 source remained 24 × 24, confirming no upscaling. Running
  the backfill twice for that account reported one normalized avatar and zero
  failures both times.
- Final full CardDAV Playwright suite: **106 passed, 1 expected TOTP skip**,
  including all request performance budgets. The suite uses explicit LiveView
  readiness and a single standard addressbook query to discover test contacts.
- Expanded vdirsyncer smoke: **all steps passed**, including client and server
  writes, conflict resolution, idempotency, application phone/tag changes,
  trash/archive, restore, and empty-trash recovery without resurrection.

Native Android verification was attempted on the Pixel_7 Android 14 emulator
with DAVx5. Repeated Pixel Launcher and DAVx5 "isn't responding" dialogs and
UI Automator failures prevented reliable account setup. One clean cold restart
with software rendering was also attempted; native creation/edit/photo checks
remain **unverified** for this follow-up. The task-owned emulator was stopped.
An iPhone and an iOS simulator were unavailable, so iOS behavior also remains
**unverified**. Do not substitute the synthetic Apple fixture for this check.

Browser console diagnostics also reproduced an existing Alpine command-palette
expression error on an ordinary Favorite toggle before any crop interaction.
That issue is separate from the successful avatar scenarios and remains open.
