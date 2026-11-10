# Isolated real Authentik harness

Run `scripts/oidc-local/up.sh` in a retained terminal (it stays attached to the owned Kith process), verify with `python3 scripts/oidc-local/check.py`,
stop using `scripts/oidc-local/down.sh`. Requires Docker Compose, host Elixir with
compiled test dependencies, Python3, OpenSSL, curl and free ports
15449/19049/8443/8444/8445. Initial migrations may take ten minutes. Do not run
multiple copies or restart while an existing owned host process is active.

Based on official deployment and provider documentation fetched 2026-11-10:
https://docs.goauthentik.io/install-config/install/docker-compose/
https://docs.goauthentik.io/add-secure-apps/providers/oauth2/
Authentik2026.8.5 and Postgres16-alpine are pinned by manifest digest in compose.
No Docker socket, optional outpost management, production configuration changes,
host DNS edits, global trust installation or insecure TLS flags are used.

Private generated credentials, keys, certificates and restricted raw diagnostics
live in ignored .oidc-local (0700 directory /0600 files). Do not print run.json,
runtime.env, enable traces/storage-state capture or photograph credential pages.
Before sharing raw provider logs, sanitize callback queries and credentials.
Teardown records project inventory, terminates only identifiable harness PIDs,
and removes only project kith-oidc-c8f3c762 volumes/network/containers. Retained
private state can be explicitly deleted after review; unrelated resources remain.

Distinct HTTPS sites and exact-hostname certificates:
- https://authentik.test:8443 (TLS edge to owned provider port19049)
- https://kith.test:8444 (test-build Kith, dedicated random-run database)
- https://fixture.test:8445 (authenticated run readiness only)

App resolver mappings are process-local. Its normal OIDC adapter verifies the
run CA; host check uses the same CA and local resolver. Docker host-gateway maps
authentik.test inside the project, with CA available /run/kith-test/ca.pem for
explicit client trust. Browser automation must map all three hosts and configure
an ephemeral profile to trust the exact leaf SPKIs or private CA. Never enable
ignoreHTTPSErrors. Listeners8443/8444/8445 permit explicit disposable-device
routing later; device DNS and CA installation are separate authorized steps.
No device access is performed by this harness.

Provider provisioning uses one strict callback, confidential client, code grant,
RSA signing and openid/email/profile mappings. Verified email is a boolean from
a generated user attribute; user2 is deliberately unverified. Discovery must
advertise code/query, RS256, S256 and client_secret_basic. Actual max_age/auth_time
freshness and browser/token interoperability require subsequent round-trip tests.

run.json contains the disposable client/user/control credentials. Kith controls
reuse only existing protected prepare/stale/expire/revoke_sessions/snapshot
seeding/lifecycle support, never fake token issuance or session installation.
Use prepare with linked:false for collision/link cases. Real identities must use
Authentik's issued subject, not fixture-generated IDs. Bearer control_token guards
/__fixture__ readiness and controls; never print it. KITH_OIDC_PASSWORD=true|false
selects the app policy before startup. Restart the app for each policy mode.
Kith test registration stays enabled. The fixture site is not a provider.
Neither desktop nor host checks count as Android/DAVx5 evidence.

Ownership: every new run generates a unique Compose project in private run.json.
Use scripts/oidc-local/compose.sh for Compose operations (it loads private
interpolation values and checks ownership). Containers, networks and volumes carry
run/worktree labels. A wrong checkout or foreign project resource fails closed.
The initial already-running project was adopted once through audited exact Docker
IDs, creation identity, existing project labels and worktree bind mounts in private
legacy-ownership.json. Only those exact objects can use this legacy allowance;
replacements must have matching run/worktree labels. Existing processes were
likewise audited by current worktree cwd plus exact command/start time. New host
processes use absolute script paths, a run marker and recorded command/start time;
teardown checks the exact identity for each process kind before signaling.

Before deletion, teardown saves final-inventory.json, restricted private provider
logs and sanitized-diagnostics.json. The sanitized artifact is a structured
allowlist of service names/status/exit codes/OOM/health failure counts/restarts;
it contains no raw log bodies, headers, query strings, environment or credentials.
Raw logs remain private and must not be published. Preserve these artifacts with
the report before explicitly deleting private run state.

Real-provider desktop checks: `KITH_OIDC_PASSWORD=true
KITH_OIDC_DATABASE_SUFFIX=_unique node scripts/oidc-local/browser.mjs` after starting
a matching fresh app/database with `restart-app.sh` and the same environment.
The restart script remains attached; it uses the ownership gate and restarts only
Kith, retaining provider/proxy. Use a new suffix per full run: provider users persist
but Kith users must not. Run again with password false and another fresh suffix.
Do not overlap full runs. Private app-mode.json records the active policy/database.
The optional KITH_CASE substring runs a targeted case against an existing prepared
database; it does not satisfy a full fresh-run requirement.

The browser harness uses Chromium's ephemeral exact-leaf SPKI allowlist with local
resolver mappings, never ignoreHTTPSErrors. It reads disposable credentials only
from run.json, and emits safe case names/statuses. No screenshots/traces/videos or
saved cookies are created. Private browser-<policy><database-suffix>.json files hold per-run
safe case results and policy/database identity verified against the running app. Protocol observation in the TLS edge stores only booleans and
HTTP status for token exchanges; no code/verifier/token/header/claim values are
written. Successful Kith sessions prove its normal signature/claim validation ran;
proxy claim-shape booleans alone do not prove signature validation. consent.py applies and then disables an owned Authentik application access policy
for actual provider denial attempts (the provider renders denial with HTTP200). See the Task3
report for unresolved cases; a harness completion message does not imply all pass.

## Authentik2026.8.5 local freshness profile

This disposable profile intentionally requests actual provider credentials on
EVERY authorization, including ordinary login. It works around the pinned
provider's repeated prompt=login/max_age=0 behavior using supported Flow,
Identification, Password and User Login stages. No claim mapping fabricates
freshness, no upstream source is patched, and Kith's auth_time validation stays
unchanged. The dedicated authorization flow has three unconditional stages, only
the built-in database password backend, and User Login terminates no other
sessions. Provider MFA is not configured for these synthetic users; Kith local
TOTP remains independently required. Future up.sh provisioning snapshots original
flow references/callbacks once and applies this stronger local authorization flow.
consent.py restores this dedicated profile when returning to implicit mode.

Use freshness-profile.sh snapshot|apply|restore through ownership-gated Compose.
Snapshot refuses overwrite. restore sets exactly the saved original flow IDs and
callbacks; it preserves dedicated stages for review/reapplication. These commands
change the shared test provider, so coordinate with any active browser/device
worker first. Never use provider logout or clear browser cookies to hide a
freshness failure.

Desktop regression runs a separate test app on8464/8465, leaving8444/8445 and the
Android fixture untouched. Register the additional exact callback
https://kith.test:8464/auth/oidc/callback on the owned client, retaining its normal
callback. Start freshness-app.sh with KITH_OIDC_PASSWORD=true|false and a short
unique KITH_OIDC_DATABASE_SUFFIX=_fresh_<suffix>; PostgreSQL identifiers must fit
63 bytes. The server fails clearly on oversized names instead of silently sharing
a truncated database. The freshness runner uses generated provider user3 and an
ephemeral desktop browser; it never attaches to Android or clears provider cookies.
Run node scripts/oidc-local/freshness.mjs with matching policy/suffix. Both delayed
repetitions wait65 seconds and require real credential submissions, local MFA and
the Security return destination. Traces/screenshots/storage-state dumps are absent.

To reproduce the original provider defect first, coordinate restoration to the
saved baseline, remove only the stale freshness-profile-ready marker, and set
KITH_FRESHNESS_RED=1 for a fresh isolated DB. The runner performs a first sensitive
credential+MFA exchange, waits65 seconds, and verifies old provider auth fails
closed on the repeated request with no credential challenge. It preserves the
same browser/context while awaiting freshness-profile.sh apply, then retries real
credentials/MFA and two further65-second repeated exchanges. Keep the app runner
attached, preserve private result JSON, and stop only its recorded exact process
identity after review. This is desktop provider evidence, never Android evidence.

freshness-process.py records the separate app PID/start/absolute command/run marker
and requires that PID to own desktop port8464. Its stop action checks the exact
saved identity and preserves the shared8444 process. KITH_FRESHNESS_LINK_ONLY=1
runs signup/enrollment plus a65-second retained-session explicit-link check; the
normal regression runs two65-second reauth repetitions and then that link check.
All link cases use actual fresh provider credentials and Kith local MFA, asserting
two identities on the original local owner. Use a fresh short database suffix per
run, never reuse a completed enrollment dataset as a fresh-signup case.

Long manual Android runs can opt into `KITH_OIDC_POOL_SIZE=16` and
`KITH_OIDC_OWNERSHIP_TIMEOUT_MS=600000` when starting or restarting the owned
test app. Defaults remain 4 connections and 120000 ms. These options affect
only the isolated test harness; record them with each run and do not interpret
a database checkout failure before provider departure as provider acceptance.
