# Generic OIDC and DAV app passwords

**Source:** User discussion and approved scope, 2026-11-09.
**Status:** Written design for review; implementation has not started.
**Research:** [OIDC standards and Assent 0.3.2 findings](../../design/oidc-research.md).

## Goal and scope

Allow operators to opt into standards-based OpenID Connect login, independently disable account-password authentication, and control registration. Provide DAV app passwords so people using external login can sync contacts without enabling account passwords. Deliver backend, responsive UI, and meaningful desktop, mobile, and Android validation together.

Kith acts as an OIDC relying party. Authentik is the user's provider, not a special implementation target. Support providers through standard discovery and a documented interoperability profile, with no provider-name branching. Existing Google/GitHub visibility and UI configuration work is explicitly excluded and tracked in [issue #62](https://github.com/kith-crm/kith/issues/62). Passkeys and existing social login retain their behavior.

## Approach and boundaries

Extend the existing Assent integration through a dedicated OIDC transaction boundary, keeping protocol handling separate from local account policy. Reuse Kith sessions and MFA rather than creating another session system. Add a separate DAV credential type rather than repurposing API tokens or storing recoverable app passwords.

Alternatives considered: a provider-specific adapter would narrow interoperability unnecessarily; implementing OIDC/JWT cryptography ourselves would duplicate maintained library behavior. Retain Assent where its pinned release satisfies the profile, supplementing the verified gaps described in the research. Any dependency update requires its own source and regression review.

Configuration validation owns operator settings. The OIDC boundary owns discovery, transaction lifecycle, and validated identity claims. Accounts owns provisioning, linking, local MFA completion, and credential ownership. DAV authentication accepts credentials only within its existing account-scoped authorization boundary. Controllers and LiveViews translate these outcomes into navigation and accessible feedback.

## Operator configuration

| Variable | Default | Contract |
| --- | --- | --- |
| `OIDC_ENABLED` | `false` | Enable the OIDC button and server endpoints. |
| `PASSWORD_LOGIN_ENABLED` | `true` | Permit account-password authentication for web login, API token issuance, and DAV. |
| `REGISTRATION_ENABLED` | `true` unless legacy signup disabling applies | Permit public creation of new users/accounts, including OIDC. |
| `OIDC_ISSUER` | Unset | Exact HTTPS issuer URL, including any path. Required when enabled. |
| `OIDC_CLIENT_ID` | Unset | Registered confidential client ID. Required when enabled. |
| `OIDC_CLIENT_SECRET` | Unset | Client credential. Required when enabled; never exposed to UI/logs. |
| `OIDC_DISPLAY_NAME` | `OpenID Connect` | Escaped operator label for the login button. |

Parse boolean variables strictly as `true` or `false`; reject invalid supplied values. Preserve `DISABLE_SIGNUP` compatibility: when only the legacy variable is supplied, registration is its inverse; when both registration variables are supplied, require agreement or fail startup. Resolve one registration policy for new registration/OIDC paths without altering existing Google/GitHub behavior.

Password disabling blocks account-password login and password-authenticated API token issuance, hides/disables password recovery and rejects outstanding reset-token redemption while disabled. Existing API tokens and authenticated sessions remain valid under their existing policies; this switch is not global revocation. DAV app passwords remain usable. Ordinary account passwords remain usable for DAV only while password login is enabled.

Fail startup for incomplete enabled OIDC settings, invalid booleans/URLs, contradictory registration settings, or no deployment-configured interactive login mechanism after disabling passwords. Count configured external providers or explicitly enabled passkey capability, not DAV credentials or existing sessions; do not claim this check proves every user has a usable credential. Document operator recovery by restoring environment configuration. Keep network discovery failures separate from malformed local configuration: time out safely and show temporary unavailability at login, never bypass validation or fall back to passwords when disabled.

## OIDC interoperability and validation

Use confidential-client authorization code flow, HTTPS, exact registered callback URIs, scopes `openid email profile`, S256 PKCE, unpredictable state, and a fresh random string nonce. Do not enable implicit flow, unsigned ID tokens, dynamic client registration, user-entered issuer URLs, or provider-specific claim assumptions. Document supported token endpoint authentication and signing algorithms; start with `client_secret_basic` and RS256, and clearly report unsupported advertised capabilities instead of silently downgrading.

Bind configured issuer to discovery metadata with exact issuer equality. Preserve trusted issuer separately because Assent's normalized claims omit it. Validate signatures against discovered keys, issuer, audience, authorized party where required, expiration, issuance-time policy, nonce, required claim types, and UserInfo subject equality if UserInfo is used. Enable PKCE explicitly; generate nonce strings rather than relying on the pinned release's boolean nonce option. Define bounded network timeouts and clock skew in the implementation plan and test their boundaries. Validate key rotation without accepting arbitrary token-supplied key URLs or algorithms.

Discovery URLs are operator-controlled, not accepted from login parameters. Permit private-network HTTPS issuers for self-hosting; do not impose a public-IP-only rule. Retain TLS certificate verification and constrain redirect/destination handling so discovery cannot change the expected issuer or leak credentials.

Store short-lived, browser-bound, single-use transactions containing state, nonce, verifier, expected issuer, callback URI, login/link intent and the initiating user for links. Proposed transaction lifetime: five minutes. Consume transactions atomically before redemption; retries require restarting login. Permit independent concurrent tabs without overwriting another transaction. Error callbacks also require transaction correlation and cleanup. Reject missing, expired, replayed or provider-switched transactions.

The current encrypted session cookie has `SameSite=Strict`; it cannot be assumed to accompany an external provider callback. Use a narrowly scoped, Secure, HttpOnly, SameSite=Lax transaction cookie with opaque browser binding and server-side transaction storage for GET/query callbacks, retaining the main cookie policy. Complete login/link using the validated transaction, then rotate the local session. Do not rely on a current-user assign at the external callback to establish link ownership. Do not support `form_post` callbacks in the initial profile. Authorization codes may appear only in the standard callback query; promptly redirect to a clean local URL. Never put verifiers, tokens or secrets in URLs, and exclude all codes and credentials from application/proxy logs, analytics and rendered errors. Redirect only to approved local destinations.

## Identity ownership, registration and MFA

Identify OIDC users by exact `(issuer, subject)`, enforced by database uniqueness. Store these separately from legacy social identity keys, or extend identity storage with an unambiguous identity-kind/issuer model; the implementation must preserve all existing social identities. Changing the configured issuer must never transfer old identities to a new issuer.

Returning linked identities resolve to their existing Kith user. Never link or merge accounts solely through an email match, including a verified email match. Collisions tell the person to authenticate to the existing account and explicitly link in settings, without exposing account details. Linking requires recent local authentication, explicit intent bound to that user and transaction, and local TOTP if enabled. Reject an identity already owned by another user; do not silently switch the active account. Unlinking must not remove the last usable interactive login method under the deployment's active policies. An app password is not an interactive recovery method.

Unknown identities may register only when registration is enabled. Require a usable email with actual boolean `email_verified == true` for automatic OIDC provisioning; reject missing/unverified email with an actionable message, rather than silently confirming it. Provision account, user, and identity atomically with uniqueness-race handling. Follow Kith's existing personal-account model: the new user administers only their newly created account. Never infer membership in an existing account or privileges from external groups/roles. Preserve configured terms acceptance requirements through an explicit completion screen before account creation. Do not silently synchronize later email/profile changes.

OIDC proves the first authentication factor. If local TOTP is enabled, retain a pending login and grant no fully authenticated Kith session until TOTP or an existing permitted recovery-code flow succeeds. Apply challenge expiry and rate limits. Only completed authentication establishes recent-authentication status. Fresh-authentication flows must be available to OIDC-only users, requesting/validating provider freshness (`max_age`/`auth_time`) and then local MFA; an old Kith session or remembered provider session alone is insufficient.

## DAV app passwords

Add user-owned, named credentials with an identifier, one-way secret hash, creation timestamp, revocation timestamp and optionally coarse last-used time. Generate at least 256 bits of cryptographic randomness and show the full credential once after creation. Store no plaintext or decryptable secret. Use a distinct format with a public lookup identifier and secret; hash the random secret with a standard cryptographic hash and compare in constant time. Never fall through to account-password handling for malformed or revoked app-password-format inputs.

Settings provide creation, one-time display/copy, list, and explicit revocation with success/error feedback. Require recent authentication and local MFA for creation and revocation. Users may manage only their own credentials; scope server-side lookups accordingly. Render labels as escaped text, enforce nonempty bounded names, and never reveal another user's credential metadata. Allow multiple named credentials so clients can be revoked separately. Initial credentials have no automatic expiry; revocation is explicit.

Authenticate DAV Basic Auth with the existing email username plus app password, binding both to the same confirmed Kith user. App passwords grant that user's existing DAV permissions, never broader account access. Check revocation on every request; the next request after revocation fails. Reuse existing failed-authentication throttling and generic unauthorized responses. Do not require an interactive TOTP challenge per DAV request. Deleting a user invalidates/removes their credentials. App passwords must fail on web login, API token issuance, and other non-DAV authentication paths.

When password login is enabled, preserve existing DAV account-password compatibility. When disabled, reject account passwords for DAV while accepting active app passwords. Do not change existing Google/GitHub or passkey behavior as a side effect.

## UI and lifecycle

Show the configured OIDC login option only when enabled; hide password login/recovery controls when disabled and registration links when registration is disabled. Enforce every policy on the server even for direct requests. Include pending, cancel, provider denial/unavailability, invalid callback, verification failure, collision, signup-disabled, MFA, and successful return states. Settings show the linked OIDC identity with the operator label and safe account information, plus link/unlink actions and DAV credential management.

Provide keyboard-operable controls, accessible names/errors, visible focus, and layouts without horizontal overflow at phone widths. Credential copying must report failure and retain a selectable one-time value for manual copy. Do not persist the revealed secret in browser storage or redisplay it after reload/navigation. Make the DAV server URL, username, and app-password instructions discoverable beside credential creation.

Logout ends the Kith session. Provider-wide logout, back-channel logout, SCIM, role/group mapping, multiple simultaneous generic issuers, and automatic external deprovisioning are excluded. Clearly document that disabling someone at the issuer does not revoke existing Kith sessions, API tokens, or DAV credentials. Avoid retaining access/refresh/ID tokens after login unless a concrete implemented function needs them; initial login-only scope does not.

## Verification and acceptance

Coverage measures security boundaries and completed journeys, not a line-percentage target. Every requirement below needs a positive case and relevant rejection/boundary cases. Backend policy tests must call direct endpoints/context functions rather than relying on hidden UI controls.

| Layer | Required evidence |
| --- | --- |
| Configuration | All independent enable/disable combinations, defaults, legacy compatibility, contradictory/invalid values, incomplete OIDC and unusable deployment configuration. |
| Protocol | Local controllable OIDC server with signed tokens and JWKS; actual authorization/token requests; PKCE verifier binding; state/nonce/issuer/audience/signature/algorithm/expiry/type failures; parallel tabs, transaction replay/timeout/provider-switch, cancellation, network errors and key rotation. |
| Accounts/MFA | Existing identity login, no email auto-link, explicit link ownership/collision, concurrent signup, disabled signup, verified-email enforcement, terms, account isolation, no external privilege mapping, MFA gating/recovery/expiry/rate limits, fresh auth and last-method unlink prevention. |
| DAV credentials | Hash-only persistence, one-time response, owner scoping, malformed credential handling, email ownership binding, create/revoke with recent auth/MFA, immediate revocation, rate limiting, deletion, no non-DAV use, compatibility with enabled/disabled account passwords. |
| Desktop browser | Real redirect round trip through a separate-origin OIDC fixture using browser cookie behavior, MFA, signup/link/unlink, app-password management, direct policy bypass attempts, accessibility and failure recovery. |
| Mobile viewport | Complete browser journeys at phone widths, touch-sized usable actions, no overflow, error readability, keyboard/focus and copy fallback. A viewport test is not Android evidence. |
| Android browser | Actual Android Chrome on a device or emulator: provider redirect/callback cookies, session continuity, MFA, linking and app-password management. Record OS/browser versions and whether device or emulator. |
| Android DAV | DAVx5 on device or emulator: configure using app password, initial sync and authenticated subsequent requests, contacts read/write under existing permissions, revoke and observe next request fail; verify both password-login settings. Record client version and TLS setup. |

Run focused Elixir tests and relevant Playwright journeys, then repository-required compile/format/static checks and full regression tests. Preserve existing non-OIDC auth/DAV test coverage. Do not replace browser round-trip tests with preinstalled session cookies. Include generic fixture interoperability plus an Authentik smoke test where a test deployment is available, without introducing Authentik-dependent application behavior. Additional standards-compatible provider checks are useful evidence, not a claim of universal compatibility.

Report commands, results and exact environments. If Android, DAVx5 or live-provider infrastructure is unavailable, document the unverified acceptance criteria explicitly and keep that validation outstanding; desktop emulation must not be presented as passing Android coverage. Never use production credentials/data for testing.

## Delivery boundary

Implement configuration and policy, OIDC backend/UI, and DAV credentials backend/UI as reviewable slices with their tests. Include environment examples, deployment/migration notes, issuer registration/callback instructions, operator recovery and DAV setup documentation. Preserve legacy identities and credentials without a destructive backfill. Google/GitHub UI changes remain in issue #62. This design is the source for a subsequent detailed Superpowers implementation plan after written-spec review.
