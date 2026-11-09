# OpenID Connect operations

Kith supports one operator-configured issuer through standard discovery. Authentik
is an interoperability target, not a special adapter. Actual Android Chrome,
DAVx5 and live Authentik acceptance is **NOT RUN**; see the
[acceptance record](../design/oidc-validation/acceptance.md).

## Register and enable

Register a confidential web client at your issuer. Register exactly
`https://YOUR_KITH_HOST/auth/oidc/callback`, including the external hostname,
port if nonstandard, and HTTPS scheme. No wildcard callback, implicit flow,
`form_post`, dynamic registration or user-selected issuer is supported.

```dotenv
OIDC_ENABLED=true
OIDC_ISSUER=https://identity.example/application/o/kith/
OIDC_CLIENT_ID=kith
OIDC_CLIENT_SECRET_FILE=/run/secrets/oidc_client_secret
OIDC_DISPLAY_NAME=OpenID Connect
PASSWORD_LOGIN_ENABLED=true
REGISTRATION_ENABLED=true
# If DISABLE_SIGNUP is also supplied, it must be false for the setting above.
```

Use the exact issuer string published in discovery, including its path and trailing
slash. Kith requests discovery at the issuer with its trailing slash removed plus
`/.well-known/openid-configuration`; metadata must report exact issuer equality.
The client needs authorization code/query responses, `client_secret_basic`, RS256
ID tokens, S256 PKCE and scopes `openid email profile`. Unsupported advertised
capabilities fail closed; no algorithm/authentication downgrade occurs. If a
UserInfo endpoint is advertised it must return the same subject as the ID token.
Do not claim compatibility with a provider until testing this profile.

`OIDC_CLIENT_SECRET` can be supplied directly instead. `_FILE` takes precedence,
reads a mounted file and trims surrounding whitespace. Missing, empty or unreadable
secrets fail startup with a redacted error. Mount only the required secret into
app/worker containers; never commit it. Other credentials are ignored when OIDC is
disabled. All policy booleans require literal `true` or `false`; blank is invalid.
See [configuration](../configuration.md#authentication-policy) for defaults,
legacy registration agreement and passkey capability configuration.

Serve Kith over HTTPS. Discovery, authorization, token, JWKS and any UserInfo
endpoints must use HTTPS; private-network issuers are allowed. Their certificates
must verify against a CA trusted by the runtime HTTP client, with matching hostnames.
Provision the private CA through your deployment's supported runtime trust setup
and test it from the app container. There is no environment flag to disable
verification or a production HTTP exception. The test fixture's `cacertfile` and
Chromium SPKI configuration are isolated test mechanisms, not deployment switches.
Metadata HTTP requests do not follow redirects or retry; use final endpoint URLs.
Restrict operator access to issuer configuration and outbound network access.

## Identity, signup and sensitive actions

Identity is exact `(issuer, subject)`, independent of legacy Google/GitHub identities.
Matching email never links accounts. An existing user must sign in, visit
**Settings → Security**, authenticate recently, and explicitly link. Local TOTP
still applies after provider authentication. A collision requires existing-account
authentication; it does not transfer ownership. Later provider profile changes are
not automatically synchronized. Unknown identities can create a personal account
only with registration enabled, a usable email and boolean `email_verified=true`,
and explicit configured terms acceptance. External roles/groups confer no membership
or privilege. Changing issuer does not migrate old identities.

Sensitive actions require completed authentication within 600 seconds, including
local MFA where enabled. OIDC linking and reauthentication request `prompt=login` with `max_age=0` and validate
`auth_time` against initiation (60 seconds skew); a remembered Kith session alone
cannot satisfy it. Unlink refuses to remove the last usable interactive method under
current deployment policy; DAV credentials do not count. No provider tokens are
retained for later API use.

## Browser, proxy and logging boundary

The main session stays SameSite=Strict. A signed opaque `__Host-kith_oidc` binding
cookie is Secure, HttpOnly, Path=/, SameSite=Lax. Query/GET callbacks correlate a
single-use server transaction expiring in 300 seconds. The clean local completion
page commits a same-site document before protected navigation so Chromium can send
the Strict session. Parallel tabs are independent; explicit local logout cancels
pending flows. Link/reauthentication begin through CSRF-protected POSTs bound to
the initiating user and still-valid originating session.

Configure proxies/CDNs/analytics to omit callback queries and auth request bodies,
Cookie, Set-Cookie, Authorization and Location headers. For nginx access logs use
`$uri`, not `$request` or `$request_uri`, for authentication paths. Do not capture
auth traces, storage state, one-time password screens, codes, provider error
responses or tokens. Application/Sentry filtering cannot remove an upstream log.
Keep callbacks and credential pages uncached; preserve no-store/no-referrer headers.

## Outage and recovery

Connect timeout is 3 seconds; each HTTP response has a 5 second total budget.
Successful discovery/JWKS cache freshness is at most 300 seconds (shorter provider
cache directives apply). An unknown key ID triggers one refresh; expired/failed
fetches cannot fall back to stale keys. A warm cache may allow validated logins
until expiry, but token/UserInfo network access is still necessary. Unavailability
shows generic temporary failure; restart the login after recovery. It never enables
a disabled password fallback. Expired transactions/challenges are rejected even if
cleanup is delayed; production worker cron purges them every five minutes.

Before disabling passwords, verify users have usable configured interactive methods
and test recovery. Startup only checks deployment capability, not each user's
credentials. To recover a configuration lockout, restore a known-good issuer/client
or enable password login and restart/recreate app and worker with consistent
configuration. Existing passwordless users still need their actual supported method;
enabling passwords does not manufacture a password. Do not delete identities or
reset the database to repair configuration. Provider outage does not require schema
rollback. Kith logout is **local only**: disabling a provider user does not revoke
Kith sessions, API bearer tokens or DAV app passwords. Revoke those separately via
your supported account/credential operations. Disabling passwords also leaves
existing bearer tokens/sessions valid and blocks outstanding password reset redemption.

## Migration and rollback

Back up the database and test restore before upgrading. Apply the normal deployment
migration command, then restart app/worker together. New tables are
`dav_app_passwords`, `oidc_transactions`, `oidc_identities`, `auth_challenges`;
`users.hashed_password` becomes nullable and `user_tokens.mfa_authenticated_at` is
added. Existing hashes, tokens, legacy social identities and DAV data are preserved;
no identity or credential backfill is performed. Old sessions have no manufactured
recent-MFA evidence and must reauthenticate for sensitive operations.

The reverse of `20261109195100_allow_oidc_passwordless_users.exs` restores NOT NULL
and **fails while any OIDC-only user has a NULL password hash**. This is an expected
rollback constraint, not a reason to fill hashes with placeholders, delete users or
invent credentials. Prefer fixing forward or disabling the feature through
configuration while retaining the compatible schema. Before a deliberate downgrade,
stop writers, retain a full backup, inspect NULL hashes without exporting credentials,
and plan supported, user-authorized credential enrollment/recovery for every affected
user. If that cannot be completed, restore a verified pre-upgrade backup into an
isolated recovery deployment and reconcile post-backup data explicitly. Returning
old code against new passwordless users is not a safe assumed rollback. Dropping
feature tables loses links, app passwords and pending flows. Never roll back/reset
a shared database to run acceptance tests; see the isolated migration evidence.
