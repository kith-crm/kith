# Distinct-site OIDC browser harness

Run `bash test/playwright/fixtures/oidc/run.sh` from the repository. PostgreSQL,
compiled test dependencies/assets and Playwright Chromium must be installed.
The maintained CI browser job runs this command after the ordinary regressions.
No external identity-provider account, mail service or shared development server
is used. Missing infrastructure or failed readiness fails the command.

The runner creates four fresh app processes and dedicated databases: password
and registration enabled, registration disabled, password disabled, and both
password and registration disabled. OIDC remains enabled. Each process owns
its normalized configuration; tests run serially with zero retries. `OIDC_MODES`
can select a mode for diagnosis; the default command runs every required mode.
Playwright arguments are forwarded, for example `--grep 'local MFA'`.

The actual browser visits HTTPS `kith.test` and HTTPS `issuer.test`, which are
different sites. Chromium receives a process-local resolver map and an SPKI
allowlist for the ephemeral test certificate only. Backend and Node requests
verify the private CA and hostname. There is no `ignoreHTTPSErrors`, system DNS
edit, global trust change, or production TLS exception. The CA, private keys,
fixture temporary directories and browser profiles are removed on teardown.
`OIDC_PORT` and `OIDC_ISSUER_PORT` default to 4149/4150. Occupied ports fail
preflight; readiness verifies both owned process liveness and run identity.
Teardown stops only owned processes and drops only the run's newly created DB.

The app wrapper and protected control plug live entirely in these test scripts,
which refuse to run outside `MIX_ENV=test KITH_OIDC_E2E=1`. Neither is compiled
into production. A random per-run bearer token guards both readiness and
controls. Controls seed confirmed test users, optional MFA/recovery codes,
claims, denials/timeouts, expiration, session revocation, and JWKS rotation.
Policy changes require a fresh process. Controls never install browser sessions.
`beginOidcLogin(page)` clicks the real UI and the issuer's Authorize button;
the shared `Kith.OIDCFixture` issues signed tokens after single-use code
redemption with actual PKCE, confidential-client and exact redirect checks.
Protocol-only DAV probes use the private CA, avoiding browser Basic Auth dialogs.

Security specs disable traces, automatic screenshots and videos and close pages
before failure context collection. Assertions avoid printing cookie/token/secret
values. Explicit PNGs under `tmp/oidc-browser/safe-*.png` show setup details or
revoked credentials after plaintext display has gone. Logs contain no control
bodies, callback queries, authorization headers or generated credentials. Do not
add traces, storage-state dumps or secret-page screenshots for debugging.

Desktop widths are 1366/1440; phone viewports are 320/375/393. These are desktop
Chromium viewport simulations, not Android Chrome, DAVx5 or live Authentik
validation. Those external acceptance criteria remain outstanding.
