# CardDAV end-to-end regression

## How to run

```bash
scripts/carddav-e2e/up.sh                 # isolated dev server on :4517, DB kith_carddav_e2e
source /tmp/kith-carddav-e2e.env
npx playwright test --project=e2e test/playwright/carddav/<file> --workers=1
scripts/carddav-e2e/down.sh               # stop the server
MIX_TEST_PARTITION=_carddav mix test      # ExUnit, DB kith_test_carddav
```

`PERF=1 scripts/carddav-e2e/up.sh` additionally seeds account E (2000 contacts).
Seeded users (password `ValidP@ssword123!`) are listed in `test/playwright/helpers/dav.ts`.

## Results matrix

| Spec | Cases | Passed | Failed | Notes |
|---|---|---|---|---|
| 00-harness | H1-H3 | 3 | 0 | |

### 01-discovery

| Case | Result |
|---|---|
| W1 | pass |
| W2 | pass |
| O1 | fixed CDV-01 |
| P1 | pass |
| P2 | pass |
| P3 | fixed CDV-02 |
| P4 | fixed CDV-03 (also CDV-08: empty-book ctag) |
| P5 | fixed CDV-06 |
| P6 | fixed CDV-05 |
| P7 | fixed CDV-04, CDV-07 |
| P8 | pass |
| P9 | pass |
| P10 | pass (CDV-06 also corrects the namespaces it echoes) |

## Bug log

| ID | Severity | Summary | Request / response | Status |
|---|---|---|---|---|
| CDV-01 | low | OPTIONS `Allow` omits PROPPATCH although PROPPATCH is implemented on the collection | `OPTIONS /dav/` -> 200, `allow: OPTIONS, GET, PUT, DELETE, PROPFIND, REPORT` | fixed |
| CDV-02 | medium | `PROPFIND /dav/addressbooks/` ignores `Depth: 0` and always returns the home set plus its child | `PROPFIND /dav/addressbooks/` `Depth: 0` -> 207 with 2 `<d:response>` | fixed |
| CDV-03 | high | Address book never offers the `sync-token` property although `supported-report-set` advertises sync-collection (RFC 6578 §4) | `PROPFIND /dav/addressbooks/default/` Depth 0 `<d:prop><d:sync-token/><cs:getctag/></d:prop>` -> 207, `<d:sync-token/>` in a `404 Not Found` propstat | fixed |
| CDV-04 | medium | Malformed XML, non-XML and non-UTF-8 PROPFIND / PROPPATCH bodies are answered 207 instead of 400 | `PROPFIND /dav/` body `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag></d:prop>` -> 207; body `hello` -> 207; UTF-8-declared body with bytes `FF FE` -> 207; `PROPPATCH` body `<d:propertyupdate xmlns:d=` -> 207 | fixed |
| CDV-05 | high | PROPFIND body parsing is namespace-blind: `allprop`/`propname` only recognised with a `d:`/`D:` prefix, and props are detected by substring | `PROPFIND /dav/` `<A:propfind xmlns:A="DAV:"><A:allprop/></A:propfind>` -> 207 `<d:response><d:href>/dav/</d:href></d:response>` (no propstat at all; same for default `xmlns="DAV:"`); `PROPFIND /dav/principals/` asking only `<card:supported-address-data/>` -> 404 propstat also lists a bogus `<d:address_data/>`; a namespace URI `urn:owner-getctag` makes `<d:owner/>` and `<cs:getctag/>` appear as requested | fixed |
| CDV-06 | medium | Unknown requested props are silently dropped instead of being reported in a 404 propstat (RFC 4918 §9.1) | `PROPFIND <contact href>` Depth 0 `<d:prop><d:getetag/><x:bogus xmlns:x="urn:x"/></d:prop>` -> 207 with only the 200 `getetag` propstat | fixed |
| CDV-07 | medium | A PROPFIND / PROPPATCH body over 8 MB crashes with `MatchError` (`read_body` returns `{:more, ...}`) -> 500 (R8) | `PROPFIND /dav/` with a 9 MB body -> 500; server log `** (MatchError) no match of right hand side value: {:more, ...}` | fixed |
| CDV-08 | low | The ctag of an empty address book is the current Unix time, so it changes every second and clients re-sync on every poll | `PROPFIND /dav/addressbooks/default/` as `dav-other` (empty book) twice, 1.2 s apart -> `<cs:getctag>1792450260` then `<cs:getctag>1792450261` | fixed |
| CDV-09 | critical | Roles are not enforced over DAV: a `viewer` can create, overwrite and delete contacts (R6) | as `dav-viewer`: `PUT /dav/addressbooks/default/<new>.vcf` -> 201; `PUT kith-contact-21.vcf` -> 204 and FN changed; `DELETE kith-contact-21.vcf` -> 204 (admin GET then 404); `PROPPATCH /dav/addressbooks/default/` -> 207 | fixed |
| CDV-10 | high | No brute-force protection on DAV Basic auth: unlimited password guesses per IP+email (R7) | 11 x `PROPFIND /dav/` with `Basic <throwaway-email>:wrong-N` from one IP -> all `401`, no `429` / `Retry-After` | fixed |

## Rulings I made

- R11 — A PROPFIND on `/dav/addressbooks/` without a `Depth` header keeps listing the child book (treated as Depth 1), and the address book keeps defaulting to Depth 0, rather than treating a missing header as `infinity` -> 403 — RFC 4918 §9.1 says missing = infinity, but rejecting it would break clients that omit the header, and both trees are finite — cost if wrong: a strict client sees one extra response.
- R12 — PROPFIND/PROPPATCH bodies are parsed with OTP's `:xmerl_sax_parser` (already loaded via `sweet_xml`; no new hex dep). Names come back as strings (no atom creation), entity declarations are refused (`disallow_entities`), a root other than `DAV:propfind` / `DAV:propertyupdate` or trailing content is a 400 — RFC 4918 §8.7 / §9.1 — cost if wrong: a client sending a non-standard root gets 400 instead of an allprop.
- R13 — `/dav/` and `/dav/principals/` answer Depth 1 with only themselves, and 404s are plain-text without a `DAV` header. Left as is — no client relies on either, and neither is a MUST — cost if wrong: none observed.
- R10 — Unknown requested props are reported in a `404 Not Found` propstat with their own namespace (replaces the old "silently ignored" test in `propfind_test.exs`) — RFC 4918 §9.1 requires every requested prop to appear in the response — cost if wrong: none; clients ignore 404 propstats.
- R14 — DAV auth limiting (R7) counts only failures that carry a parseable Basic email (key: client IP + lowercased email, Hammer fixed 5-minute window, shared ETS/Redis backend). Once a pair has 10 failures it gets `429` + `Retry-After` (seconds to the window end) *before* its credentials are checked, so even the right password is refused until the window ends; a success clears the pair's count. Requests with no or unparseable credentials are never counted — otherwise a client's challenge-seeking first request (or any proxy) would lock out every user behind that IP, and they cannot guess a password anyway — cost if wrong: a legitimate user who mistyped 10 times waits up to 5 minutes; a fixed window allows up to 20 guesses across a window boundary.

## Real-client smoke
