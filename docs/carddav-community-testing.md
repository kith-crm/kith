# Upstream community CardDAV testing

`scripts/carddav-e2e/community-test.sh` runs Apple's original CalDAVTester CardDAV scripts against Kith's isolated live harness. It preserves upstream assertions and reports failures. It complements Kith's ExUnit, Playwright and real-client checks; its result is not a claim of full CardDAV conformance.

## Reproduce

The pinned runtime currently supports **macOS ARM64 only**. Required tools are Bash, Git, curl, shasum, tar, lsof, pgrep and Python 3 (configuration/artifact processing only). The tester itself runs under a private PyPy Python 2.7 runtime; no system Python installation or global packages change.

Use the existing isolated harness, with database `kith_carddav_task10_e2e`, HTTP endpoint `http://127.0.0.1:4527`, and fixture account `dav-other@carddav.test`. If it is not already running, start it using the repository's existing setup:

```bash
scripts/carddav-e2e/up.sh
scripts/carddav-e2e/community-test.sh --prepare-only
scripts/carddav-e2e/community-test.sh
```

`up.sh` recreates the dedicated test database; do not restart it during another live-client test. The community script neither starts the server nor creates/drops databases. It sources the harness-generated `.carddav-task10/env`, refuses a different database/endpoint, checks the recorded server process and authenticates to account B before executing the suite. Coordinate runs with other tests using that account: upstream tests create, overwrite and delete resources with fixed names. Use `DAV_PASSWORD` only if the dedicated fixture password has changed.

`--prepare-only` verifies/downloads dependencies and generates the server configuration without sending requests. The normal run invokes the unmodified upstream command with `--all --subdir CardDAV`, log and JSON observers, and these advertised test features: `carddav`, `current-user-principal`, `sync-report`, `well-known`, `ctag`. Disabled features cause upstream tests to be ignored rather than rewritten. All configuration changes are in a generated `serverinfo.xml`; resource bodies, verifier code and XML assertions remain unchanged.

Each invocation produces a directory under `.carddav-task10/community-results/` containing `serverinfo.xml`, complete `upstream.log` and extracted `results.json`. Output includes actual pass/fail/error/ignored counts and the upstream exit status; a failed suite exits nonzero. Setup/runtime errors also fail. Logs and JSON can contain HTTP Basic authorization headers for the local fixture; keep these ignored artifacts local or redact them before sharing.

## Reproducible dependencies

| Component | Pin |
| --- | --- |
| [Apple CalDAVTester](https://github.com/apple/ccs-caldavtester/tree/bed21e5924275552c1561febc8203a9f194cf737) | `bed21e5924275552c1561febc8203a9f194cf737` |
| [Apple PyCalendar](https://github.com/apple/ccs-pycalendar/tree/a12dd4e1ce8822b022d4abf2cfe6cc93902ff03f) | `a12dd4e1ce8822b022d4abf2cfe6cc93902ff03f` |
| [Official PyPy download](https://downloads.python.org/pypy/) | `pypy2.7-v8.0.1-macos_arm64.tar.gz` |
| [Published archive SHA256](https://pypy.org/checksums.html) | `8d9f5d9b440bb4886df07f5e5038b87985e2b977dc048763d6699fa7b7186b19` |

The script reuses the ignored `.carddav-task10/community-caldavtester`, `community-pycalendar-upstream` and PyPy caches. Wrong revisions, origins, tracked local modifications or archive checksums fail rather than being silently reset. The pinned archive is checked on every preparation. Remove or move a conflicting cache explicitly before retrying.

Apple [archived the original repository on February 24, 2024](https://github.com/apple/ccs-caldavtester); its setup declares Python 2 only. [CalConnect's fork](https://github.com/CalConnect/caldavtester) was last pushed on February 6, 2019 ([repository metadata](https://api.github.com/repos/CalConnect/caldavtester)). Python 3 forks such as [grozadanut's tester](https://github.com/grozadanut/ccs-caldavtester) and [LeanderKafemann's PyCalendar](https://github.com/LeanderKafemann/ccs-pycalendar) were explored locally but did not provide a complete working replacement in this evaluation. That is a local evaluation result, not a claim that all forks are unusable. This helper uses the original engine and official private Python 2 runtime to avoid silently changing upstream behavior.

## Recorded unmodified baseline

The first upstream baseline on October 29, 2026 ran **115 tests: 26 passed, 62 failed, 5 setup errors, 22 ignored**, with a nonzero exit. Local artifacts are `.carddav-task10/community-upstream-baseline.log` and `.carddav-task10/community-upstream-baseline.json`. These are historical observations from the initial local configuration; reruns print their own counts. The reproducible helper was then executed after the discovery privilege fix and independently reproduced **26 passed, 62 failed, 5 errors, 22 ignored**, exiting **67**. Its final artifacts are `.carddav-task10/community-results/20261029T003521Z-13238/`; console summary is `.carddav-task10/community-runner-final.log`. The generated configuration was also validated with upstream's own server-info parser.

Interpret individual request/response traces before labeling a failure a Kith defect:

- Many upstream fixtures use UIDs such as `…:ABPerson`. Kith's agreed identity policy requires UUID identities, so these writes fail and dependent GET/report assertions can fail in turn. The baseline leaves those fixtures unchanged.
- Upstream scripts assume CalendarServer's configurable books, collection creation, COPY, ACL and arbitrary dead properties. Kith currently exposes one fixed address book and does not implement those facilities.
- All enabled upstream user aliases map to account B and the same book. This prevents the baseline from mutating another fixture account, but does **not** validate independent-user ACL, delegation, account isolation or distinct-user paths. Kith's dedicated isolation tests remain necessary.
- The upstream well-known check expects a different redirect target from Kith's server-root discovery route. Compare the required discovery behavior and actual Location header before treating the exact-path expectation as a defect.
- `Resource/CardDAV/vnonascii/2.vcf`, used by the upstream non-UTF-8 test, actually contains valid UTF-8 encoding of U+FFFD. Its acceptance does not demonstrate acceptance of malformed UTF-8. Kith's byte-level invalid-input tests cover that boundary separately.
- Two malformed PROPFIND cases were genuine validation gaps in the recorded baseline: an `allprop` plus `propname` body, and a body containing only `undefined`, returned 207 rather than a client error. These are separate from the fixed native-discovery defect; no general WebDAV rewrite was undertaken. See [RFC 4918 PROPFIND grammar](https://www.rfc-editor.org/rfc/rfc4918.html#section-14.20).
- Server-setup errors and skipped feature tests reduce meaningful coverage. A large number of assertions failing after one rejected fixture is not evidence of that many independent protocol defects.

Any later Kith-specific profile must record fixture/setup adaptations separately, retain the untouched baseline and explain each change. Do not edit the upstream verifiers, relax assertions, or count ignored/setup-failed cases as passes to produce a green result.


## Detailed classification of the 62 failed checks

This classifies the final recorded run at
`.carddav-task10/community-results/20261029T003521Z-13238/results.json`.
Counts below are failing checks, not distinct defects. Every failed check has
one primary classification; the counts total exactly 62. Machine-readable
case IDs and original failure text are retained in ignored
`.carddav-task10/community-failure-triage.json`. No additional server test was
run for this classification; it combines the saved wire traces, current source
and the cited standards.

| Classification | Failed checks | Evidence / interpretation |
| --- | ---: | --- |
| PROPFIND validation defect | 2 | `propfind.xml / prop errors / 1,2`: conflicting `allprop`+`propname`, and an `undefined`-only body both returned 207. They violate the [PROPFIND grammar](https://www.rfc-editor.org/rfc/rfc4918.html#section-14.20). One missing validation mechanism accounts for both checks. |
| Media-type error response defect | 1 | `errors.xml / ERROR CONDITIONS / 4`: wrong Content-Type returned plain-text 415 without the required `CARDDAV:supported-address-data` precondition. The missing XML error is the confirmed issue; the suite additionally demands status 403. [RFC 6352 §6.2.2](https://www.rfc-editor.org/rfc/rfc6352.html#section-6.2.2) requires that precondition. |
| Unimplemented ACL/principal reports | 15 | `aclreports.xml`: ACL principal-property sets, principal matching/search and their error handling are absent. Excludes one rejected UID fixture and two requests using nonexistent CalendarServer hierarchy paths, classified below. This group includes the generic error-body mismatch on the unsupported principal-search report. It is not 15 independent defects. |
| Unimplemented WebDAV property editing | 7 | `proppatch.xml`: arbitrary dead properties and book display-name edits are rejected; dependent readback also fails. |
| Unimplemented book creation | 1 | `mkcol.xml / MKCOL with body / 1`: creation of another address book has no implemented endpoint. |
| Unimplemented collection GET representations | 4 | `get.xml / GET on resource / 2,3`; `directory.xml / GET on collections / 2,6`: directory-style GETs on the existing book/principal/home endpoints are absent. |
| Absent collection content-length property | 1 | `propfind.xml / regular prop finds / 4`: no size representation is exposed for the book collection. This does not establish a size-property bug for individual vCards; [RFC 4918 §15.4](https://www.rfc-editor.org/rfc/rfc4918.html#section-15.4) ties the property to a GET representation. |
| Agreed UUID-only restriction and cascades | 9 | Three `errors.xml` checks, one `get.xml`, one `aclreports.xml`, and four high-ASCII checks reject valid opaque/Apple `…:ABPerson` UIDs, or fail downstream after that rejection. These UIDs are valid vCard values: the restriction is Kith's interoperability limitation, not proof of broken fixtures. Three of these nine are downstream GET/query failures. |
| Harness-specific discovery expectations | 10 | `well-known.xml`: five checks expect a service at the `/.well-known/` container itself; five require an exact HTTPS-root Location instead of Kith's working principal redirect. Native discovery passed through the actual redirect. These results do not demonstrate ten broken discovery functions. |
| CalendarServer hierarchy/configuration mismatch | 7 | Five `directory.xml` checks and two `aclreports.xml / principal-match / 4,5` target CalendarServer-style `/users/`, `/groups/` or `/__uids__/` paths absent from Kith's account-relative layout. Their 404s do not prove equivalent requests at correctly mapped principal endpoints would pass. |
| Broken UTF-8 fixture plus rerun state | 3 | `nonascii.xml / Non-utf-8 address data / 1,2,3`: the fixture contains valid UTF-8 U+FFFD. Initial execution accepted it; the final repeat hit Kith's reserved trashed href and returned plain-text 409 instead. These three checks do not test malformed UTF-8 reliably. |
| Permitted status-code difference | 2 | `errors.xml / ERROR CONDITIONS / 25,26`: PUT targets existing collections; Kith rejects it with 405 while the suite demands 403. [RFC 4918 §9.7.2](https://www.rfc-editor.org/rfc/rfc4918.html#section-9.7.2) permits 405 for collection PUT. |
| **Total** | **62** | **3 checks expose two implementation defects; 28 concern missing features/properties; 31 concern declared restrictions, fixture/configuration assumptions or allowed response differences.** |

“Unimplemented” does not mean “optional” or “fully compliant without it.” In
particular, [RFC 6352 §§3 and 7](https://www.rfc-editor.org/rfc/rfc6352.html#section-3)
requires WebDAV ACL support. Kith's missing ACL functionality is a real full-
conformance gap even though ordinary contact sync works. Extended MKCOL is
recommended, rather than universally mandatory. The UUID-only policy is also a
compatibility restriction beyond general vCard UID syntax. Earlier descriptions
that broadly called these CalendarServer assumptions were too imprecise.

The five setup errors are outside the 62: COPY/MOVE, errorcondition and REPORT
suites stopped on rejected UID fixtures; PUT setup tried deleting the fixed
book through DELETEALL, and sync setup tried deleting the book directly.
Those suites' test bodies were not executed. Their errors are not evidence
that CardDAV PUT, REPORT or sync themselves are broken or validated by this
community run. The 22 ignored entries likewise contribute no pass evidence.

The separate native home-child privilege discovery defect was fixed and
retested in Thunderbird. It is not an additional open failure in this table.


## Follow-up correctness slice (2026-10-29)

The original 26/62/5/22 baseline, 62-case classification and untouched upstream
scripts/resources remain unchanged. Local follow-up implements selector validation
and the missing structured media-type error. Conflicting/duplicated/missing
PROPFIND selectors now return 400; empty request bodies and unknown extensions
remain accepted, and `allprop` plus `include` honors explicit properties, including
404 propstats for missing properties. Direct property text values are rejected.

Unsupported PUT Content-Type now returns XML `CARDDAV:supported-address-data`
with **415**, retaining the appropriate unsupported-media status. [RFC 6352
§§6.2.2/6.3.2.1](https://www.rfc-editor.org/rfc/rfc6352.html#section-6.3.2.1)
mandates the precondition without prescribing 403; [RFC 4918 §16](https://www.rfc-editor.org/rfc/rfc4918.html#section-16)
requires correct HTTP semantics, and [RFC 9110 §15.5.16](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.16)
defines 415 for this rejection. The upstream check still demands 403: do not
predict a green check or edit its verifier. The missing XML defect is fixed
locally; the status expectation remains a separate compatibility difference.

The prioritized [remaining-work plan](plan/carddav-data-boundary.md#17-remaining-correctness-and-interoperability-plan-2026-10-29)
separates mandatory ACL/principal/expand-property and PROPPATCH processing work
from recommended arbitrary dead-property storage/extended MKCOL, optional
collection representations, and retained UUID/single-book restrictions. The
advertised DAV class inventory also needs review against actual methods.

No new community/live/native run is claimed by this slice. Before a meaningful
rerun, reserve exclusive harness ownership, recreate only its dedicated fixture
DB/storage, map supported paths/capabilities correctly, and separate real users
for ACL testing. Preserve the untouched baseline alongside any explicitly named
Kith profile; record all UID/setup adaptations and keep upstream assertions.
Focused and broader local validation results are recorded in plan section 17.


## Fresh-state Apple baseline rerun (2026-10-29 12:50 UTC)

After the request correctness fixes, the user requested another Apple run.
Port 4527 and database `kith_carddav_task10_e2e` were verified unused/absent;
`up.sh` created fresh dedicated database/storage and seeded the existing harness.
Both pinned upstream repositories were unchanged. The same generated baseline
capability/path/user-alias configuration and original scripts, fixtures and
verifiers were retained; no Kith-specific profile adaptation was applied.
This is a controlled baseline rerun, not resolution of the configuration and
independent-user coverage limitations described above.

Result: **28 passed, 60 failed, 5 setup errors, 22 ignored; exit 65**.
Artifacts: `.carddav-task10/community-results/20261029T125041Z-15216/`
(`upstream.log`, `results.json`, `serverinfo.xml`); runner summary:
`.carddav-task10/apple-rerun-20261029.log`. The original baseline remains intact.

Case-level comparison, including failure details rather than just totals:

- `propfind.xml / prop errors / 1,2` both changed from fail to pass, confirming
  rejection of conflicting selectors and undefined-only requests.
- `errors.xml / ERROR CONDITIONS / 4` still fails its exact expected 403 status.
  Its captured response now contains HTTP 415, `application/xml` and the required
  namespaced `CARDDAV:supported-address-data` child inside `DAV:error`. The
  structured-error defect is resolved; the remaining status expectation is the
  separately documented permitted HTTP semantic choice, not a missing XML error.
- `nonascii.xml / Non-utf-8 address data / 1,2,3` still fail, but now receive
  201/204/204 rather than the previous repeated-run 409 conflicts. Fresh state
  removes the reserved-href cascade. The original fixture still contains valid
  UTF-8 U+FFFD, so acceptance does not demonstrate malformed UTF-8 acceptance.
- Every other recorded result and failure detail matches the saved baseline.
  The same five setup errors persist; those suites' bodies still do not establish
  PUT/REPORT/sync conformance. Ignored cases remain uncovered.

Startup first prepared/seeding successfully but its detached server exited
before the runner's ownership check; that attempt ran no suite bodies. The
server was restarted in a foreground tool session against the prepared fresh
state, ownership metadata was refreshed, and the completed run above followed.
The verified task-owned server, dedicated database and newly allocated storage
were removed afterward. Default databases, personal clients and original
performance fixtures were untouched. No commit, push or PR comment occurred.


## Revised-plan protocol changes (2026-10-29)

Local implementation now includes canonical per-user and derived-role principals,
account-scoped principal reports, local bounded property expansion, role-aware
privilege properties and ordered atomic PROPPATCH processing. Unsupported class-2
locking is no longer advertised. Protected ACL policy does not establish full
RFC 3744 grant support; arbitrary dead-property storage and book displayname edits
remain unsupported. Current exact evidence and restrictions are in plan section 17.

No new Apple result is claimed for these changes. The pinned original baseline
and its 28/60/5/22 rerun remain untouched historical evidence. Its same-account
aliases cannot validate the new distinct-user behavior. HTTP regression tests
use actual distinct users/roles and an unrelated account. A future community
profile must be separately named, map canonical principal paths and real users,
and record capability/setup adaptations without modifying upstream fixtures,
verifiers or assertions. Ignored/setup-failed cases still are not passes.
