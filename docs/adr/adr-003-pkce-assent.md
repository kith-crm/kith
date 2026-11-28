# ADR-003: PKCE OAuth via Assent

**Status:** Superseded for dedicated provider login by the [generic OIDC decision](../superpowers/specs/2026-11-09-oidc-dav-app-passwords-design.md). Assent and S256 PKCE remain in use.
**Date:** 2026-03-17

## Context

Kith supports social OAuth login (GitHub, Google). Mobile app clients cannot securely store a client secret, making PKCE (Proof Key for Code Exchange) mandatory for those flows. We needed to confirm that our chosen OAuth library supports PKCE before committing to it.

## Decision

Use the `assent` library for all social OAuth flows, configured with PKCE (`code_challenge_method=S256`). `phx_gen_auth` handles session/password authentication; `assent` handles third-party OAuth providers.

## Verification Checklist

Before shipping OAuth login to production, the following must be confirmed and checked off:

- [ ] assent supports PKCE code challenge generation
- [ ] assent supports `code_challenge_method=S256`
- [ ] Integration tested with GitHub OAuth end-to-end
- [ ] Integration tested with Google OAuth end-to-end
- [ ] PKCE flow works end-to-end in test environment (including code_verifier round-trip)

## Consequences

### Positive

- **PKCE support built-in:** `assent` is designed to support modern OAuth 2.0 features including PKCE, making it suitable for both web and future mobile clients.
- **Provider strategy pattern:** Adding new OAuth providers (Apple, Microsoft) requires only a new strategy module without restructuring the auth pipeline.
- **Composable with phx_gen_auth:** `assent` integrates alongside `phx_gen_auth` without replacing it; password and social auth coexist cleanly.
- **TOTP and WebAuthn path:** `pot` (TOTP) and `wax` (WebAuthn) are layered on top independently, keeping auth concerns separated.

### Negative

- **Verification required before ship:** PKCE support must be manually verified against each provider during integration testing (see checklist above).
- **Additional configuration:** Each provider requires client ID/secret configuration and callback URL registration; more setup than a batteries-included solution.

## Alternatives Considered

| Alternative | Reason Rejected |
|---|---|
| ueberauth | Popular but PKCE support varies by strategy plug; inconsistent across providers; less actively maintained for newer OAuth 2.0 features |
| Custom OAuth client | Full control but high implementation cost; reinvents token exchange, PKCE generation, and provider normalization already solved by `assent` |
