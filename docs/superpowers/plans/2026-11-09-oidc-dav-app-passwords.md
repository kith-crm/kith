# Generic OIDC and DAV App Passwords Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. The user explicitly selected subagent-driven development. Steps use checkbox (`- [ ]`) syntax for tracking. This request creates the plan; it does not start implementation.

**Goal:** Deliver optional generic OIDC, independent authentication policies, DAV app passwords, and the approved uncluttered settings UI with meaningful cross-platform validation.

**Architecture:** Retain Phoenix sessions, Assent and local MFA, but isolate OIDC protocol transactions from identity/account decisions. Store issuer-bound identities, single-use authentication transactions and hashed DAV credentials in dedicated tables. Reuse the shared settings shell with grouped navigation and separate Profile, Security and Contact sync destinations.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Ecto/PostgreSQL, pinned Assent 0.3.2, existing crypto and HTTP adapters, Alpine CSP, Playwright Chromium; actual Android Chrome and DAVx5 for device interoperability.

**Spec:** `docs/superpowers/specs/2026-11-09-oidc-dav-app-passwords-design.md`

**UI:** `docs/design/previews/show-me-settings-v2.html` (approved); `docs/design/previews/show-me-oidc-ui.html` (login/MFA only).

## Global Constraints

- Generic standards-based OIDC; Authentik is an interoperability target, not application branching logic.
- `OIDC_ENABLED=false`, `PASSWORD_LOGIN_ENABLED=true`; registration defaults enabled unless legacy disabling applies.
- Preserve `DISABLE_SIGNUP` compatibility and reject contradictory supplied registration settings.
- Other login methods retain their current behavior. Google/GitHub UI configuration/visibility work stays in issue #62.
- OIDC login still requires Kith TOTP when enabled; no fully authenticated session before completion.
- Identity is exact `(issuer, subject)`; never auto-link by matching email.
- Unknown OIDC identities require enabled registration, verified email and configured terms acceptance.
- App passwords grant DAV access only, are shown once and stored as hashes; next request after revocation must fail.
- Keep ordinary DAV account passwords working while password login is enabled; reject them when disabled.
- Keep existing Kith design tokens, components, app chrome, route permissions, account isolation and Alpine CSP.
- Group settings into Personal, Workspace and Data; mobile uses a labelled grouped destination selector.
- Never pass production secrets into fixtures, logs, snapshots or artifacts.
- Desktop/mobile viewport evidence is not Android evidence. Missing device infrastructure leaves acceptance outstanding.
- No destructive identity migration, provider logout/SCIM, automatic deprovisioning, external role mapping or new Google/GitHub/passkey management UI.

## Execution contract: subagent-driven development

The controller reads the spec and this plan, checks the isolated worktree, and uses the installed Superpowers SDD skill. Resolve that skill's location at execution; the current installation is `/Users/basharqassis/.codex/.tmp/plugins/plugins/superpowers/skills/subagent-driven-development/SKILL.md`.

- Create the plan-owned workspace with its `scripts/sdd-workspace PLAN_FILE`; keep `progress.md` with the plan path on line one. Record task bases, heads, reports, review verdicts, rulings, test results and outstanding external validation. Resume from that ledger after compaction.
- Before code changes, perform the SDD preflight review. Do not execute task 1 merely because this document was written.
- Dispatch one fresh implementer per task, with no inherited conversation history, a task-specific file brief, exact interfaces below, global constraints and report path. Workers do not delegate. Never run concurrent implementation agents against shared files.
- After each task, dispatch an independent task reviewer for **both spec compliance and code quality** using the complete recorded BASE..HEAD diff package. A worker self-review is insufficient. Handle fixes and scoped re-review before marking the task complete; follow current T3 orchestration rules for review dispatches.
- Specify models per SDD guidance: standard capable models for integration tasks, stronger judgment for protocol/MFA/concurrency and whole-branch review. Do not switch providers silently.
- Run a final whole-branch review after all tasks. Follow SDD's ledger, bounded fix loops and recovery rules. Small findings the controller can safely fix follow the higher-priority orchestration instructions, with checks and review evidence retained.
- No merge, publication, deployment or unrelated issue work is part of execution. Starting the plan does not authorize production configuration changes.

## Preflight and fixed technical decisions

Inspect existing files before changing them, especially `UserAuth`, `UserSessionController`, `UserToken`, `SettingsLayout`, `Integrations`, `TotpSetup`, `Kith.DAV.Auth`, browser fixtures and `Kith.ConfigHelpers`. Existing app-password verification wrappers and recent-auth timestamps must remain valid. Migrations use fresh timestamps from `mix ecto.gen.migration`, not historical names copied literally.

1. Use dedicated `oidc_identities`, `oidc_transactions`, `auth_challenges`, and `dav_app_passwords` tables. Keep legacy `user_identities` untouched. Use current integer user foreign-key conventions and `on_delete: :delete_all`.
2. Transaction expiry is **300 seconds**, fresh authentication **600 seconds**, clock skew **60 seconds**, maximum initial ID-token age **300 seconds**. Reject future `iat` beyond skew; fresh authentication requests `max_age=0` and validates `auth_time` against initiation with skew. HTTP connect timeout **3 seconds**, total response budget **5 seconds**; cap successful discovery/JWKS cache freshness at **300 seconds**, refresh once for an unknown `kid`, never use stale keys to bypass a failed check. Review actual Assent adapter behavior before implementing these limits.
3. Initial provider profile: HTTPS issuer/discovery/endpoints, code + query callback, confidential client `client_secret_basic`, RS256, S256 PKCE, `openid email profile`. Unsupported capability fails clearly; there is no downgrade or HTTP exception in production. Test HTTPS certificates are trusted only by the isolated test runner.
4. DB transactions make flow completion single-use across nodes. Store only hashes of state/browser-binding/challenge handles. Encrypt serialized transaction payloads using existing `Kith.EncryptedBinary` (JSON-encoded binary), never raw Elixir term decoding of untrusted data. The Lax binding cookie is opaque, `__Host-kith_oidc`, Secure, HttpOnly, Path=/, expires with the flow. Reuse binding across parallel flows; deleting it when one tab finishes must not break another tab. Main session cookie stays Strict.
5. OIDC callbacks do not assume the main cookie is present. Link/reauth transactions bind the initiating user and an encrypted existing session token; at completion check that session is still valid, user unchanged and flow authorized. Persist a local-only return destination. Never derive link ownership from email or a callback `user_id` parameter.
6. Introduce a first-class `Kith.Auth.Principal` struct, only constructed from verified protocol output: `issuer`, `subject`, `email`, `email_verified`, `name`, `auth_time`. Do not pass raw callback parameters to Accounts.
7. Challenge and transaction rows are consumed before their sensitive operation. Purge expired rows with the existing Oban infrastructure; expiry enforcement must not depend on cleanup running.
8. Fixtures use a real HTTPS issuer on a different hostname/site from the app (not just another localhost port) so SameSite behavior is exercised. No production verification bypasses.
9. Keep known shortcomings in old social callbacks outside this change; new password/OIDC completion shares the hardened challenge boundary without rewriting social behavior. Document that distinction.

## Ownership map and dependencies

| Unit | Responsibility | Tasks |
| --- | --- | --- |
| `Kith.Auth.Config`, `Kith.Auth.Policy` | Parse deployment settings; enforce method availability | 1 |
| `SettingsLayout`, `SettingsLive.Security` | Group navigation and relocate password form | 2 |
| `Kith.Accounts.DavAppPasswords`, DAV auth | Credential lifecycle, DAV-only verification | 3 |
| `SettingsLive.ContactSync` | Personal DAV details and one-time credential management | 4 |
| `Kith.Auth.OIDC`, transaction store, protocol fixture | Discovery, validated claims, correlation | 5 |
| `Kith.Accounts.OIDC` | Issuer identity ownership and provisioning | 6 |
| `Kith.Auth.Challenges`, web authentication completion | Local MFA, freshness and session rotation | 7 |
| `OIDCController`, login/security UI | Usable end-to-end OIDC/link/signup flows | 8 |
| Browser harness and regression specs | Real browser cookies and user journeys | 9 |
| Android runbook/evidence | Chrome and DAVx5 interoperability | 10 |
| Configuration/deployment docs and release checks | Whole-feature acceptance | 11 |

Execution order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11. Task 7 strengthens recent-auth guards introduced conservatively in tasks 2–4. No task is considered production-complete before dependent integration and final acceptance.

### Task 1: Authentication configuration and policy enforcement

**Files:**
- Create: `lib/kith/auth/config.ex`, `lib/kith/auth/policy.ex`, `test/kith/auth/config_test.exs`, `test/kith_web/auth_policy_test.exs`.
- Modify: `config/runtime.exs`, `config/config.exs`, `lib/kith/application.ex`, `lib/kith_web/controllers/user_session_controller.ex`, `lib/kith_web/controllers/api/auth_controller.ex`.
- Modify: `lib/kith_web/live/user_live/login.ex`, `registration.ex`, `forgot_password.ex`, `reset_password.ex` (all under `lib/kith_web/live/user_live/`).
- Modify docs: `docs/configuration.md`; extend the existing environment example file if present, otherwise create `.env.example`.

**Interfaces:**
- `Config.from_env!(env_map) :: map` returns `%{oidc_enabled: boolean, password_login_enabled: boolean, registration_enabled: boolean, oidc: nil | keyword}`; malformed configuration raises `ArgumentError` without secret values.
- `Config.validate_runtime!(config, capabilities) :: :ok` validates local setup and configured interactive mechanisms, without discovery calls or querying whether every user owns a credential.
- `Policy.password_login_enabled?()`, `Policy.registration_enabled?()`, `Policy.oidc_enabled?()` return booleans from normalized runtime config.
- Keep legacy `:disable_signup` equal to the inverse of normalized registration policy for existing readers; no separate conflicting policy path.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "contradictory signup settings fail closed" do
  assert_raise ArgumentError, fn ->
    Kith.Auth.Config.from_env!(%{
      "REGISTRATION_ENABLED" => "true", "DISABLE_SIGNUP" => "true"
    })
  end
end
```

Add a truth-table test over all eight flag combinations; legacy-only, new-only, agreeing/conflicting dual registration inputs; invalid/blank booleans and credentials; disabled OIDC ignoring unused credentials; issuer userinfo/query/fragment/HTTP rejection; valid HTTPS path issuer; credential redaction; unavailable interactive mechanisms. Use `ConfigHelpers.read_secret/1` for `OIDC_CLIENT_SECRET` and its `_FILE` convention. Test direct password POST, API token POST, reset request/redemption and registration events while disabled, including tokens issued before disabling. Password-disabled registration must not create password-only accounts or auto-login through password endpoints: offer OIDC signup when available, otherwise no public signup route despite registration permission. Preserve existing sessions/API bearer use, local confirmation rules, passkeys and legacy social configuration.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith/auth/config_test.exs test/kith_web/auth_policy_test.exs test/kith_web/live/user_live/signup_controls_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
defp boolean!(env, key, default) do
  case Map.get(env, key) do
    nil -> default
    "true" -> true
    "false" -> false
    _ -> raise ArgumentError, "#{key} must be true or false"
  end
end
# In API password-token creation, gate before credential verification:
# Return a disabled-method response before invoking any password verifier.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: authentication configuration and policy enforcement` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Independent flags, no hidden-control-only enforcement, no password recovery bypass, no accidental Google/GitHub UI fix or logged credentials.

### Task 2: Grouped settings navigation and focused security page

**Files:**
- Modify: `lib/kith_web/live/settings_live/settings_layout.ex`, `lib/kith_web/live/user_live/settings.ex`, `lib/kith_web/router.ex`, `lib/kith_web/components/layouts.ex`.
- Create: `lib/kith_web/live/settings_live/security.ex`, `test/kith_web/live/settings_live/security_test.exs`, `test/kith_web/live/settings_live/settings_layout_test.exs`.
- Modify: `test/kith_web/live/user_live/settings_test.exs`, `test/playwright/settings.spec.ts`, `test/playwright/mobile-navigation.spec.ts`.
- Create: `assets/js/hooks/settings_navigation.js`; register in `assets/js/app.js`; add `test/js/settings-navigation.test.mjs`.

**Interfaces:**
- `SettingsLayout.destinations(scope) :: [%{label: string, items: [%{path: string, label: string, icon: string}]}]` supplies both desktop navigation and mobile options, filtering by existing permissions.
- Routes: existing Profile `/users/settings`; new Security `/settings/security`; mobile selector uses safe static route values from `destinations/1`.
- Security owns the current password form/event contract and its existing POST `/users/update-password`; Profile retains email and confirmation routes.
- `SettingsNavigation` hook receives only an allowlisted selector and navigates using LiveView-compatible navigation; server authorization remains independent.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "password form moves out of profile", %{conn: conn} do
  user = Kith.AccountsFixtures.user_fixture()
  conn = log_in_user(conn, user)
  {:ok, profile, _} = live(conn, "/users/settings")
  refute has_element?(profile, "#password_form")
  {:ok, security, _} = live(conn, "/settings/security")
  assert has_element?(security, "#password_form")
end
```

First verify the installed LiveView JS navigation API; use the supported API with the same contract if it differs. Personal contains Profile and Security (Contact sync arrives task 4); Workspace/Data contain every existing destination exactly as approved. No empty groups. Preserve admin authorization and direct routes. Keep app shell/mobile bottom-navigation active state for new paths, including existing viewport-height regression. Move password behavior rather than copying it. Password controls absent when disabled; direct submit remains guarded by task 1. Retain recent-auth protection until task 7 enables OIDC freshness. Add TOTP status and entry to the existing setup route; do not expose unsupported recovery-code regeneration or new passkey/social management. Tests assert destinations, selected state, role filtering, confirmation-email return, password update and keyboard/mobile navigation, without conditional assertions that silently pass.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith_web/live/settings_live/security_test.exs test/kith_web/live/settings_live/settings_layout_test.exs test/kith_web/live/user_live/settings_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
# Render the same filtered destinations in both navigation modes:
for group <- destinations(@current_scope) do
  # desktop: heading + route links with aria-current
  # mobile: optgroup + options whose values are the static route paths
end
```
```javascript
// assets/js/hooks/settings_navigation.js
export default {
  mounted() {
    this.onChange = () => {
      const option = this.el.selectedOptions[0];
      if (option && option.dataset.allowed === "true")
        window.liveSocket.js().navigate(option.value);
    };
    this.el.addEventListener("change", this.onChange);
  },
  destroyed() { this.el.removeEventListener("change", this.onChange); }
};
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: grouped settings navigation and focused security page` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Approved layout, same permission model in both navigation modes, no duplicated password handlers, no replacement of app chrome, existing settings links still reachable.

### Task 3: Hashed DAV app passwords and request authentication

**Files:**
- Create: `lib/kith/accounts/dav_app_password.ex`, `lib/kith/accounts/dav_app_passwords.ex`, `test/kith/accounts/dav_app_passwords_test.exs`.
- Create migration with `mix ecto.gen.migration create_dav_app_passwords` under `priv/repo/migrations/`.
- Modify: `lib/kith/dav/auth.ex`, `lib/kith/accounts/user.ex`, `test/kith_web/dav/auth_test.exs`, `test/kith_web/controllers/api/auth_controller_test.exs`.
- Add account-password rejection regression to `test/kith_web/controllers/user_session_controller_test.exs`.

**Interfaces:**
- `DavAppPasswords.create(user, %{name: string}) :: {:ok, row, plaintext} | {:error, :reauthentication_required | changeset}`.
- `list(user) :: [row]`, `revoke(user, id) :: :ok | {:error, :not_found | :reauthentication_required}`.
- `authenticate(email, credential) :: {:ok, confirmed_user} | {:error, :unauthorized}` is DAV-only, does not elevate `authenticated_at` and enforces active row and email ownership.
- Schema fields: `user_id`, `name` (1..80 trimmed characters), `public_id` (unique), `secret_hash` (redacted binary), `revoked_at`, timestamps. Last-used tracking is omitted initially rather than introducing per-request write churn.
- Format: `kith_dav_<22-char base64url public id>.<43-char base64url 32-byte secret>`; no padding. A credential beginning `kith_dav_` must never fall back to account-password verification.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "revocation is immediate and owner-scoped" do
  user = Kith.AccountsFixtures.user_fixture()
  user = %{user | authenticated_at: DateTime.utc_now(:second)}
  other = Kith.AccountsFixtures.user_fixture()
  other = %{other | authenticated_at: DateTime.utc_now(:second)}
  {:ok, row, secret} = Kith.Accounts.DavAppPasswords.create(user, %{name: "Pixel"})
  assert {:ok, _} = Kith.Accounts.DavAppPasswords.authenticate(user.email, secret)
  assert {:error, :not_found} = Kith.Accounts.DavAppPasswords.revoke(other, row.id)
  assert :ok = Kith.Accounts.DavAppPasswords.revoke(user, row.id)
  assert {:error, :unauthorized} = Kith.Accounts.DavAppPasswords.authenticate(user.email, secret)
end
```

Use confirmed fresh users in fixture setup; set authentication timestamp explicitly when needed. Enforce freshness before create/revoke; task 7 replaces provisional sudo checks with MFA-aware evidence. Test no raw secret in DB/inspect/log output, malformed/oversized values, wrong username, wrong secret, unconfirmed/deleted user, user/account scoping, revocation twice, name limits, and concurrent revoke/next-request behavior. Revocation update and each verification query read authoritative DB state without a credential cache. Preserve existing DAV throttling, verified-password wrapper and `WWW-Authenticate`. In password-disabled mode test both active app-password success and account-password denial. Test PROPFIND/GET/PUT/DELETE/REPORT authorization using an app password and cross-account target denial, plus web/API rejection. Include existing local password compatibility tests.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith/accounts/dav_app_passwords_test.exs test/kith_web/dav/auth_test.exs test/kith_web/controllers/api/auth_controller_test.exs test/kith_web/controllers/user_session_controller_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
public_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
secret_hash = :crypto.hash(:sha256, secret)
plaintext = "kith_dav_" <> public_id <> "." <> secret
# Persist secret_hash only; return plaintext once from successful creation.
# Verification: lookup public_id+user, require revoked_at == nil, then
# Plug.Crypto.secure_compare(stored_hash, :crypto.hash(:sha256, supplied_secret)).
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: hashed dav app passwords and request authentication` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Hashing random secrets rather than human-password assumptions, no cross-protocol credentials, no plaintext retention, no changes to DAV resource permissions.

### Task 4: Personal contact sync settings and one-time credentials UI

**Files:**
- Create: `lib/kith_web/live/settings_live/contact_sync.ex`, `test/kith_web/live/settings_live/contact_sync_test.exs`.
- Modify: `lib/kith_web/router.ex`, `lib/kith_web/live/settings_live/settings_layout.ex`, `lib/kith_web/live/settings_live/integrations.ex`.
- Modify: `assets/js/alpine/copy_text.js` only if its current behavior needs a safe reusable extension; add targeted JS tests for any changed behavior.
- Modify: `test/playwright/carddav-copy.spec.ts`, `test/playwright/immich.spec.ts`, `test/kith/settings_multitenancy_test.exs`.

**Interfaces:**
- `/settings/contact-sync` is available to any authenticated confirmed user, including editor/viewer roles; mutation ownership is the current user, never a browser-supplied user ID.
- Live actions `:index`, `:new`, `:created`, `:revoke` correspond to approved overview/create/reveal/confirm states. Plaintext lives only in ephemeral LiveView assigns for the creation result.
- Uses task 3 `create/list/revoke`; missing recent authentication returns through a safe route to retry, never through a session-stored plaintext secret.
- Reuse `/dav/principals/` connection instructions from existing Integrations; preserve a link from Integrations to the new destination. Do not move Immich permissions/configuration.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "viewers can access personal sync without managing integrations", %{conn: conn} do
  user = Kith.AccountsFixtures.user_fixture(%{role: "viewer"})
  conn = log_in_user(conn, user)
  {:ok, view, _} = live(conn, "/settings/contact-sync")
  assert has_element?(view, "#dav-app-passwords")
  assert has_element?(view, "#carddav-url")
  refute has_element?(view, "a[href='/settings/integrations']")
end
```

Build from UI.header/card/input/button and the approved iteration 2 organization. Overview starts with the list, connection details and collapsed client instructions; creating and revealing are focused steps, not an always-expanded form. Show device creation time without inventing last-used evidence. Add empty/error/loading states, revoke confirmation with device name, clipboard fallback and live status messages. One-time reveal is not encoded in a URL, session, Alpine data attribute outside the visible value, local/sessionStorage or browser snapshot. Set sensitive response/cache policy appropriately; reloading reconnecting cannot reconstruct the secret. Test stale authenticated socket events and cross-owner credential IDs. Update old DAV copy tests to the new route and retain an explicit Integrations link regression. Include Android DAVx5 instructions and account-password compatibility copy only when enabled.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith_web/live/settings_live/contact_sync_test.exs test/kith/settings_multitenancy_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
# Event receives only device name. Context independently enforces ownership/freshness.
case DavAppPasswords.create(socket.assigns.current_scope.user, %{name: params["name"]}) do
  {:ok, row, plaintext} ->
    {:noreply, assign(socket, created_credential: row, revealed_secret: plaintext)}
  {:error, :reauthentication_required} ->
    {:noreply, redirect(socket, to: ~p"/users/log-in")}
  {:error, changeset} ->
    {:noreply, assign(socket, form: to_form(changeset))}
end
# Clear revealed_secret on every navigation, completion, cancel and reconnect.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: personal contact sync settings and one-time credentials ui` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Personal credentials accessible to non-admin users, no accidental account integration access, secret disappears after navigation/reconnect, mobile focused states match mockup.

### Task 5: OIDC protocol adapter and single-use browser transactions

**Files:**
- Create: `lib/kith/auth/principal.ex`, `lib/kith/auth/oidc.ex`, `lib/kith/auth/oidc/transaction.ex`, `lib/kith/auth/oidc/transactions.ex`, `lib/kith/auth/oidc/metadata.ex`, `lib/kith/workers/purge_auth_flows_worker.ex`.
- Create migration `create_oidc_transactions` with `mix ecto.gen.migration`.
- Create: `test/kith/auth/oidc_test.exs`, `test/kith/auth/oidc/transactions_test.exs`, `test/support/oidc_fixture.ex`.
- Modify: `config/config.exs` (existing Oban schedule), `config/test.exs` only for isolated fixture TLS configuration. Keep Assent pinned unless verified gaps require a reviewed update. Package its optional JWT adapter dependency explicitly only if the chosen supported adapter requires it. Inspect installed release, not latest docs.

**Interfaces:**
- `Principal` struct: `issuer`, `subject`, `email`, `email_verified`, `name`, `auth_time`.
- `Transactions.start(attrs, browser_binding) :: {:ok, %{state: string, nonce: string, code_verifier: string, id: integer}}`; attrs include `intent` (`:login | :link | :reauth`), `issuer`, `redirect_uri`, `return_to`, optional `user_id` and encrypted `session_token`.
- `Transactions.consume(state, browser_binding) :: {:ok, transaction} | {:error, :invalid_transaction}`; row locks/conditional DB update provide one winner, 300-second expiry.
- `OIDC.authorize(transaction, config) :: {:ok, url} | {:error, reason}`; `OIDC.callback(transaction, params, config) :: {:ok, %Principal{}} | {:error, reason}`. Never expose token structs outside the adapter.
- `Metadata.get(config) :: {:ok, metadata} | {:error, :unavailable | :invalid_metadata}`; successful discovery/JWKS caching follows preflight limits and issuer equality.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "a consumed transaction cannot be replayed" do
  binding = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  {:ok, flow} = Kith.Auth.OIDC.Transactions.start(%{
    intent: :login, issuer: "https://issuer.test", redirect_uri: "https://kith.test/auth/oidc/callback",
    return_to: "/dashboard"
  }, binding)
  assert {:ok, _} = Kith.Auth.OIDC.Transactions.consume(flow.state, binding)
  assert {:error, :invalid_transaction} = Kith.Auth.OIDC.Transactions.consume(flow.state, binding)
end
```

Schema: state/binding hashes, issuer, intent, encrypted payload, initiated/expires/consumed timestamps, optional initiating user. Store no raw handle in logs. Fixture must serve discovery, authorization, token and JWKS with genuine RS256 signing and controllable claim/error/rotation behaviors; use existing crypto adapter or explicit reviewed JWT dependency, not unsigned mocked callback output. Test S256 challenge derived from verifier, restored `session_params`, nonce string distinct per flow, signature/algorithm/issuer/aud/azp/subject/type/time failures, UserInfo mismatch, exact metadata issuer, advertised unsupported profile, timeout/redirect/TLS errors, unknown-key refresh, cache expiry and parallel consumption. Implement three- and five-second time limits through the actual adapter, not unused config values. Use clock input/test clock for expiry tests without sleeps. Add cleanup worker tests proving expired rows/challenges are removed and active rows retained; task 7 extends cleanup to auth challenges. Internal HTTPS issuer addresses remain supported; arbitrary request-supplied discovery is rejected.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith/auth/oidc_test.exs test/kith/auth/oidc/transactions_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
# One-use DB transaction, never read-then-delete without locking:
Repo.transaction(fn ->
  flow = Repo.one(from f in Transaction,
    where: f.state_hash == ^hash(state), lock: "FOR UPDATE")
  if valid?(flow, browser_binding, DateTime.utc_now()),
    do: Repo.update!(Ecto.Changeset.change(flow, consumed_at: DateTime.utc_now())),
    else: Repo.rollback(:invalid_transaction)
end)
# Assent options explicitly include code_verifier: true and a random nonce STRING.
# Bind expected config issuer to discovery issuer before accepting Assent validation.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: oidc protocol adapter and single-use browser transactions` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Actual Assent 0.3.2 options/claims validation, concurrent single use across processes, encrypted payloads, metadata issuer consistency and no replay/downgrade path.

### Task 6: Issuer-bound identity ownership and atomic provisioning

**Files:**
- Create: `lib/kith/accounts/oidc_identity.ex`, `lib/kith/accounts/oidc.ex`, `test/kith/accounts/oidc_test.exs`.
- Create migration `create_oidc_identities`; modify `lib/kith/accounts/user.ex` and focused existing Accounts last-login-method checks.
- Reuse existing account/reminder seeding and registration validation without copying the legacy email-auto-link path. Preserve all legacy social identity rows.

**Interfaces:**
- `Accounts.OIDC.resolve(principal) :: {:ok, user} | {:error, :registration_required | :email_collision}` resolves exact issuer/subject only.
- `register(principal, %{tos_accepted: boolean}) :: {:ok, user} | {:error, :registration_disabled | :email_unverified | :email_collision | changeset}`; checks policy internally and creates account+user+identity+defaults atomically.
- `link(user, principal) :: {:ok, identity} | {:error, :identity_in_use | :reauthentication_required}`; recent-auth and same-user flow evidence required by web completion.
- `unlink(user, identity_id) :: :ok | {:error, :not_found | :last_login_method | :reauthentication_required}`; consider active deployment policies, passkeys, legacy providers and passwords. App passwords never count.
- `list(user) :: [identity]`. Dedicated schema unique `(issuer, subject)`, FK user cascade, provider label not used as key.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "verified matching email never links an existing account" do
  user = Kith.AccountsFixtures.user_fixture()
  principal = %Kith.Auth.Principal{
    issuer: "https://issuer.test", subject: "external-1", email: user.email,
    email_verified: true, name: "Alex"
  }
  assert {:error, :email_collision} = Kith.Accounts.OIDC.resolve(principal)
  assert [] = Kith.Accounts.OIDC.list(user)
end
```

Add a dedicated OIDC user changeset rather than weakening password registration validation. Preserve email uniqueness/format limits, display name sanitization and terms policy. Returning linked users can log in when signup disabled or external email changed; do not silently modify local email. Missing/false/string `email_verified` rejects new signup, not a known identity that does not need email for identity proof. Test same subject/different issuer produces different identities, changed issuer cannot capture an account, collision at both resolve and DB write, existing identity cannot transfer owners, concurrent first signup creates one account/default-rule set, rollback prevents orphan accounts. Serialize link/unlink/last-method checks against a per-user DB lock so concurrent unlink cannot remove both final methods. Keep legacy password/identity deletion behavior compatible with new identity type without implementing legacy UI.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith/accounts/oidc_test.exs test/kith/accounts_oauth_test.exs test/kith/accounts_webauthn_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
# Schema constraints and lookup preserve exact external identity:
identity = Repo.get_by(OIDCIdentity, issuer: principal.issuer, subject: principal.subject)
# In register/2, enforce true rather than truthiness:
case principal.email_verified do
  true -> register_transaction(principal, attrs)
  _ -> {:error, :email_unverified}
end
# register_transaction uses Ecto.Multi for account, user, identity and default rules.
# Do not set a hidden random password: an OIDC-only user has hashed_password: nil.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: issuer-bound identity ownership and atomic provisioning` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** No email linking, no privileged external claim mapping, no orphan personal accounts, no fake local password, race-safe last-method protection.

### Task 7: MFA completion and OIDC-aware recent authentication

**Files:**
- Create: `lib/kith/auth/challenges.ex`, `lib/kith/auth/challenge.ex`, `lib/kith_web/authentication.ex`, `test/kith/auth/challenges_test.exs`, `test/kith_web/authentication_completion_test.exs`.
- Create migration `create_auth_challenges`.
- Modify: `lib/kith_web/controllers/user_session_controller.ex`, `lib/kith_web/user_auth.ex`, `lib/kith/accounts/user_token.ex`, `lib/kith_web/live/user_live/totp_challenge.ex`, `lib/kith_web/live/user_live/login.ex`, `lib/kith_web/live/user_live/totp_setup.ex`.
- Integrate tasks 2–4 contexts/pages and task 6 mutation guards; extend auth-flow cleanup worker from task 5.

**Interfaces:**
- `Challenges.issue(user, attrs) :: {:ok, opaque_handle}`; DB row holds handle hash, user, intent (`:login | :reauth | :link`), verified first-factor timestamp, expires/consumed timestamps and encrypted completion context.
- `Challenges.complete(handle, browser_binding, code) :: {:ok, completion} | {:error, :invalid | :expired | :rate_limited}` validates local TOTP/recovery, binding and one-use consumption. Reuse existing rate-limit keys and recovery-code verification.
- `Authentication.begin(conn, user, completion) :: conn` either challenges or completes; `Authentication.finish(conn, completion) :: conn` rotates/creates local session and stamps fresh full-auth evidence only after all factors.
- `Authentication.require_recent(user, max_age_seconds \\ 600) :: :ok | {:error, :reauthentication_required}` consumes persisted completed-auth evidence; a renewed session does not refresh this timestamp.
- Add persisted nullable `mfa_authenticated_at` to `UserToken` and a matching virtual `User` field; carry it through session lookup/reissue. Set it only after local TOTP/recovery verification. `require_recent/2` checks `authenticated_at` and, for TOTP-enabled users, `mfa_authenticated_at`, each within the freshness limit. Legacy nil MFA evidence requires reauthentication.
- Password login and new OIDC login use this completion boundary. Existing social/passkey callbacks retain behavior; legacy session timestamps alone cannot authorize new sensitive mutations for a TOTP-enabled user without recorded MFA completion.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "renewing a session does not manufacture recent authentication" do
  user = Kith.AccountsFixtures.user_fixture()
  old = DateTime.add(DateTime.utc_now(:second), -601, :second)
  user = %{user | authenticated_at: old}
  token = Kith.Accounts.generate_user_session_token(user)
  assert {loaded, _} = Kith.Accounts.get_user_by_session_token(token)
  assert {:error, :reauthentication_required} =
    KithWeb.Authentication.require_recent(loaded)
end
```

Persist the explicit `mfa_authenticated_at` completion timestamp on session token metadata (with conservative legacy interpretation); do not confuse first-factor proof with sudo timestamps. Cover no-token-before-MFA, wrong/expired/rate-limited/replayed challenges, stolen handle with another binding, recovery code single use, link/reauth same-user enforcement and logout during pending flow. Password reauth includes TOTP when enabled. OIDC reauth starts a new provider transaction with `max_age=0`, validates `auth_time`, resolves the SAME linked issuer/subject and then local MFA; never changes users. Sensitive UI returns to its originating local route without auto-replaying a credential creation POST. Profile email/password, OIDC link/unlink, app-password create/revoke and TOTP setup/enable all use the same recent-auth boundary. Audit other existing sensitive mutations only where these changes affect them; avoid locking OIDC-only users into password-only sudo. New sessions rotate after successful login/freshness and existing return-to allowlisting is enforced.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith/auth/challenges_test.exs test/kith_web/authentication_completion_test.exs test/kith_web/controllers/user_session_controller_test.exs test/kith_web/user_auth_test.exs test/kith_web/live/settings_live/contact_sync_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
# Public intent dispatch must operate on validated completion, not browser intent:
case completion.intent do
  :login -> complete_login_after_required_mfa(conn, completion)
  :reauth -> renew_same_user_after_required_mfa(conn, completion)
  :link -> link_same_user_after_required_mfa(conn, completion)
end
# Record authentication completion in the issued UserToken metadata.
# Never update authenticated_at because a cookie/session was merely reissued.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: mfa completion and oidc-aware recent authentication` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Freshness cannot be forged by session renewal, local MFA never skipped for new OIDC flows, recent-auth works without a local password, challenge replay/link intent is contained.

### Task 8: End-to-end OIDC login and account linking UI

**Files:**
- Create: `lib/kith_web/controllers/oidc_controller.ex`, `lib/kith_web/live/user_live/oidc_registration.ex`, `test/kith_web/controllers/oidc_controller_test.exs`, `test/kith_web/live/user_live/oidc_registration_test.exs`.
- Modify: `lib/kith_web/router.ex`, `lib/kith_web/live/user_live/login.ex`, `lib/kith_web/live/settings_live/security.ex`, `lib/kith_web/endpoint.ex` only for integration needed by the dedicated cookie; do not loosen the main session cookie.
- Modify: `config/config.exs` log parameter filtering; `lib/kith/sentry_scrubber.ex` (create) and `config/runtime.exs` to wire the installed Sentry version's supported event-scrubbing callback; `Kith.SentryFilter` currently filters exceptions, not payload contents.
- Update focused Security and login tests.

**Interfaces:**
- `GET /auth/oidc` starts login; `GET /auth/oidc/callback` handles query code/errors. Explicit routes precede `/auth/:provider` to avoid legacy controller interception.
- `POST /users/oidc/link` and `POST /users/oidc/reauth` are CSRF-protected starts; intent/user/return destination derived server-side. Unlink is a protected settings event.
- `GET /users/oidc/register` presents terms/profile completion from a single-use pending-registration handle; POST completion is CSRF protected and checks current policy again.
- Uses OIDC, Transactions, Principal, Accounts.OIDC and Authentication interfaces from tasks 5–7. Login button uses escaped `OIDC_DISPLAY_NAME`, never a provider-specific logo/behavior.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```elixir
test "disabled OIDC rejects direct starts and callbacks", %{conn: conn} do
  # The test's setup installs normalized config with oidc_enabled: false.
  conn = get(conn, "/auth/oidc")
  refute redirected_to(conn) =~ "issuer.test"
  refute get_resp_header(conn, "set-cookie") |> Enum.any?(&String.contains?(&1, "__Host-kith_oidc="))
  callback = get(build_conn(), "/auth/oidc/callback", %{"code" => "untrusted", "state" => "unknown"})
  refute get_session(callback, :user_token)
end
```

Set/read the dedicated opaque Lax binding cookie with an unpredictable 32-byte random value and signed-cookie integrity protection; correlation is verified against DB hashes. Main session Strict is unchanged. On callback without main cookie, restore only the initiating session after validating encrypted stored token for link/reauth; enforce session still exists and identity matches. Protect initiating link from login CSRF; authenticated clicking GET login must not link by accident. Login/register consume known-user or pending terms outcomes, with no tokens retained. Pending signup uses encrypted single-use DB payload (the transaction store can support a distinct completion purpose), not raw claim fields in hidden inputs. Handle parallel tabs, provider deny, missing state, broken issuer, signup disabled mid-flow, stale link initiation, user mismatch, expired terms and email collision. Ensure local-only navigation, clean callback URL, no query credential logs/traces (document reverse proxy logging requirements). Unlink requires confirmation/last-method guard. UI has loading/disabled states and field errors with accessible status; mockup preview switches/messages never ship.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
mix test test/kith_web/controllers/oidc_controller_test.exs test/kith_web/live/user_live/oidc_registration_test.exs test/kith_web/live/user_live/login_test.exs test/kith_web/live/settings_live/security_test.exs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```elixir
with {:ok, tx} <- Transactions.consume(params["state"], browser_binding(conn)),
     :ok <- enabled_and_expected_issuer?(tx),
     {:ok, principal} <- OIDC.callback(tx, params, config()) do
  dispatch_validated_intent(conn, tx, principal)
else
  {:error, _reason} -> authentication_failed_without_sensitive_details(conn)
end
# Error callbacks validate and consume correlation too, without token redemption.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: end-to-end oidc login and account linking ui` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Route precedence, external callback cookie reality, CSRF and same-user linking, terms cannot be skipped, registration policy enforced at final mutation, secrets scrubbed.

### Task 9: Desktop and mobile browser journeys with genuine provider redirects

**Files:**
- Create: `test/playwright/fixtures/oidc/server.exs`, `boot.exs`, `control.exs`, `run.sh`, `README.md` under that fixture directory; reuse task 5 fixture implementation through a compiled test-support module.
- Create: `test/playwright/oidc.spec.ts`, `test/playwright/dav-app-passwords.spec.ts`, `test/playwright/settings-navigation.spec.ts`, `test/playwright/helpers/oidc.ts`.
- Modify: `test/playwright/fixtures/regressions/run.sh`, `test/playwright/README.md`, `test/playwright/settings.spec.ts`, `mobile-navigation.spec.ts`, `mobile-layout.spec.ts`, `playwright.config.ts`, `.github/workflows/ci.yml`.
- Extend existing test-only seed/control patterns; no fixture-control routes in production builds.

**Interfaces:**
- Fixture harness provisions test-only trusted HTTPS names `kith.test` and `issuer.test` and checks run identity/readiness. Its signed tokens enforce actual code/verifier redemption.
- Fixture control endpoint accepts the run-specific fixture token; supports selected subject/claims, deny/timeout, key rotation, enabled flags via app-process restart and deterministic MFA test user setup. Never controls a production app.
- `beginOidcLogin(page)` follows real UI redirects; does not set a Kith session cookie. Use existing account setup helpers only when the journey specifically tests an already-authenticated settings flow.
- Playwright specs remain fail-fast with zero retries for security journeys and explicit test assertions, not `if (element.count())` conditional pass paths.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```typescript
import { test, expect } from "@playwright/test";

test("mobile settings select navigates to personal sync", async ({ page }) => {
  // beforeEach logs in a confirmed viewer through the normal UI.
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto("/settings/security");
  await page.getByLabel("Settings", { exact: true }).selectOption("/settings/contact-sync");
  await expect(page).toHaveURL(/\/settings\/contact-sync$/);
  await expect(page.getByRole("heading", { name: "Contact sync", exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
```

Implement exact named controls in app/fixture so tests are stable. Browser scenarios: initial signup/terms, returning user with signup disabled, password-disabled OIDC, explicit link/unlink with reauth, collision no takeover, TOTP success/wrong/recovery, two simultaneous flow tabs, denied/expired/replayed callback, missing binding, logout/revoked originating session, no provider-token leakage, create/reveal/reload/revoke app password and immediate DAV failure, denied API/web reuse. Run fresh isolated app instances for flag combinations so mutable global config cannot leak between parallel tests. Cover desktop 1366/1440, mobile 320/375/393, desktop→mobile→desktop, focus/keyboard/select, server/secret-copy failure, long device names and empty lists, non-admin ownership and Integrations permission retention. Keep existing browser-toolbar-height regression. Record screenshots for key states without plaintext real credentials. Hook fixtures into maintained CI harness with owned-process teardown and readiness, no silent skips when mandatory. A second port on the same site is insufficient for the callback-cookie regression. Certificate setup is test-runner-local and removed on teardown.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
bash test/playwright/fixtures/oidc/run.sh
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```typescript
// A callback must succeed through browser navigation, not request-context shortcuts.
await page.goto("/users/log-in");
await page.getByRole("link", { name: "Continue with OpenID Connect" }).click();
await expect(page).toHaveURL(/^https:\/\/issuer\.test/);
await page.getByRole("button", { name: "Authorize" }).click();
await expect(page.getByLabel("Authentication code")).toBeVisible();
// Fixture supplies a known TOTP secret through its protected test control only.
// Finish with a generated current code, assert protected app route and session rotation.
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: desktop and mobile browser journeys with genuine provider redirects` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Tests fail if controls vanish; real cross-site callback traverses actual cookies; phone viewport is labelled simulation; no secret artifacts or test backdoors in app builds.

### Task 10: Actual Android Chrome and DAVx5 interoperability validation

**Files:**
- Create: `docs/design/oidc-android-validation.md`, `scripts/carddav-e2e/oidc-app-passwords-android.md`.
- Create: `scripts/android/oidc-chrome.mjs` for real Android Playwright connection where supported; no app install/global device setting changes without existing session authorization.
- Modify: `test/playwright/README.md`, `docs/carddav-client-checklist.md`.
- Store sanitized reproducible evidence under `docs/design/oidc-validation/` only; avoid storing real app passwords, identity tokens or personal contact exports.

**Interfaces:**
- Runbook identifies device/emulator, Android build, Chrome version, DAVx5 version, test app/issuer origins, TLS trust and run date.
- Android runner uses Playwright's Android device support (`_android.devices()` and `device.launchBrowser()`); requires an authorized connected test device. Absence fails clearly rather than returning passing test status.
- Runbook records each acceptance case as PASS, FAIL or NOT RUN with evidence. Authentik smoke is separate interoperability evidence and remains provider-neutral in application code.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```javascript
import { _android as android } from "playwright-core";
const devices = await android.devices();
if (devices.length !== 1) throw new Error("Connect exactly one authorized Android test device");
const device = devices[0];
const context = await device.launchBrowser();
try {
  const page = await context.newPage();
  await page.goto(process.env.KITH_ANDROID_TEST_URL);
  if (!(await page.getByRole("link", { name: /Continue with/ }).isVisible()))
    throw new Error("OIDC login action missing on Android");
} finally {
  await context.close();
  await device.close();
}
```

Extend runner to complete the same Android login, MFA and credential UI journeys using protected fixture setup, without installing session cookies. Require `KITH_ANDROID_TEST_URL` with HTTPS and trusted nonproduction issuer; do not put secrets into command-line arguments or logs. Real device networking/TLS differ from desktop: document reachability and test-only CA provisioning; do not disable global TLS verification. Check Android back navigation, keyboard opening, focused action visibility, touch/select behavior and callback continuity. DAVx5 validation uses a test address book and a newly created credential, observes server request outcomes and checks read/write scoping, next-request revocation failure and unaffected second device. Existing DAVx5 vCard fixtures do not prove client interoperability. Include a live Authentik test only if nonproduction credentials/test deployment are supplied through secure tooling. If device/provider access is unavailable, finish the runner/runbooks but leave the acceptance matrix NOT RUN, with exact prerequisites; feature cannot be reported fully validated.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
node scripts/android/oidc-chrome.mjs
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```text
Android browser: login → provider redirect → callback → local TOTP → protected page
Settings: selector → Security → fresh-auth round trip → Contact sync → create/show once
DAVx5: URL + email + app password → discover address book → sync → edit test contact
Revoke credential in Kith → force another DAV request → authentication fails
Repeat with PASSWORD_LOGIN_ENABLED=false; ordinary password fails, app password works
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: actual android chrome and davx5 interoperability validation` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Actual Android evidence and explicit outstanding validation; no substitute based on viewport/user-agent/vCard fixture; no unrelated device changes or credentials in evidence.

### Task 11: Operator documentation and whole-feature release acceptance

**Files:**
- Modify: `docs/configuration.md`, `docs/deployment/README.md`, `test/playwright/README.md`, environment example from task 1.
- Create: `docs/deployment/oidc.md`, `docs/deployment/dav-app-passwords.md`, `docs/design/oidc-validation/acceptance.md`.
- Review: all feature migrations, policy guards, sensitive response/log handling, test fixtures and approved settings pages.
- Modify CI/docs only where required to run the focused/full checks added in earlier tasks.

**Interfaces:**
- `acceptance.md` maps each spec section to implementation paths, exact tests, results, review verdicts and desktop/Android/live-provider evidence.
- Operator guide documents issuer/client registration, `/auth/oidc/callback`, scopes/profile restrictions, environment flags/secret-file support, private HTTPS issuer trust, migration and rollback expectations, operator recovery and provider-outage handling.
- DAV guide documents URL/username, one-time passwords, revocation, Android/Apple setup and behavior under both password-policy states.

- [ ] **Step 1: Add the first behavior regression and the listed cases.** Put this concrete test inside the stated test module/suite with its normal imports and fixtures:

```text
Acceptance ledger rows:
Configuration → task 1 tests → command/result
Settings routes and permissions → tasks 2/4/9 → command/result
OIDC validation and identity ownership → tasks 5/6/8 → command/result
Local MFA / fresh authentication → task 7 → command/result
DAV credential isolation/revocation → tasks 3/4/9 → command/result
Desktop and phone layout → task 9 → browser/version/result
Android Chrome / DAVx5 → task 10 → device/client/version/result
Authentik smoke → task 10 → result or NOT RUN with prerequisites
```

Run each required command after final integration, not repeatedly without a changed concern. Start necessary documented DB/mail/browser fixtures before commands; infrastructure errors are not successful assertions. Verify migration upgrade preserves all existing user/session/social/DAV data; dedicated new tables avoid destructive backfills. Validate downgrade constraints in docs without dropping shared data. Document logout is local-only, disabled provider users retain Kith credentials/sessions until separately revoked, disabling passwords does not revoke bearer tokens, and cached discovery/outage behavior. Review full branch with independent SDD reviewer and resolve findings. Compare actual UI to approved mockup using project components and desktop/mobile evidence, not the static HTML prototype. Missing actual Android acceptance remains conspicuous rather than hidden in a generic all-tests-passed summary. Record residual risks and externally blocked checks in handoff. No push/PR/merge unless separately requested.

- [ ] **Step 2: Run the focused command before implementation.** Expected: new assertions fail for the missing behavior, rather than missing database/server prerequisites.

```sh
git diff --check
```

- [ ] **Step 3: Implement the boundary using this code shape, then satisfy every case above.** Snippets fix the important semantics; preserve existing framework conventions and fill out the named interfaces in this task, without introducing unrelated behavior.

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
npm run test:js
mix run --no-start scripts/security/sobelow_check.exs
mix dialyzer
npm run test:regressions
bash test/playwright/fixtures/oidc/run.sh
```
```sh
# Against an isolated test DB, verify fresh-install migrations and upgrade
# from pre-feature schema; never roll back shared/production databases.
MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 4: Re-run the focused command and affected existing regressions.** Expected: all assertions pass, with no skipped required scenarios. Inspect failure paths and sensitive-data output.
- [ ] **Step 5: Self-review, run `git diff --check`, stage only this task's named source/tests/docs, and commit with message `feat: operator documentation and whole-feature release acceptance` (use `test:` or `docs:` for validation-only tasks).** Send the controller status, exact commit(s), commands/results, concerns and a full report file. Do not claim unavailable external validation passed.
- [ ] **Step 6: Controller obtains independent spec/quality review and resolves its findings before completing this task.**

**Reviewer focus:** Every spec requirement has concrete implementation and evidence; no unsupported universal-provider claim; no assertion that mobile emulation is Android verification; final diff stays within agreed scope.

## Spec-to-task coverage audit

The checks below confirm plan coverage only. Implementation tasks, test execution and external validation remain unstarted.

- [x] Operator controls/defaults/legacy compatibility/direct policy guards: task 1, integrated tasks 7–9.
- [x] Approved settings navigation, relocated password, role visibility, mobile selector, existing routes: tasks 2/4/9.
- [x] Hashed one-time app credentials, DAV-only use, revocation and local-password compatibility: tasks 3/4/9/10.
- [x] Discovery, issuer binding, PKCE, nonce, JWT claims, time budgets, keys and single-use DB state: task 5, browser proof task 9.
- [x] Issuer-sub identity, no email takeover, terms, registration races, privilege/account boundary: task 6, UI task 8.
- [x] Local MFA, recovery, challenge replay, OIDC-only recent auth and sensitive operation guards: task 7.
- [x] Login/link/signup UI, cookie boundary, routing, logging and error states: task 8.
- [x] Desktop and mobile viewport journeys, accessibility and regression CI: task 9.
- [x] Actual Android Chrome, DAVx5 and live-provider evidence/explicit gaps: task 10.
- [x] Docs, migrations, operator recovery, full checks and final independent review: task 11.

## Completion and handoff

The implementation controller records task completion only after independent review. After task 11, report concrete behavior, commits, tests and unresolved external validation. Use the SDD finishing workflow while honoring the user's authorization scope; do not automatically merge/deploy or create new top-level threads. Implementation method is already selected: **subagent-driven development**; do not ask the user to choose it again.
