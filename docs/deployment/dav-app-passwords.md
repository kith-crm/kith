# Contact sync with DAV app passwords

Open **Settings → Contact sync** as your own confirmed Kith user. This personal
page is available independently of workspace Integrations permission. Use the
server URL shown there, normally `https://YOUR_KITH_HOST/dav/principals/`, and
your exact Kith email as username. Kith implements CardDAV contacts, not CalDAV.
Use HTTPS and a certificate trusted by the client.

Choose **Create app password**, give it a recognizable device name (1–80 Unicode
codepoints after trimming), and complete recent authentication/local MFA if asked.
Create one credential per client. Copy the complete value including its `kith_dav_`
prefix; it is shown only once. If clipboard access fails, select the visible value
and copy manually. Leaving/reloading the page clears it. Kith stores only a public
lookup identifier and SHA-256 hash of a random 256-bit secret; the original cannot
be recovered. Lost values must be revoked and replaced. Never send passwords in
screenshots, logs, chat or support tickets.

## Configure clients

- **Android / DAVx5:** add an account using “Login with URL and user name”; enter
  the displayed URL, Kith email and app password. Select the Kith address book and
  enable contacts sync. Allow the permissions required by your Android installation.
- **iOS:** Settings → Apps → Contacts → Contacts Accounts (wording varies by OS),
  Add Account → Other → Add CardDAV Account. Supply the host/account details and
  app password; use advanced server settings for the displayed URL if needed.
- **macOS:** Contacts → Add Account → Other Contacts Account → CardDAV; use Manual
  or Advanced to supply the displayed server URL and email/app password.
- **Other CardDAV clients:** use the same discovery URL and Basic Auth credentials.

These are setup instructions, not certified device results. Actual Android Chrome,
DAVx5 and live Authentik validation remains **NOT RUN**. See the
[Android runbook](../design/oidc-android-validation.md) and
[acceptance gaps](../design/oidc-validation/task-10-acceptance.md). Client UI varies.

## Policy, permissions and revocation

| Credential | Password login enabled | Password login disabled |
| --- | --- | --- |
| Active DAV app password + matching confirmed email | DAV allowed | DAV allowed |
| Ordinary Kith account password | Existing DAV compatibility | DAV rejected |
| App password used for web login/API token issuance | Rejected | Rejected |

App passwords grant the user's existing account-scoped DAV permissions; they do
not grant administrator access or bypass read-only roles. No interactive TOTP is
required for each sync request. The credential must belong to the supplied email,
even for people in the same account. Malformed/revoked app-password-format inputs
never fall back to ordinary password authentication. Failed requests use the existing
DAV throttling; repeated failures may produce 429 with Retry-After.

Revoke the named credential in Contact sync and confirm. Creation and revocation
require recent completed authentication, including local MFA. Revocation is checked
on every request: the client's next request fails. Other client credentials are
unaffected; Kith contacts remain. Credentials have no automatic expiry. Removing a
user cascades their credentials. Disabling a user at the issuer or logging out of
Kith does not revoke DAV passwords; revoke them explicitly. Turning off password
login does not revoke existing API bearer tokens or sessions.

If sync fails, check the exact URL, matching email, trusted TLS chain, whether the
credential is revoked, current role permissions and throttling. A provider outage
does not invalidate existing DAV credentials. Do not enable ordinary passwords as
a silent fallback. For recovery or database rollback, follow the
[OIDC operator guide](oidc.md#migration-and-rollback).
