# Actual Android OIDC acceptance

Status (2026-11-10): **qualified actual-device acceptance**, with historical failures
and remaining gaps preserved. See the [dated consolidated record](oidc-validation/task-6-final-2026-11-10.md),
[original Android matrix](oidc-validation/task-4-android-acceptance.md), and
[configured-profile supplement](oidc-validation/task-4-android-freshness-2026-11-10.md).
The standard runner below remains NOT RUN under the pinned-device-CLI UI constraint;
actual cases used supported native adapters. Full native copy/clipboard verification
and external keyboard remain NOT RUN after supported controls were exhausted.

Run the automated subset from the repository:

```sh
node scripts/android/oidc-chrome.mjs
```

Prerequisites must be prepared by the operator of an authorized, disposable test
device; this task does not authorize installs or global device/TLS changes:

- Exactly one authorized device/emulator visible to Playwright's ADB service.
  Chrome and Playwright's Android driver must already be installed. The runner
  uses `_android.devices({omitDriverInstall: true})` and `device.launchBrowser()`;
  it never installs the driver. Missing prerequisites fail with exit 1.
- A dedicated nonproduction Kith/issuer deployment using the Task 9 protected
  [fixture contract](../../test/playwright/fixtures/oidc/README.md): `MIX_ENV=test`,
  `KITH_OIDC_E2E=1`, confirmed disposable users, signed fixture tokens, single-use
  authorization codes with exact callback/PKCE, and protected `/__fixture__` controls.
  No production fixture endpoint or preinstalled browser session cookies.
- App and issuer must be different sites, with device-resolvable hostnames,
  reachable HTTPS ports, exact registered HTTPS callback, and valid hostname
  certificates. The desktop harness's process-local DNS/SPKI settings do not
  configure Android. Arrange a dedicated test network/DNS and test-only CA trust
  on a disposable device beforehand under separate authorization. Never disable
  certificate verification or change global TLS settings to make a run pass.
- Supply through the protected process environment (never arguments or echoed
  shell commands): `KITH_ANDROID_TEST_URL` (app HTTPS origin),
  `KITH_ANDROID_ISSUER_URL` (issuer HTTPS origin), `KITH_TEST_FIXTURE_TOKEN`,
  `KITH_OIDC_TLS` (directory with trusted `ca.pem`), `KITH_OIDC_E2E=1`, and
  `KITH_OIDC_PASSWORD=true` or `false`. Node must resolve/reach the same app origin;
  its requests verify the CA and hostname. Keep secret files outside evidence.
- Run twice against fresh dedicated app processes: `PASSWORD_LOGIN_ENABLED=true`
  and `false`, reflected exactly by `KITH_OIDC_PASSWORD`. Do not flip shared app
  configuration or reset a shared DB. Use fixture-owned cleanup only.

The runner seeds a linked MFA user through the authenticated control channel,
selects fixture claims, then uses the real Android login action and issuer
Authorize button. It checks pending MFA cannot access dashboard, wrong code
rejection, TOTP success, Settings native selector, Android back, stale-session
provider reauthentication (`max_age=0`) plus local MFA returning to Security,
credential creation/reveal/focus/reload/revocation, and protocol status probes.
A protocol probe is never DAVx5 evidence. The runner's PASS only covers its
explicit automated subset; it does not complete the manual acceptance matrix.
Controls create disposable test records; clean up only the dedicated run's DB.

Manual Android Chrome acceptance, both policy modes:

1. Record device vs emulator, Android build, Chrome version, date, trusted app
   and issuer origins, TLS/CA setup and policy. Do not retain a serial number.
2. Start logged out in the isolated browser profile. Touch OIDC, cancel using
   Android Back, restart, authorize and complete callback/MFA. Check clean final
   URL and correct protected user. Test wrong TOTP and recovery-code completion
   with a separate fresh fixture user; pre-MFA protected routes must deny access.
3. Open the native Settings selector using touch, choose Security and Contact
   sync, use Android Back/Forward and repeat. Attach an external keyboard if
   available: Tab through controls, observe focus, activate selected destination.
   Verify no clipped focus/action at actual device width or with browser toolbar.
4. Tap MFA and Device name inputs; observe the Android keyboard actually opens.
   Confirm the focused input and primary action can be scrolled into view without
   horizontal overflow; dismiss keyboard with Back without leaving the flow.
   Automated DOM focus assertions alone do not prove OS keyboard visibility.
5. Using a separate confirmed unlinked user and normal password UI while enabled,
   explicitly link through Security and complete provider + local MFA. Check
   linked identity, unlink confirmation and successful relink. In passwordless
   mode use an existing linked MFA user and verify last-method unlink is rejected.
   Never bootstrap an authenticated session by installing a cookie.
6. Expire freshness through protected fixture `stale` control, visit Security,
   complete real fresh-provider + local MFA round trip. Repeat creation/revocation
   after freshness expiry. Check return destination and cancelled auth denial.
7. Create a named credential. Touch Copy and verify success or actionable failure.
   Long-press/select all and manually copy the selectable one-time value when
   clipboard access fails. Never capture the secret in screenshots/recordings.
   Reload and navigate away/back: value must disappear. Create another credential
   for DAVx5; keep it only in the client's protected account store.
8. Revoke and check next authenticated DAV request fails. Verify web/API use is
   denied and the second independently named client credential remains usable.
   Follow the [DAVx5 runbook](../../scripts/carddav-e2e/oidc-app-passwords-android.md).

Live Authentik smoke is separate: only run when a nonproduction deployment and
credentials are supplied through secure tooling. Register exact HTTPS callback,
code/query, confidential client_secret_basic, S256 PKCE, RS256 and openid/email/
profile. Use a confirmed linked disposable user, provider login, callback, local
MFA, fresh auth and Contact sync creation. Verify passwordless mode and
last-method protection. Record provider version/profile and sanitized outcomes;
do not use fixture Authorize controls against Authentik or branch application
logic by provider. Missing access is NOT RUN, never fixture-derived PASS.

Evidence belongs only under `docs/design/oidc-validation/`: PASS/FAIL/NOT RUN per
case with date, mode, device/software metadata and sanitized request method/path/
status. No callbacks with queries, cookies, authorization headers, fixture tokens,
TOTP seeds/recovery codes, credentials, personal contacts or storage-state dumps.
The runner prints only a fixed phase on failure, not Playwright error details;
no traces, video or automatic screenshots. Observe first, then transcribe harmless
results after secret display is gone. If a failure occurs, record FAIL and stop
claiming completion; unavailable prerequisites remain NOT RUN.
