# Task 10 sanitized acceptance record

Date: 2026-11-09. No actual Chrome/DAVx5/provider acceptance was executed.
Read-only `_android.devices({omitDriverInstall:true})` enumeration found one
emulator reporting model `Android SDK built for arm64`. Read-only device shell reports Android 10. `pm list packages` found no
`com.android.chrome` or `com.microsoft.playwright` package; DAVx5 package
`at.bitfire.davdroid` is present, version NOT RUN (not inspected). Chrome and
the Playwright driver require separately authorized installation before a run. No installs/device setting
changes performed. App/issuer origins, device network reachability and TLS trust:
NOT SUPPLIED. Nonproduction Authentik deployment/credentials: NOT SUPPLIED.

| Acceptance case | Password enabled | Password disabled | Evidence / prerequisite |
| --- | --- | --- | --- |
| Android Chrome redirect/callback/session continuity | NOT RUN | NOT RUN | Trusted reachable distinct-site fixture + preprovisioned driver |
| Wrong MFA, TOTP and recovery, protected-route denial | NOT RUN | NOT RUN | Protected fixture setup and actual browser |
| Link/unlink, last-method denial, fresh auth + MFA return | NOT RUN | NOT RUN | Confirmed disposable users and browser |
| Selector touch, back/history, keyboard/focus/occlusion | NOT RUN | NOT RUN | Actual device observation |
| Create/show once/copy fallback/select/reload/revoke | NOT RUN | NOT RUN | Actual browser and disposable credential |
| DAVx5 discovery + initial/subsequent sync | NOT RUN | NOT RUN | Already provisioned actual DAVx5 and test book |
| DAVx5 contacts read/write + read-only/account isolation | NOT RUN | NOT RUN | Synthetic book and roles, safe server outcomes |
| DAVx5 next-request denial + unaffected second client | NOT RUN | NOT RUN | Two independently named actual client credentials |
| Ordinary password policy + app-password success | NOT RUN | NOT RUN | Independent policy deployments |
| Live Authentik login/MFA/fresh auth/credential smoke | NOT RUN | NOT RUN | Securely supplied nonproduction provider |

Runner failure evidence: `node scripts/android/oidc-chrome.mjs` exits 1 with
`FAIL: HTTPS and protected fixture prerequisites (see Android runbook)` and no
acceptance recorded. This proves prerequisite failure handling only. No viewport,
fixture vCard or protocol-probe results are counted as Android/DAVx5 PASS.

Future records must include date, device/emulator, Android build, Chrome/DAVx5
versions, app/issuer origins, TLS setup, mode, case result and sanitized evidence.
