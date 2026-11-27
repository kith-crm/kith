# OIDC relying-party research

Researched 2026-11-09. Scope: Kith consumes an external OpenID Provider (OP); it does not issue identities or implement an OP. Research only; no implementation. Applied the research skill directly as the assigned research agent; no applicable repository/ancestor `AGENTS.md` was found.

## Baseline and recommendation

`mix.exs` specifies `{:assent, "~> 0.3.2"}` and `mix.lock` resolves **0.3.2**. Findings below concern that release, not current/latest docs. Existing integration points are `lib/kith_web/controllers/oauth_controller.ex`, `lib/kith/accounts.ex`, and `lib/kith/accounts/user_identity.ex`. The identity schema keys on `(provider, uid)` and encrypts stored tokens. OIDC needs an explicit binding between provider configuration and immutable issuer; a generic provider label alone cannot distinguish issuers.

Recommended Kith policy: confidential server-side authorization code flow, S256 PKCE, state and fresh nonce, approved providers only, explicit account linking, and local session ownership. Provider support, signup policy, local MFA requirements, and logout scope need product decisions before implementation.

## Protocol and callback boundary

- OIDC adds authentication to OAuth. Request `openid` plus only necessary profile/email scopes. Validate the ID token signature with the issuer's keys and a configured permitted algorithm; validate `iss`, `aud`, `azp` where applicable, expiry, issuance time policy and nonce before login. If requesting freshness using `max_age`, validate `auth_time`. UserInfo must have the same `sub` as the ID token. [Core §§3.1.3.7, 5.3.2](https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation).
- `(iss, sub)` is the stable identity; email can change or be reassigned. `email_verified: true` means the OP verified control at verification time; it does not establish ownership of a preexisting Kith account. [Core §§5.1, 5.7](https://openid.net/specs/openid-connect-core-1_0.html#ClaimStability).
- Use S256: transmit the verifier only to the token endpoint; PKCE binds redemption to the initiating client transaction. [RFC 7636 §4](https://www.rfc-editor.org/rfc/rfc7636.html#section-4). Use exact registered callback URIs, TLS, code flow and issuer mix-up defenses. PKCE is recommended for confidential clients too; do not silently downgrade when unsupported. [RFC 9700 §§2.1.1, 4.4](https://www.rfc-editor.org/rfc/rfc9700.html).
- Pin the configured issuer and verify discovery metadata `issuer` exactly matches it, then validate tokens against that issuer. Approve endpoints and HTTPS destinations; do not discover arbitrary user-supplied URLs. Discovery explicitly requires issuer consistency and TLS validation. [Discovery §§4.3, 7](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfigurationValidation).

Kith application requirements: persist a short-lived, browser-bound, single-use transaction containing expected provider/issuer, state, nonce, verifier, callback URI and login-versus-link intent. Reject missing, expired, mismatched or replayed transactions, including provider switches. Consume on callback/error; support parallel tabs deliberately. Protect the verifier with server-side storage or encrypted session storage, never a merely signed readable cookie. Rotate the local session after success, allowlist return destinations, and exclude tokens/codes/secrets from logs. These are proposed Kith controls informed by [RFC 9700 §§4.4–4.8](https://www.rfc-editor.org/rfc/rfc9700.html), not features supplied by Assent.

## Assent 0.3.2 capabilities and gaps

Source review, not runtime verification:

| Area | Release behavior / consequence |
| --- | --- |
| Code flow, state, PKCE | OAuth2 generates/checks state by default. `code_verifier: true` enables S256 and token redemption with the verifier; default is off. Kith must retain and restore `session_params`. |
| Discovery and JWT | OIDC fetches discovery/JWKS, checks required claims, signature, configured algorithm (default RS256), metadata issuer, audience, present `azp`, expiry and nonce. `iat` TTL is opt-in. |
| Nonce discrepancy | Documentation promises generation for `nonce: true`, but `add_nonce_param/2` and `add_nonce_to_session_params/2` copy the configured value. Supply a fresh random **string**; do not depend on boolean generation. |
| Identity claims | Default user claims come from the validated ID token; `iss` is stripped. `fetch_userinfo/2` is separate and checks subject equality. Preserve the trusted issuer separately. |
| Application gaps | Discovery does not compare metadata issuer to `base_url`; no transaction expiry/replay store, provisioning, linking or logout lifecycle is supplied here. |

Sources: tagged [OAuth2 implementation/docs](https://github.com/pow-auth/assent/blob/v0.3.2/lib/assent/strategies/oauth2.ex) and [OIDC implementation/docs](https://github.com/pow-auth/assent/blob/v0.3.2/lib/assent/strategies/oidc.ex). Avoid `none`, broadened trusted audiences, and disabled state. Supplement claim type/future-time/freshness checks and validate provider interoperability before shipping. Caching, HTTP timeouts, key rotation and adapter behavior need a separate implementation review.

## Linking, provisioning and authorization

Kith policy recommendations (identity rationale: [Core §5.7](https://openid.net/specs/openid-connect-core-1_0.html#ClaimStability)):

- Resolve returning users by exact issuer and subject; enforce database uniqueness and transactional creation. Either extend identity storage or bind an immutable provider configuration to one issuer. Never repoint a provider key to a different issuer while retaining its identities.
- Do not reuse the existing email-match linking path for generic OIDC. Require recent authentication to the existing Kith account and an explicit link intent bound to the transaction. Handle collisions without moving an identity between users; retain a recovery method when unlinking.
- If email is required for signup, require an actual boolean `email_verified == true` from an approved issuer or perform Kith's own verification. Missing/false claims must not auto-confirm email. Decide whether verified external email satisfies Kith confirmation policy; never overwrite local email silently.
- Provision only under explicit signup/invitation policy. Set local account membership, role, terms acceptance and MFA rules deliberately; never take arbitrary OP groups/roles as Kith privileges. In particular, review the current user schema's default `admin` role and account creation path.
- OIDC login does not provide ongoing deprovisioning. Disabling someone at the OP does not inherently revoke Kith sessions, API tokens or other login methods. Specify revocation timing and administrator controls; SCIM is a separate provisioning protocol, not part of OIDC login. [RFC 7644 §§1, 3](https://www.rfc-editor.org/rfc/rfc7644.html).

## Logout and token lifetime

Always invalidate the Kith session locally. If supported, offer a distinct provider logout using discovered `end_session_endpoint`, an `id_token_hint`, registered `post_logout_redirect_uri`, and correlated logout `state`. Local logout alone does not terminate the OP's SSO session; provider logout may affect other applications. Retain an ID token securely only if this feature needs it. [RP-Initiated Logout §§2–3](https://openid.net/specs/openid-connect-rpinitiated-1_0.html).

OP-initiated logout requires a separate integration. Back-channel logout needs signed Logout Token validation, issuer/audience/time/events checks, replay handling, and mapping `sid` or subject to revocable local sessions; ordinary ID-token validation is insufficient. [Back-Channel Logout §§2.4–2.7](https://openid.net/specs/openid-connect-backchannel-1_0.html).

For login-only use, avoid retaining access/refresh tokens without a concrete need. If retained, define encryption, rotation, revocation and deletion policies. A refreshed token or an unexpired ID token must not bypass local suspension or replace the Kith session policy. [RFC 9700 §2.2](https://www.rfc-editor.org/rfc/rfc9700.html#section-2.2).
