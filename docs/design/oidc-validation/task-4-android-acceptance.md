# Actual Android OIDC acceptance — 2026-11-10

**PARTIAL. Delayed/repeated live Authentik freshness fails in both password policies.** This is not feature acceptance. The controllable signed fixture and live-provider results are separate.

[Sanitized case matrix](task-4-android-matrix.json) contains the latest observed outcome per case. Earlier failed adapter attempts remain in the protected local records; corrected native input, scrolling and navigation timing were rerun before recording PASS.

| Actual Android scope | PASS | FAIL | Qualification |
|---|---:|---:|---|
| Signed fixture, password enabled | 15 | 0 | Includes explicit password/MFA login, link/unlink/relink, stale-token rejection and recovery |
| Signed fixture, password disabled | 14 | 0 | Includes last-method protection and account-password DAV rejection |
| Live Authentik, password enabled | 19 | 2 | Delayed freshness fails; full native Copy fallback not completed |
| Live Authentik, password disabled | 17 | 2 | Same failures; retained provider session prevents a comparable visible issuer-cancel step |

Counts describe executed cases, not identical coverage or a complete manual matrix. The enabled live run additionally exercised actual web-form rejection of a working DAV app password and native browser Forward. The disabled run explicitly verified committed full-origin navigation/Back removes the one-time value. See individual rows rather than inferring missing cases from another policy.

## Device and trust

Actual Pixel_4 emulator: Android10/API29, build `QSR1.211112.002/7910984`, security patch2019-09-05. Chromium `159.0.8152.0` (`org.chromium.chrome`, code815200004), Playwright1.64.1, official Android driver revision1001. This is Chromium, not a branded `com.android.chrome` installation.

The installed browser APK exactly matches `chrome-android/apks/ChromePublic.apk` from the [official ARM64 snapshot1738660](https://storage.googleapis.com/chromium-browser-snapshots/Android_Arm64/1738660/chrome-android.zip), SHA256 `da8bcb3abbc2ad69bb4569974cf630270c5ad44c81aac6622d44a89e377c7883`.

Both [official driver1001 APKs](https://cdn.playwright.dev/dbazure/download/playwright/builds/android/1001/android.zip) were installed after recording their absence. `android-driver.apk` is the test package and declares no versionName/versionCode; `android-driver-target.apk` declares1.0/code1. Their exact hashes are in the owner recovery/provisioning report.

Only the dedicated run CA was installed in Android USER trust; the original USER CA tab was empty. Host/system trust and DNS were not changed. Chromium process-local mappings send `kith.test`, `authentik.test` and `fixture.test` to emulator host gateway10.0.2.2. No TLS bypass, SPKI bypass, global resolver change or browser session-cookie installation was used.

Live sites: `https://kith.test:8444`, `https://authentik.test:8443`.
Signed-fixture sites: `https://kith.test:8454`, `https://fixture.test:8455`. Port8445 remains the live harness readiness site, not the fixture issuer. The fixture leaf explicitly covers kith.test/fixture.test and expires2026-11-11 00:29:42UTC; renew through the harness owner if needed. Both fixture policies used distinct owned databases/processes.

## What passed

Actual pinned-CLI interaction covered real provider signup/terms/callback, protected account continuity, native Settings selection and Back, real AOSP keyboard opening on Device name and MFA fields, focus/action reachability with the keyboard,44CSS-pixel Create action, no horizontal overflow, wrong TOTP rejection, valid TOTP and recovery consumption, last-method rejection, credential creation, one-time hiding after reload/navigation, and revocation followed by DAV401. A working app password returned DAV207 and was rejected by API login; the enabled live run also rejected it through the actual web password form. Pending-MFA browser fetches were denied before successful local MFA; these are browser-session protocol observations, not a manual second-tab navigation claim.

Fixture-only cases additionally completed explicit linking after normal password login and local MFA, unlink confirmation/relink, fresh sensitive authentication returning to Security, independent named credentials (revoking one leaves its peer DAV207), deliberately stale signed auth_time rejection, and renewed first-factor/local-MFA recovery. These do not establish Authentik freshness.

[Public login screen](android-live-enabled-login.png) was captured before credentials were entered. No secret-page screenshot, trace, video, callback-query record, cookie dump or storage-state dump is evidence here. An audit bug overmatched policy strings true/false in135 private diagnostic files. Affected boolean metadata could not be reconstructed and is explicitly null/unknown (2614 positions); primary case records, cleanup inventory and this evidence were unaffected. The corrected sensitive-input scan found zero known matches in checked logs/public text. No raw diagnostics are published. UI input used the pinned CLI; CDP observed layout, requests and outcomes without driving UI. Test IME was used for reliable injection after separately observing the real AOSP keyboard. It was restored at handoff.

## Outstanding outcomes

**Live delayed/repeated freshness: FAIL in both policies.** The retained provider session receives max_age=0/prompt=login, immediately returns a successful code, and produces token endpoint200 with the expected claim-shape booleans. Kith rejects the result instead of granting sensitive access or local MFA. A freshly issued token is not proof of a fresh authentication event. The controller's separate read-only investigation reopened Task3; it identifies a likely pinned Authentik repeated-prompt/session-marker issue. No provider fix or weaker application validation was applied by Task4.

**Full native one-time-value Select All/Copy fallback: FAIL to complete through the pinned UI.** Long-press selected part of the readonly value; full Select All/Copy could not be completed through exposed controls. The application Copy feedback check passed (the disabled run explicitly recorded Copied!), but independent clipboard-content verification is NOT RUN: the supported CLI reports clipboard UNSUPPORTED_OPERATION. A native Chrome Copy-public-URL action was issued after testing to replace test-secret clipboard content; contents and original clipboard restoration cannot be verified by that CLI.

**NOT RUN:** external hardware-keyboard/Tab traversal (no external keyboard; no pinned Tab action), a comparable visible live issuer-cancel step in the second policy's retained SSO session, and live-provider identity switching/link/unlink beyond last-method protection. Changing the retained provider login to another principal would conflict with preserving the repeated-freshness reproducer. Fixture enabled link/unlink/relink was executed.

The original `scripts/android/oidc-chrome.mjs` entry point was NOT RUN unchanged: its Playwright UI calls conflict with the pinned-CLI-only UI requirement. The actual device matrix used protected local adapters with the fixture contract and real app/provider actions. No desktop viewport simulation or DAV protocol probe is DAVx5 evidence.

## Handoff

The provider session was preserved: its cookie fingerprint is unchanged from before fixture execution, no cookies were cleared, and Chromium stayed running. The original standard tab is intact; the test standard tab was closed. The device binding was released by opening/closing Settings, leaving the browser process alive. AOSP input method was restored. The temporary CDP port forward was removed.

Owned Kith is retained with password=true, suffix `_android_enabled_01`; `.oidc-local/app-mode.json` is authoritative. Its Contact sync page was verified connected after a final ownership-gated restart. Long UI runs intermittently hit the test harness's four-connection checkout queue; a reload recovered one MFA setup500, and the final restart recovered the retained page. This infrastructure limitation must not be counted as an authentication bypass or hidden by the host readiness probe.

The separate fixture remains password=false on8454/8455. Exact PIDs, database names, protected credential interfaces and identity-checked cleanup instructions are in `.superpowers/sdd/2026-11-10-local-oidc-device-validation/task-4-android-acceptance-report.md`. Provider remediation and Task5 may now acquire their own supported device binding. Preserve the retained browser/provider session until the delayed/repeated provider regression is complete.
