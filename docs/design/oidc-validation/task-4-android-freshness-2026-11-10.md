# Android freshness supplemental evidence — 2026-11-10

Actual configured-profile rerun: **PASS for both policies, two delayed repeats each, original-owner links and cancellation.** Native full-copy and clipboard contents remain **NOT RUN**. Historical stock-provider failures in [the baseline](task-4-android-acceptance.md) and [matrix](task-4-android-matrix.json) remain unchanged.

Authentik 2026.8.5 uses the independently reviewed `kith-local-always-authenticate` authorization profile: unconditional Identification → Password (InbuiltBackend) → UserLogin, `terminate_other_sessions=false`. This local validation profile requires real credentials on every authorization and emits real `auth_time`. It does not establish that the stock provider's repeated `prompt=login` / `max_age=0` defect is corrected. Kith's strict freshness validation remains intact.

| Actual Android case | Password enabled | Password disabled |
|---|---|---|
| Sensitive baseline: actual provider password then local MFA → Security | PASS | PASS |
| Delayed repeat 1: deliberate wait / elapsed since prior successful round | PASS: 66.004s / 92.446s | PASS: 66.002s / 99.154s |
| Delayed repeat 2: deliberate wait / elapsed since prior successful round | PASS: 66.003s / 92.035s | PASS: 66.002s / 93.749s |
| Real provider identification/password submissions per baseline/repeat | 1 / 1 each | 1 / 1 each |
| Cancel provider challenge with Android Back | PASS | PASS; subsequent credential+MFA recovery PASS |
| Delayed original-owner explicit link | PASS: 66.005s | PASS: 67.004s, **policy-cutover** preconditions below |
| Copy success feedback; new test credential revoked | PASS | PASS |
| Native full selection + Copy / clipboard content verification | NOT RUN | NOT RUN |

The same existing Incognito provider jar/principal was retained across modes, both repeats and linking. Chrome PID17109 remained running; target-scoped CDP verified the same browser context and four provider cookies at handoff. Cookies were never cleared or installed; no principal switch, global logout, browser relaunch, DOM form injection, fabricated claims or session bootstrap was used. Every input/action used the supported pinned device CLI; CDP observed only. There were no credential screenshots or dumps.

The false-policy link is specifically **FALSE policy-cutover explicit-link evidence**, not steady-false unlink evidence. The steady-false last-method guard first rejected unlink. On the same owned database, temporary true policy allowed a real password fallback and visible unlink. An initial false attempt encountered expired sensitive recency; genuine local password plus original-owner MFA refreshed the session under true. An ownership-gated same-database restart returned policy to false while preserving the real RP session and provider jar. After 67.004s, visible Connect required one genuine provider password submission and original-owner MFA; the original owner's identity count returned to one. Final false policy was verified, normal account-password DAV returned401, and last-method unlink still rejected removal. Enabled linking likewise used a real password fallback and visible unlink; its first MFA code was rejected and a genuine current-code retry passed. Exact enabled-link provider password count was not persisted, but the >=1 submission guard passed before MFA.

Completed sustained UI runs used pool16 / ownership timeout600000ms in isolated owned databases. Earlier pre-provider HTTP500 attempts were harness checkout timeouts, excluded from profile acceptance; default source settings remain4 /120000ms. Failed operational attempts remain in private evidence. Baseline matrix SHA256: `752e349e063c39395a94f9909eedf76d10566b10682bd87c1b538a2437008575`.

Chrome is official Chromium159.0.8152.0 (snapshot1738660 exact installed APK match), Android10/API29 buildQSR1.211112.002, Playwright1.64.1 / official Android driver1001. Trusted exact HTTPS origins are `https://kith.test:8444` and `https://authentik.test:8443`; process-scoped mappings route those and fixture.test to10.0.2.2. Narrow user CA only; no TLS bypass or global trust/DNS changes. Browser routing does not prove DAVx5 native networking.

Full native-copy fallback remains unverified: supported native controls exposed only partial selection (enabled31/75, disabled26/75) and no full-selection/Copy action. The supported clipboard command was already exhausted; no ADB clipboard bypass was used. Copy success feedback is not a claim about clipboard contents. Both newly created copy-test credentials were hidden and revoked.

Handoff retains false policy, original standard tab, provider jar/Chrome PID, narrow CA, driver and browser routing. Original AOSP keyboard restored, own device binding released, observer port forward removed. No test tabs were added in this rerun. Task5 must acquire its own supported device binding and establish its separate native network prerequisites. Exact structured evidence: [dated matrix](task-4-android-freshness-2026-11-10.json).
