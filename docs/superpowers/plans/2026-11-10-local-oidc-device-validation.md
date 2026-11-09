# Local OIDC, Android and DAVx5 validation

Execute after feature HEAD `f8048bab163750feb4458d8389dbff05237f5115` in the existing Kith worktree. The user authorizes local Docker/emulator setup and validation, including disposable installs and test trust configuration. No deployment, shared-container replacement, production identity configuration or unrelated data deletion.

Use Superpowers subagent-driven development: fresh implementer per task, independent spec/quality review per task, final review of setup changes and evidence. Existing feature spec and acceptance criteria remain binding. Keep an ignored plan-owned ledger with BASE/HEAD, commands, outcomes, ownership and cleanup inventory. Never turn NOT RUN into PASS without actual execution.

## Task 1: Inventory and isolate

- Confirm branch/status, available disk/RAM, Docker engine, current emulator, browser/driver/DAVx5 versions and ports without exposing credentials.
- Existing `kith-mobile-audit-app-1` mounts another worktree: preserve it. Use a separate Compose project, dedicated databases/volumes and unoccupied ports for this branch.
- Record agent device access prerequisite. Device integration currently refuses access; do not bypass that restriction with ADB or another device-control route. Continue independent Docker/provider work while the user enables access. Resume device tasks only with available authorized integration/session.
- Record every created resource and original device state. Prefer a disposable emulator clone/snapshot; do not wipe the existing emulator or overwrite existing client accounts.

## Task 2: Reproducible local services and trust

- Add a repeatable test-only harness for isolated Kith plus real pinned Authentik server/worker/PostgreSQL, following official upstream deployment/configuration documentation. Reuse existing Kith fixture support only for controlled seeding; real-provider results must redeem Authentik-issued codes and signed tokens.
- Generate throwaway secrets into ignored restrictive files; never commit or print secrets. Do not mount Docker socket for unused outpost management. Record pinned image versions/digests.
- Provide distinct app/fixture/provider HTTPS sites with exact hostname certificates. Validate reachability and verified TLS from host, Kith runtime, containers and Android. Configure narrowly scoped test DNS/routing and disposable-device CA trust; no TLS bypass, production verification exception or host-wide trust change.
- Provision confidential OIDC client, exact callback, code/query, RS256, S256 PKCE, openid/email/profile, suitable verified-email claim and provider freshness. Use generated disposable users. Check actual discovery capabilities; fail clearly on incompatible configuration.
- Health/readiness checks must identify the owned run. Teardown touches only owned resources; preserve sanitized failure diagnostics and inventory before removal.

## Task 3: Real Authentik interoperability

- Run with password login enabled, then disabled in a fresh Kith process/database.
- Through actual provider redirects test initial signup/terms, returning login, local TOTP/wrong code/recovery, explicit linking/collision/no takeover, unlink/last-method guard, max_age/auth_time fresh-auth round trip and Contact sync credential creation.
- Observe code/PKCE/client authentication and real signed metadata/token validation without recording tokens, codes, cookies or secrets. Do not adapt application behavior to Authentik by provider name or weaken the approved profile.
- Test denial/unavailability/recovery where controlled locally. Record provider/browser versions and PASS/FAIL per actual case. Fix discovered application defects test-first and obtain independent review.

## Task 4: Actual Android Chrome

- Once device integration is enabled, provision trusted-source compatible Chrome and Playwright driver on a disposable emulator; record Android/build/browser versions and provisioning source. Use emulator control through the supported device integration/CLI.
- Run `scripts/android/oidc-chrome.mjs` against reachable trusted distinct-site fixture deployments in both password modes. Extend infrastructure/runner only as necessary; no preinstalled authenticated cookies or fake provider completion.
- Execute the manual acceptance subset through actual device interaction: redirect/callback/session continuity, cancel/back/history, TOTP/recovery, explicit link/unlink/last-method rejection, fresh auth and return destination, native Settings selector, keyboard opening/occlusion, focus/touch targets, copy fallback, one-time reveal/reload/revoke.
- Exercise real Authentik on Android too, clearly separating controllable-fixture cases from live-provider evidence. Capture only sanitized screens after credentials disappear; avoid automatic secret-bearing screenshots/traces/UI dumps.

## Task 5: Actual DAVx5 interoperability

- Use the installed DAVx5 on the authorized disposable emulator with Contacts permissions and synthetic contacts. Record exact client version and TLS setup.
- In both password modes create two independently named credentials, configure actual DAVx5 clients/profiles, discover the address book, sync, and verify actual subsequent authenticated requests.
- Create/edit/delete synthetic contacts both directions; test viewer read-only behavior and cross-account denial. Record sanitized method/path/status and visible outcomes.
- Revoke A in Kith with fresh auth/MFA; force a new DAVx5 request and observe 401/client authentication failure, while independently configured client B still syncs. Test account-password success only when enabled, active app-password success in both modes, web/API rejection.
- Protocol probes alone do not prove DAVx5 behavior. Keep unexecuted cases explicitly outstanding.

## Task 6: Evidence, checks and cleanup

- Update Android/provider acceptance records with dated environment, versions, exact commands and actual PASS/FAIL/NOT RUN for every criterion; replace stale prerequisite claims while preserving historical checkpoints.
- Run focused tests for changed harness/application behavior, required repository quality/security checks and full ExUnit before each commit. Review all secret handling and test-only route boundaries. Obtain independent final review.
- Stop only run-owned services, revoke disposable credentials, remove only created test client accounts/data and transient private keys. Restore any changed emulator DNS/CA/configuration or retain an explicitly documented isolated disposable validation environment for reproducibility.
- Report validated behavior, remaining gaps, exact commits, evidence paths and any retained local resources. No push/PR/merge/deploy.

## Primary references

- https://docs.goauthentik.io/install-config/install/docker-compose/
- https://docs.goauthentik.io/install-config/automated-install
- https://docs.goauthentik.io/add-secure-apps/providers/oauth2/
- `docs/design/oidc-android-validation.md`
- `scripts/carddav-e2e/oidc-app-passwords-android.md`
- `docs/design/oidc-validation/task-10-acceptance.md`
