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

## Bug log

| ID | Severity | Summary | Request / response | Status |
|---|---|---|---|---|
| CDV-01 | low | OPTIONS `Allow` omits PROPPATCH although PROPPATCH is implemented on the collection | `OPTIONS /dav/` -> 200, `allow: OPTIONS, GET, PUT, DELETE, PROPFIND, REPORT` | fixed |
| CDV-02 | medium | `PROPFIND /dav/addressbooks/` ignores `Depth: 0` and always returns the home set plus its child | `PROPFIND /dav/addressbooks/` `Depth: 0` -> 207 with 2 `<d:response>` | fixed |
| CDV-03 | high | Address book never offers the `sync-token` property although `supported-report-set` advertises sync-collection (RFC 6578 §4) | `PROPFIND /dav/addressbooks/default/` Depth 0 `<d:prop><d:sync-token/><cs:getctag/></d:prop>` -> 207, `<d:sync-token/>` in a `404 Not Found` propstat | fixed |
| CDV-04 | medium | Malformed XML, non-XML and non-UTF-8 PROPFIND / PROPPATCH bodies are answered 207 instead of 400 | `PROPFIND /dav/` body `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag></d:prop>` -> 207; body `hello` -> 207; UTF-8-declared body with bytes `FF FE` -> 207; `PROPPATCH` body `<d:propertyupdate xmlns:d=` -> 207 | fixed |
| CDV-05 | high | PROPFIND body parsing is namespace-blind: `allprop`/`propname` only recognised with a `d:`/`D:` prefix, and props are detected by substring | `PROPFIND /dav/` `<A:propfind xmlns:A="DAV:"><A:allprop/></A:propfind>` -> 207 `<d:response><d:href>/dav/</d:href></d:response>` (no propstat at all; same for default `xmlns="DAV:"`); `PROPFIND /dav/principals/` asking only `<card:supported-address-data/>` -> 404 propstat also lists a bogus `<d:address_data/>`; a namespace URI `urn:owner-getctag` makes `<d:owner/>` and `<cs:getctag/>` appear as requested | open |
| CDV-06 | medium | Unknown requested props are silently dropped instead of being reported in a 404 propstat (RFC 4918 §9.1) | `PROPFIND <contact href>` Depth 0 `<d:prop><d:getetag/><x:bogus xmlns:x="urn:x"/></d:prop>` -> 207 with only the 200 `getetag` propstat | open |
| CDV-07 | medium | A PROPFIND / PROPPATCH body over 8 MB crashes with `MatchError` (`read_body` returns `{:more, ...}`) -> 500 (R8) | `PROPFIND /dav/` with a 9 MB body -> 500; server log `** (MatchError) no match of right hand side value: {:more, ...}` | open |
| CDV-08 | low | The ctag of an empty address book is the current Unix time, so it changes every second and clients re-sync on every poll | `PROPFIND /dav/addressbooks/default/` as `dav-other` (empty book) twice, 1.2 s apart -> `<cs:getctag>1792450260` then `<cs:getctag>1792450261` | open |

## Rulings I made

## Real-client smoke
