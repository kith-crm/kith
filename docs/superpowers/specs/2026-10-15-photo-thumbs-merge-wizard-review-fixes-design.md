# Photo thumbnails and merge wizard: review fixes (design)

- **Date:** 2026-10-15
- **Branch:** `feat/stack-40-consolidated` (PR #44 → `release/0.5.0`)
- **Status:** decisions made during the PR #35/#36 review triage (2026-09-26) with the author; this document
  consolidates them for PR #44 and is awaiting review
- **Origin:** PR #44's deferred follow-up "review findings for #35 and #36". Those PRs were folded into #44 on
  2026-09-27; none of the fixes below have landed yet.

## 1. Status on PR #44 (head `c70b145`, checked 2026-10-15)

Each finding was re-checked against the PR #44 code. Findings marked **runtime** were reproduced again on
2026-10-15 in Kith running in Docker, driven with headless `playwright-cli`. The others were reproduced at runtime
during the September triage (S3 mode with a request-logging fake S3, Chromium, call tracing), and the code they
point at is unchanged on #44.

| Finding | Problem | Still present on #44 |
|---|---|---|
| #35-1 | A cached presigned URL (`@presign_expiry 3600`) outlives its expiry; a long-lived LiveView then shows "Image unavailable". | Yes: `PhotoThumbComponent.update/2` resolves the URL once; no refresh path. |
| #35-2 | `S3.presigned_url/2` signs with `utc_now`, so every call yields a new URL and the browser re-downloads. | Yes: no `start_datetime` (`s3.ex:100-105`). |
| #35-3 | `S3.csp_img_src/0` rescues every exception silently. | Yes (`s3.ex:120-130`). |
| #35-6 | `ImgFallback.bind()` attaches listeners to a new `<img>` without removing them from the old one; a late error from the old node marks the new image failed. | Yes (`img_fallback.js:20-31`; only `destroyed()` removes listeners). |
| #35-8 | `PhotoThumbComponent` has two near-identical `render/1` clauses. | Yes (`:45`, `:74`). |
| #35-avatar | `KithUI.avatar/1` shows the browser's broken-image icon when `src` fails; initials appear only when `src` is nil. | Yes (`kith_ui.ex:163`). |
| #35-9 | No tests for S3 signing, the CSP origin, or the refresh path. | Yes. |
| #36-2 | The wizard's back link and Cancel key on `synthetic?`, not on where the user came from. | **Yes, runtime:** from `/contacts/1` → Merge, the link reads "Back to contacts" → `/contacts`. |
| #36-5 | The wizard highlights the **All** tab on a manual merge. | **Yes, runtime:** "All" carries the accent classes on `/contacts/duplicates/cluster/1`. |
| #36-4 | Avatar choice buttons have identical accessible names; no `choose-field` button exposes its selected state. | Yes: no `aria-label`/`aria-pressed` in `cluster_merge.ex`. |
| #36-6 | `candidate_name/2` duplicates `member_name/2`. | Yes (`:767`, `:808`). |
| #36-3 | Hooked avatars need unique DOM ids; the same file shows as a member chip and as a choice button. | Yes: no ids passed (`:975`, `:1098`). |
| #36-8 | Tests miss the manual-merge nav and S3 URLs (mutation-tested: 3 deliberate breaks, 0 failures). | Yes. |

Dropped during triage and still dropped: #35-4 (unreachable), #35-5 (won't fix: negligible cost), #35-7 (disproved
at runtime), #36-1 (no change here; covered by #35-2), #36-7 (same code path).

## 2. Decisions

| # | Decision | Rejected alternatives |
|---|----------|-----------------------|
| B1 | **Stable signing (#35-2):** `presigned_url/2` passes `start_datetime` floored to the start of the current UTC hour, and `expires_in: 7200` by default. The same key gives the same URL within an hour, and every URL is valid for at least an hour after it's handed out. | Proxying images through the app (a round-trip in front of every S3 image). |
| B2 | **Lazy refresh (#35-1):** `ImgFallback` keeps an explicit state `"ok" \| "retrying" \| "failed"`. On the first `error` it sets `"retrying"`, hides the `<img>` behind a neutral placeholder, and `pushEventTo(this.el, "refresh_url", {})`. `PhotoThumbComponent` re-signs and assigns `:url`. An error while retrying → `"failed"` (amber badge); a `load` → `"ok"`. One retry per image, never a loop. `updated()` re-applies the stored state instead of re-deriving it from `naturalWidth`. | Re-signing on a timer; stable signing alone (only delays the failure). |
| B3 | **Hide while retrying** is required: a `src` change reuses the `<img>` node, and without it the broken-image icon showed for about 175 ms locally. | — |
| B4 | **Listener cleanup (#35-6):** `bind()` removes `onError`/`onLoad` from the previous `this.img` before binding a new node. | — |
| B5 | **Log CSP failures (#35-3):** keep the rescue (the page must render), but `Logger.error("Failed to build S3 CSP img-src: " <> Exception.message(e))` first. | Letting it raise. |
| B6 | **One render (#35-8):** a single `render/1` plus a private `variant_classes(:tile \| :timeline)` returning a map of class strings, done **before** B2 so the retrying state is written once. No visual change. | — |
| B7 | **Avatar fallback:** `KithUI.avatar/1` wires `ImgFallback` when `src` is set; on failure it shows the coloured initials circle (same `initials/1` + `name_to_color/1`). It has no stateful target for `refresh_url`, so it goes straight to failed → initials. `id` becomes **required when `src` is set**, and every call site that passes `src` supplies one. Photo thumbnails keep the amber badge. | Deriving the id from the storage key or name (not unique: the same file can appear twice on a page). |
| B8 | **Back target from `_live_referer` (#36-2):** in `mount/3`, read `get_connect_params(socket)["_live_referer"]` once and `URI.parse/1` it. Ignore it unless the host is our endpoint's host, then match **only the path**: `/contacts/duplicates` → "Back to duplicates"; `/contacts/<id>` (integer, looked up through the scoped context) → "Back to <name>"; `/contacts` → "Back to contacts", keeping the query string. Anything else, or no referer (reload, direct URL), → today's `synthetic?` behaviour. Assign it as `:back` (`%{path, label}`) and use it for the header link **and** the manual-merge Cancel. | A `?from=` param; one route per entry point; `history.back()`. |
| B9 | **Tab (#36-5):** the wizard always highlights **Duplicates** (`active={:duplicates}`). | Keying the tab on origin. |
| B10 | **Accessible choices (#36-4, #36-6):** delete `candidate_name/2` and use `member_name/2`. Avatar buttons get `aria-label="Photo N of M, from <holders>"` (unique holder names joined by ", "). **All** `choose-field` buttons, including "Leave empty", get `aria-pressed`. | — |
| B11 | **Unique avatar ids (#36-3):** `merge-member-avatar-<member id>` (chips) and `merge-avatar-choice-<index>` (choices). The existing "falls back to initials" comments stay; B7 makes them true. | — |
| B12 | Leaving the wizard discards unmerged choices: accepted, intended behaviour. No guard. | — |

## 3. Order of work
1. B6 (render refactor, no behaviour change).
2. B1, B5 (storage layer).
3. B2, B3, B4 (hook + component).
4. B7 (avatar fallback, required ids; update all call sites).
5. B8, B9, B10, B11 (merge wizard; depends on B7's required ids).
6. Tests (§4) for each step alongside it.

## 4. Testing

Every test that sets S3 config with `Application.put_env` must be `async: false` (global app env; it caused a real
flake in this repo).

**ExUnit**
- `S3.presigned_url/2`: identical URL for two calls in the same hour; a different URL in the next hour (signing is local).
- `S3.csp_img_src/0`: scheme + host, port 443 omitted, a custom port such as `:9000` kept; on a config error it
  returns `""` and logs (`capture_log`).
- CSP plug: with S3 configured, the `img-src` directive contains the storage origin.
- `PhotoThumbComponent`: `refresh_url` re-signs and assigns a new URL (`render_hook`); both variants still render
  as before (existing activity-stream tests stay green after B6).
- `KithUI.avatar/1`: with `src`, renders the hook, the given `id` and the hidden initials fallback; without `src`,
  unchanged.
- `ClusterMergeTest` (via `put_connect_params(conn, %{"_live_referer" => url})`):
  - contact → "Back to <name>"; list with a query → query kept; duplicates → "Back to duplicates"; foreign host,
    unknown path, `nil` → fallback; Cancel uses the same target.
  - Manual merge (`?with=`) → Duplicates tab active, All not.
  - Two contested avatars → distinct `aria-label`s; `aria-pressed="true"` only on the selected choice.
  - The same avatar as chip and choice renders (LiveViewTest raises on duplicate ids).
  - S3 config: the avatar `src` is unchanged after toggling a member off and on (B1 regression).
  - **Mutation check:** temporarily break the back link, the tab and Cancel; the new tests must fail. Restore.

**Playwright** (`test/playwright/`, S3 mode with the fake S3 from `stack-40-reviews/tools/fake_s3.py`)
- A missing-file photo retries once, then shows "Image unavailable"; the broken `<img>` is never visible while
  retrying; no retry loop.
- A missing-file avatar shows the contact's initials, on the contact page and as both chip and choice in the wizard,
  with no duplicate-id console errors.
- A photo that flips syncing → loaded (node replaced): a late error from the old node doesn't mark the new one failed.

## 5. Out of scope
- Immich: the CSP plug's `IMMICH_BASE_URL` read and per-account Immich URLs (issue #41).
- The S3 `scheme` fix: already in #44 (from #42).
- The flaky contested-gender test: already fixed in #44 (from #43).
- The "only X has this" hint, `SectionNav`'s attr contract, merge-resolution defaults.
