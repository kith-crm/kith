# DAVx5 app-password interoperability

**NOT RUN for OIDC/app passwords.** Historical DAVx5/vCard results do not prove
this flow. Use an actual authorized Android device/emulator with DAVx5 already
installed and a disposable test address book. Installation, Contacts permissions,
network and test CA provisioning need separate authorization; do not mutate a
shared device or weaken TLS. See the [Android prerequisites and evidence rules](../../docs/design/oidc-android-validation.md).

For each independent deployment (`PASSWORD_LOGIN_ENABLED=true`, then `false`):

1. Record Android build, device/emulator model, Chrome and DAVx5 versions, run date,
   app/issuer origins, TLS trust and policy. Sign in through real OIDC + local MFA.
   Create two separately named app passwords in Contact sync (DAVx5 A and B).
   Transfer secrets directly to clients; never place them in arguments, evidence,
   terminal history, screenshots or logs. Use a dedicated second client/profile
   whose credential is B; record which actual client and device was used.
2. In DAVx5 A choose login with URL and username. Use the exact server URL shown
   by Contact sync (`https://<test-app>/dav/principals/`), displayed email, and new
   app password A. Discover the test address book, enable Contacts sync, sync now.
   Observe sanitized server PROPFIND/REPORT/GET outcomes (207/200 as applicable)
   and the synthetic contact in Android Contacts. Ensure server/proxy logging
   omits Authorization and sensitive request bodies before testing.
3. Create/edit a synthetic contact in Android Contacts under A. Force DAVx5 sync;
   observe authenticated PUT success and matching Kith test contact. Edit in Kith,
   sync again, verify Android receives changes; delete synthetic contact and verify
   server DELETE outcome. Record only synthetic labels and method/path/status.
4. Repeat as an existing read-only viewer: discovery advertises read-only;
   reads succeed and writes cannot change server contacts. Record actual DAVx5
   behavior and server outcomes. Test another account's address book remains
   inaccessible; app password must never broaden the user's existing scope.
5. Sync client B successfully, revoke only A through Kith with fresh auth/MFA,
   then explicitly Sync now A. Identify the first new authenticated DAV request
   after revocation: expect 401 plus DAVx5 authentication failure. Cached visible
   contacts or a sync timer alone do not prove immediate revocation. Sync B again;
   expect successful authenticated request and contact update. Record timestamps
   and safe statuses, not headers/credentials.
6. Test an ordinary account password in a separate disposable DAVx5 account:
   enabled mode preserves success; disabled mode denies the next authenticated
   request with 401, while a fresh active app password still succeeds. Also verify
   app passwords cannot log into web or issue API tokens. Remove only test-owned
   accounts/contacts and revoke remaining test credentials after evidence capture.

Record each case PASS, FAIL or NOT RUN in
[`task-10-acceptance.md`](../../docs/design/oidc-validation/task-10-acceptance.md).
A curl/Node PROPFIND, fixture import or desktop viewport cannot fill these rows.
