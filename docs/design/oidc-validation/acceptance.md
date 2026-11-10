# OIDC and DAV feature acceptance

2026-11-10 update: actual Android/live-provider/DAVx5 acceptance now has
[dated qualified evidence](task-6-final-2026-11-10.md). Prerequisite absences and
NOT RUN statements below describe the historical feature checkpoint. Original
failures and later qualified supplements are retained separately. Final cleanup
and independent final review status are recorded in the dated record.

Checkpoint: 2026-11-10, branch `t3/add-oidc-support`, task 11 base
`fbcdd28f6226f2c4d2d2b06c124d88a390315f4b`.
**Release acceptance is pending. Actual Android Chrome, DAVx5 and live Authentik
checks are NOT RUN. Task 11 independent review and final independent whole-branch
review are PENDING controller dispatch; this document does not certify them.**

This map audits the [binding spec](../../superpowers/specs/2026-11-09-oidc-dav-app-passwords-design.md)
and [approved settings organization](../previews/show-me-settings-v2.html).
Source/test paths below are repository-relative. Reports, exact command output,
and independent task reviews are retained locally under
`.superpowers/sdd/2026-11-09-oidc-dav-app-passwords/` (abbreviated **E/**), not
published secret-bearing browser traces. “Reviewed” below means the named task
review, not a final whole-branch verdict. Required feature cases have no skips;
ordinary ExUnit `:external`/`:slow` exclusions do not count as provider/device proof.

## Spec-to-implementation and evidence map

| Spec section / acceptance boundary | Implementation | Exact automated cases / command evidence | Review / remaining boundary |
| --- | --- | --- | --- |
| Goal, scope, approach | `lib/kith/auth/{config,policy,oidc,principal}.ex`, `lib/kith/accounts/{oidc,dav_app_passwords}.ex`; dedicated transactions/challenges; existing Assent 0.3.2 | Protocol, account, MFA and DAV suites below exercise the separate boundaries. No provider-name branch, dependency upgrade, role mapping, provider logout or new social/passkey management. | Tasks 1–9 reviewed; whole-branch review PENDING. Generic fixture evidence is not universal-provider compatibility. |
| Operator configuration: all flags/defaults, strict booleans, legacy compatibility, malformed URLs/secrets, usable capability | `lib/kith/auth/{config,policy}.ex`, `lib/kith/config_helpers.ex`, `config/{config,runtime}.exs`, `lib/kith/application.ex` | `test/kith/auth/config_test.exs`: “defaults and all independent flag combinations”, “contradictory signup settings fail closed”, “secret files take precedence and errors are redacted”, “startup requires a configured interactive mechanism, not existing credentials”. Task 1 command: `mix test test/kith/auth/config_test.exs test/kith_web/auth_policy_test.exs test/kith_web/live/user_live/signup_controls_test.exs` → 19/0, E/task-1-green.log. Included in final full suite below. | E/task-1-review.md Approved. Startup checks deployment capability, not every user's ability to log in. |
| Password/registration policy: direct endpoints, reset request/redemption, pending MFA, existing sessions/bearers | `lib/kith_web/controllers/{user_session_controller,api/auth_controller}.ex`, `live/user_live/{login,registration,forgot_password,reset_password}.ex`, `authentication.ex`, `lib/kith/dav/auth.ex` | `test/kith_web/auth_policy_test.exs`: direct POST, API issuance, connected signup/recovery/reset events, pre-disable challenge and “existing sessions and bearer credentials remain valid”. Browser `test/playwright/oidc.spec.ts`: “password policy is enforced by UI and direct web/API requests”; `dav-app-passwords.spec.ts`: “account DAV password follows the independent password policy”. Full ExUnit + four-mode runner below. | Tasks 1/3/7/8/9 reviewed; old Google/GitHub behavior retained. Disabling passwords is not revocation. |
| OIDC interoperability: code/query, Basic client auth, RS256, S256, nonce, exact issuer, claims/types, UserInfo, clock/network/key boundaries | `lib/kith/auth/oidc.ex`, `oidc/metadata.ex`, `test/support/oidc_fixture.ex` | `test/kith/auth/oidc_test.exs`: “authorization uses S256, a string nonce, code/query and exact redirect”, invalid signed claim values, pinned signature/algorithm, exact metadata/profile, UserInfo subject, timeout/TLS/hostname, 300-second cache, unknown-kid refresh, clock skew/token-age boundaries, real single-use code/PKCE/client/redirect binding. Task 5 fix command `mix test test/kith/auth/oidc/runtime_config_test.exs test/kith/auth/oidc_test.exs test/kith/auth/oidc/transactions_test.exs` → 35/0, E/task-5-fix1-green.log. Final full suite below. | E/task-5-re-review-1.md resolves production cron + fixture PKCE findings. Supported profile only; Authentik NOT RUN. |
| Transaction/browser ownership: expiry, parallel tabs, atomic single use, error correlation, cookie separation, safe return, rotation | `oidc/transactions.ex`, `oidc/transaction.ex`, `lib/kith_web/controllers/oidc_controller.ex`, `oidc_html/complete.html.heex`, `authentication.ex`, `user_auth.ex` | `test/kith/auth/oidc/transactions_test.exs` tests concurrent consumption/parallel flows/hash+encrypted storage. `test/kith_web/controllers/oidc_controller_test.exs` tests disabled routes, callbacks, signed completion forgery/expiry/local destinations and response privacy. `test/playwright/oidc.spec.ts` distinct-site callbacks, pending tabs, denial/expiry/replay/missing binding/timeout, key rotation, logout/revoked-origin session. Full ExUnit + four-mode runner below. | Tasks 5/7/8/9 reviewed, including sibling-cancellation fix. Chromium observed Lax binding present/Strict absent at callback, Strict present after committed same-site completion. No helper-installed session cookie. |
| Identity ownership/registration: exact issuer+sub, no email takeover, verified email, terms, races, personal account, no external privileges, unlink last method | `lib/kith/accounts/oidc.ex`, `accounts/oidc_identity.ex`, `accounts/user.ex`; `live/user_live/oidc_registration.ex`, OIDC controller | `test/kith/accounts/oidc_test.exs`: “verified matching email never links an existing account”, exact keys/different issuers, personal account/defaults, later missing/unverified email without synchronization, actual boolean verification, terms/rollback/no orphan, concurrent first signup on independent connections, collision race, persisted password/MFA state and configured alternatives, app passwords do not count. Task 6 focused command `mix test test/kith/accounts/oidc_test.exs test/kith/accounts_oauth_test.exs test/kith/accounts_webauthn_test.exs` → 53/0 (E/task-6-final-focused.log); final full suite below. Browser signup/terms/closed modes/link/unlink/other owner's identity in `oidc.spec.ts`. | E/task-6-review.md Approved; task 8/9 UI reviews Approved after fixes. Issuer changes never transfer identities. |
| Local MFA/fresh authentication: pending gate, recovery replay/expiry/throttling, OIDC-only freshness, stale-session mutation denial | `lib/kith/auth/{challenges,challenge}.ex`, `lib/kith_web/authentication.ex`, `controllers/user_session_controller.ex`, `live/user_live/{login,totp_challenge,totp_setup}.ex`, user tokens | `test/kith/auth/challenges_test.exs`: browser binding/one use, expiry, recovery reuse, origin session, rate limits, encrypted storage/purge. `test/kith_web/authentication_completion_test.exs`: password MFA grants no token, legacy freshness, same-user reauth, OIDC auth_time, local MFA link, session rotation, logout siblings/no Strict state. Task 7 final fix focused → 53/0, E/task-7-fix1-lax-green2.log. Browser TOTP/recovery/fresh link/reauth/protected denial in `oidc.spec.ts`. Full suite + runner below. | E/task-7-re-review-1.md resolves cancellation identity finding. Provider first factor never bypasses local TOTP; merely renewed sessions do not establish freshness. |
| DAV credentials: hash-only, entropy, names, ownership, malformed prefix, immediate concurrent revocation, deletion, DAV-only, role/account boundaries | `lib/kith/accounts/{dav_app_password,dav_app_passwords}.ex`, `lib/kith/dav/auth.ex`, existing DAV scope/policy | `test/kith/accounts/dav_app_passwords_test.exs`: hash persistence/Inspect/log redaction, fresh mutations, bounded Unicode labels, wrong owner/secret/malformed input, concurrent revocation. `test/kith_web/dav/auth_test.exs`, API/session controller tests verify DAV-only use, policy/throttling, ownership and deletion. Task 3 four-file command → 48/0 (E/task-3-green.log), affected full DAV → 336/0 (E/task-3-affected.log). `test/playwright/dav-app-passwords.spec.ts` real PROPFIND 207, wrong username 401, next request after revoke 401, same-account sibling, web/API rejection. Final suite + runner below. | Tasks 3/4/7/9 reviewed. No expiry/last-used tracking claim. Actual DAVx5 client NOT RUN. |
| UI/lifecycle: configured visibility, pending/cancel/failure, no-store, one-time display/copy fallback, errors, focus/no overflow | `lib/kith_web/live/settings_live/{security,contact_sync}.ex`, user login/registration views, `assets/js/alpine/copy_text.js`, OIDC controller, router privacy plugs | `test/kith_web/live/settings_live/{security,contact_sync}_test.exs`: placement, disabled/forged events, owner checks, fresh mutation/reconnect, confirmations, one-time navigation/remount, cache/return allowlist. `test/js/copy-text.test.mjs`; `test/playwright/{oidc,dav-app-passwords,carddav-copy}.spec.ts`: real failures/retry, clipboard rejection/select-all/reload, 44px targets, long names and widths. Task 4 final focused 73/0 (E/task-4-status-green.log), JS 19/0; final checks below. | Task 4 Approved; Task 8 re-review Approved after diagnostic redaction. Provider logout/deprovisioning excluded and documented. |
| Sensitive responses/logs/fixtures | `config/config.exs` filters, `lib/kith/sentry_scrubber.ex`, controller no-store/no-referrer, encrypted payload schemas/Inspect exclusions; test-only fixture controls | `test/kith_web/controllers/oidc_controller_test.exs`: actual CaptureLog successful callback + opaque provider diagnostic denial; `test/kith/sentry_upgrade_integration_test.exs`: real emitted envelope excludes opaque markers; scrubber/event-handler tests. Task 8 fix command over those four suites → 44/0 (E/task-8-fix1-green.log). No trace/video/storage-state exports; only secret-free explicit screenshots. Full suite/static security below. | E/task-8-re-review-1.md resolves diagnostic disclosure. Proxies must separately exclude queries/headers/bodies. Existing legacy social shortcomings remain outside this work. |
| Settings integration: every old destination/active state, role/direct-route authorization, Profile email, Security password/TOTP return, personal DAV vs Immich | `lib/kith_web/live/settings_live/settings_layout.ex`, `security.ex`, `contact_sync.ex`, `integrations.ex`, `live/user_live/settings.ex`, router/layouts; `assets/js/hooks/settings_navigation.js` | `test/kith_web/live/settings_live/settings_layout_test.exs`: role groups/every destination+nested history/direct route; security/contact-sync/Profile tests; `test/kith/settings_multitenancy_test.exs`. Browser `test/playwright/settings-navigation.spec.ts` exact mobile Settings selector, role destinations/history/resize, admin Immich, email confirmation/password relocation; existing `settings.spec.ts`, `mobile-navigation.spec.ts`, `mobile-layout.spec.ts`. Task 2 browser 23/0, task 4 browser 24/0; final runner/regressions below. | Tasks 2/4/9 Approved. Import filtered by existing create/import permission after real viewer dead end. Approved mockup is organization guidance; actual Kith chrome/components preserved. |
| Verification/delivery: migration preservation, operator recovery, full checks/reviews and external evidence | Five `priv/repo/migrations/202611*.exs`; [OIDC operations](../../deployment/oidc.md), [DAV guide](../../deployment/dav-app-passwords.md), `.env.example`, CI browser jobs | Task 11 isolated fresh + populated prefeature upgrade/actual failed DOWN below; full integration checks below. Task 10 runbook/runner exists; [device acceptance](task-10-acceptance.md) records NOT RUN. | Tasks 1–10 independent reviews exist; 5/7/8/10 required fixes re-reviewed. Task 11 and final whole-branch review PENDING. No release/merge/deploy authorization. |

## Integrated execution checkpoint

Environment: macOS 27.2 (26B123), Node v26.5.0, Playwright 1.64.1,
Chromium 156.0.8078.4. Desktop 1366/1440px; phone viewports 320/375/393px,
including retained 0/57px browser-toolbar simulations. These are desktop Chromium
simulations, **not Android**. Four fresh process/database policy instances cover
password and registration independently enabled/disabled, with OIDC enabled.
Fixture sites are `https://kith.test` and `https://issuer.test` on loopback with
run-local DNS and TLS trust; no global installation/trust change or production data.
Regression runner verifies Mailpit and starts owned app/S3/Monica fixtures.

| Final integration command (task 11) | Result / retained log |
| --- | --- |
| `git diff --check` before documentation | Exit 0, E/task-11-before.log; a documentation audit has no fabricated failing behavior test. |
| `MIX_ENV=test mix quality` (compile warnings-as-errors, format check, strict Credo, reviewed Sobelow script, Dialyzer) | Exit 0, E/task-11-quality.log; 32 exact reviewed exceptions; 2 existing CLDR suppressions, 0 unnecessary skips. No exception/digest changed in task 11. |
| `npm run test:js` | Exit 0, 19/0, E/task-11-js.log. |
| `MIX_ENV=test mix test` | Exit 0 on final sole run, 2770/0, 93.0s, E/task-11-full-final.log; first run 2770/1 retained (cluster selection), exact recheck 1/0 and unchanged file/original seed 101/0.. |
| `PLAYWRIGHT_NO_COPY_PROMPT=1 PLAYWRIGHT_OUTPUT_DIR=tmp/browser-regressions/task11-results PORT=4121 KITH_TEST_S3_PORT=9121 KITH_TEST_MONICA_PORT=8121 npm run test:regressions` | Exit 1, 53 passed/2 failed; E/task-11-regressions.log. Login-throttle setup timeout at 390px and reset-button disabled after input; exact fresh-fixture recheck 2/0, exit 0, E/task-11-regressions-recheck.log. All 55 unique cases have positive execution; full batch remains failed.. |
| `bash test/playwright/fixtures/oidc/run.sh` | Exit 0, 39/0 per mode, 156/0 total, zero skips; E/task-11-oidc.log.. |
| `MIX_ENV=test mix run --no-start .superpowers/sdd/2026-11-09-oidc-dav-app-passwords/task-11-migrations.exs` | Exit 0 on final run, E/task-11-migrations-final.log; details below. Earlier prerequisite/seed mistakes retained, not passing evidence. |
| `MIX_ENV=test MIX_TEST_PARTITION=_task11_fresh_1794262289 mix ecto.migrate` | Exit 0, migrations already up; E/task-11-ecto-migrate.log; owned fresh database only. |

Earlier task 9 distinct-site matrix: 156/0 twice, then final focused 36/0 with
zero skips (E/task-9-browser-final.log, task-9-browser-verified.log,
task-9-post-review-matrix.log). Its existing full regression batch had 45 passes,
1 unchanged animation timeout and 9 blocked serial siblings; exact animation
recheck 1/0 and siblings 9/0 established positive execution of all 55 unique cases.
That earlier batch remains a **failed batch**, not “all green”.

## Migration preservation and rollback observation

Owned databases retained for inspection:
`kith_test_task11_fresh_1794262518` and
`kith_test_task11_upgrade_1794262518`. The fresh install applied all migrations,
including all five feature migrations. The upgrade started with the migration
set strictly before `20261109183601`, populated synthetic account/user, a real
verifiable password hash, three token contexts (session/API/reset), legacy GitHub
identity with synthetic credential bytes, contact, rich/archived DAV document,
resource UID/revision/extras/fingerprint, sync floor and document reference.
After upgrade, all preexisting fields in all eight populated tables compared
identically by complete-row fingerprints; the existing password still verified.
Only the new `mfa_authenticated_at` column was excluded from legacy fingerprints,
and its NULL value on every existing token was separately asserted.

The actual generated DOWN for `20261109195100` was executed after adding a
synthetic OIDC-only NULL-hash user in that owned upgrade DB. PostgreSQL rejected
NOT NULL with `not_null_violation`; the failed migration left the column nullable.
No user deletion, fake hash or destructive credential backfill was used. This
establishes the documented recovery constraint, not safe automatic rollback.
The [operator recovery guide](../../deployment/oidc.md#migration-and-rollback)
requires fix-forward or deliberate supported enrollment/verified backup recovery.
No shared database was reset, rolled back or force-disconnected. Earlier owned
attempt databases and scripts/logs remain recovery artifacts. A final assertion
also verified the failed DOWN retained the NULL-hash user and every original row.

## Visual comparison to approved settings

Inspected actual application PNGs `tmp/oidc-browser/safe-sync-open-1440.png` and
`safe-revoked-open-320.png`, plus the approved iteration-2 HTML and actual
`SettingsLayout`, Profile, Security and Contact sync implementations. Desktop
retains Kith chrome, warm surface/amber active treatment, grouped Personal /
Workspace / Data links, current location, focused cards and a personal Contact sync
destination. Phone uses one labelled native grouped Settings selector above the
page; the 80-character device label wraps inside the 320px card and primary action
remains usable. Credential list/empty state is default; creation/reveal/revoke are
focused steps and connection details use the supported `/dav/principals/` URL.
The app puts credential management before connection details, keeping the list
primary; the mockup's illustrative URL, last-used values and demo recovery
regeneration controls are not product requirements. Security uses existing focused
cards with collapsed password form, configured identity status/confirmation and
existing TOTP setup. Profile retains email, not the password form. Browser journeys
verify those routes/keyboard/history/permissions; screenshots do not establish
Android touch/keyboard behavior or claim pixel equality with the prototype.

## Outstanding acceptance and residuals

- **Android Chrome NOT RUN:** read-only enumeration found an Android 10 arm64
  emulator with no Chrome or Playwright driver. No installation/global settings
  changes were authorized. Provider callback cookies, actual session/MFA/link/
  reauth/credential/touch/history/keyboard behavior remains unverified on Android.
- **DAVx5 NOT RUN:** package `at.bitfire.davdroid` is present; version not inspected.
  Reachable trusted fixtures and actual client configuration/sync/read-write/
  role-isolation/revocation/second-client behavior remain outstanding in both modes.
- **Live Authentik NOT RUN:** no nonproduction deployment/credentials supplied.
  Generic signed HTTPS fixture execution is not live-provider acceptance.
- **Independent final whole-branch review PENDING:** controller must dispatch it
  after task 11 review and resolve blocking findings; no verdict is implied here.
- Earlier task reviews approved scoped work after required fixes. Deferred minors:
  expected negative-worker/slow-query/teardown and conflicting color warning noise;
  historical rate-limit reset rounding and metrics initialization flakes; unchanged
  animation observer timeout (root cause unestablished); error-path OIDC runner
  cleanup suppresses DB-drop failure with `|| true` (normal success path fails on
  drop error). Keep run ownership/inventory visible after failures. Task 9 fixed
  the previously unmatched CardDAV script-loading warning; do not blanket-suppress
  unexpected diagnostics. Existing two CLDR Dialyzer suppressions remain.
- Task 11 initial full ExUnit had one unchanged cluster-merge selection failure;
  exact test 1/0 and full unchanged file with original seed 101/0, then full suite
  2770/0. Root cause unestablished. Existing browser batch had a 390px password
  setup throttle timeout and disabled account-reset button after input; retain
  the 53/2 batch. Both exact cases passed unchanged in a fresh fixture (2/0);
  this establishes 55 unique positive cases, not a green full batch.
- Hosted CI/production-build/deployment execution is not certified by local test
  results. Existing legacy social callback shortcomings and issue #62 remain
  outside scope. No provider-wide logout, SCIM, automatic deprovisioning, group/role
  mapping, multiple generic issuers, or new recovery-code regeneration UI is claimed.
