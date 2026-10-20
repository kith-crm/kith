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
| 02-auth | A1-A5, M1-M3, RL1-RL3 | 10 | 0 | A4 is `test.fixme` (CDV-11, product decision) |

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

### 02-auth

| Case | Result |
|---|---|
| A1 | pass |
| A2 | pass |
| A3 | pass (`users.email` is citext; web login and DAV both accept `DAV-Admin@…`) |
| A4 | product decision CDV-11 |
| A5 | fixed CDV-10 |
| M1 | pass |
| M2 | pass |
| M3 | pass (B's PUT to A's `kith-contact-N.vcf` creates a new contact in B; A unchanged) |
| RL1 | pass |
| RL2 | fixed CDV-09 |
| RL3 | pass |

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
| CDV-10 | high | No brute-force protection on DAV Basic auth: unlimited password guesses per IP+email (R7). Root cause: `Kith.DAV.Auth` had no limiter at all; the first fix was itself check-then-act (read the count, verify PBKDF2 ~0.28 s, then increment), so concurrent bad guesses all read a stale count — 30 parallel guesses all got 401. Now the failure is counted atomically before verifying (serialized per key), a deny is 429 before any password check, and a success clears the count | 11 x `PROPFIND /dav/` with `Basic <throwaway-email>:wrong-N` from one IP -> all `401`, no `429` / `Retry-After`; 30 concurrent bad guesses -> 30 x `401` | fixed |
| CDV-11 | medium | A TOTP-enabled user authenticates over DAV with the account password alone; the second factor is bypassed for DAV (R1) | `PROPFIND /dav/` as `dav-totp@carddav.test:ValidP@ssword123!` -> 207. Recommendation: per-user, revocable DAV app passwords (required once TOTP is on); until then keep DAV working for 2FA users | product decision |
| CDV-12 | critical | Client-chosen resource names are ignored (R2): a PUT to `<uuid>.vcf` creates a contact at `kith-contact-N.vcf`, the client's href then 404s, every re-PUT creates a duplicate, and the vCard UID is replaced by `kith-contact-N`. Breaks Apple Contacts, DAVx5 and Thunderbird. Root cause: `find_contact_by_uid/2` only parsed `kith-contact-N.vcf`, every href emitter hard-coded that pattern, and `VCardAdapter.inject_uid` always wrote `kith-contact-N`. Fix: `contacts.dav_resource_name` / `dav_uid` (unique per account), `Contacts.get_contact_by_dav_name/2`, one `contact_href/1` helper (percent-encoded) for PROPFIND, multiget, sync and query, UID returned verbatim | `PUT /dav/addressbooks/default/<uuid>.vcf` (`UID:<uuid>`) -> 201; `GET` same href -> 404; PROPFIND Depth 1 lists `kith-contact-56.vcf` only; second identical PUT -> 201 and a second contact | fixed |
| CDV-13 | medium | Unsafe or malformed resource names are accepted on PUT: `..`, `%2E%2E`, `a%2Fb.vcf` (decodes to a slash), bad escapes (`%ZZ.vcf`) and control characters all create a contact; with R2 storing names they would become hrefs that cannot round-trip. Now a 400 for any name that is not one well-escaped, valid UTF-8 segment of at most 255 bytes without `/`, `\`, control characters or dot segments | `PUT /dav/addressbooks/default/%2E%2E` -> 201; `PUT .../..` -> 201; `PUT .../a%2Fb.vcf` -> 201; `PUT .../%ZZ.vcf` -> 201 | fixed |
| CDV-14 | medium | `If-Match` with a list of entity tags is compared as one opaque string, so `If-Match: "a", "<current>"` fails although the current ETag is listed (RFC 7232 §3.1). Weak `W/` tags were already refused. Now the header is parsed as a tag list and compared strongly | `PUT kith-contact-N.vcf` `If-Match: "a", "<current etag>"` -> 412 | fixed |

## Rulings I made

- R11 — A PROPFIND on `/dav/addressbooks/` without a `Depth` header keeps listing the child book (treated as Depth 1), and the address book keeps defaulting to Depth 0, rather than treating a missing header as `infinity` -> 403 — RFC 4918 §9.1 says missing = infinity, but rejecting it would break clients that omit the header, and both trees are finite — cost if wrong: a strict client sees one extra response.
- R12 — PROPFIND/PROPPATCH bodies are parsed with OTP's `:xmerl_sax_parser` (already loaded via `sweet_xml`; no new hex dep). Names come back as strings (no atom creation), entity declarations are refused (`disallow_entities`), a root other than `DAV:propfind` / `DAV:propertyupdate` or trailing content is a 400 — RFC 4918 §8.7 / §9.1 — cost if wrong: a client sending a non-standard root gets 400 instead of an allprop.
- R13 — `/dav/` and `/dav/principals/` answer Depth 1 with only themselves, and 404s are plain-text without a `DAV` header. Left as is — no client relies on either, and neither is a MUST — cost if wrong: none observed.
- R10 — Unknown requested props are reported in a `404 Not Found` propstat with their own namespace (replaces the old "silently ignored" test in `propfind_test.exs`) — RFC 4918 §9.1 requires every requested prop to appear in the response — cost if wrong: none; clients ignore 404 propstats.
- R14 — DAV auth limiting (R7) counts only failures that carry a parseable Basic email (key: client IP + lowercased email, Hammer fixed 5-minute window, shared ETS/Redis backend). Once a pair has 10 failures it gets `429` + `Retry-After` (seconds to the window end) *before* its credentials are checked, so even the right password is refused until the window ends; a success clears the pair's count. Requests with no or unparseable credentials are never counted — otherwise a client's challenge-seeking first request (or any proxy) would lock out every user behind that IP, and they cannot guess a password anyway — cost if wrong: a legitimate user who mistyped 10 times waits up to 5 minutes; a fixed window allows up to 20 guesses across a window boundary.
- R15 — Role checks for DAV writes use `Kith.Policy.can?(user, action, :contact)` with `:create` for a PUT to an unknown href, `:update` for a PUT to an existing contact and for PROPPATCH, `:delete` for DELETE. The 403 is sent before the vCard is parsed, but after the contact lookup, so a viewer DELETE on a missing href is still 404 — RFC 4918 lets the server pick between 403 and 404, and 404 for a missing resource leaks nothing — cost if wrong: none.
- R16 — R2 storage: a contact created by a DAV PUT stores the decoded last path segment as `dav_resource_name` and the vCard `UID` as `dav_uid`; both are returned verbatim (the href percent-encoded as one segment, the UID in both vCard versions). Lookup is by stored name first, then `kith-contact-<id>.vcf` only for contacts without a stored name, so every resource has exactly one href. A PUT to an existing contact keeps its href and original UID. Existing tests that read the relocated `kith-contact-N.vcf` href back out of PROPFIND now use the PUT href (`address_object_test.exs` `put_and_find/2` and the email/phone round trip) — RFC 6352 §6.3.2 forbids relocating — cost if wrong: a client that invents `kith-contact-<future id>.vcf` would shadow that future contact's default href (no real client does; ids are global bigserials).

## Real-client smoke
