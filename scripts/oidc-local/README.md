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
