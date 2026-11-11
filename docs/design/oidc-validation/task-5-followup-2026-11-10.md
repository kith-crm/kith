# Task 5 follow-up — 2026-11-10

Actual viewer/read-only and cross-account acceptance now **PASS in both policies**, and disabled web submission was actually executed and denied. Fresh A/B reruns close the earlier attribution gap. The remaining failed observation is the **authentication-specific native sync notification** on installed DAVx5/API29; generic native failure is visible. Root acceptance review remains pending. This supplement preserves the original partial evidence and review.

| Criterion | Password enabled | Password disabled |
|---|---|---|
| Actual viewer discovery/read and read-only edit/delete enforcement | PASS | PASS |
| Actual outsider cross-account resource denial with valid own-book control | PASS | PASS |
| Fresh normal OIDC + original MFA, separate A/B UI credentials and actual profiles | PASS | PASS |
| Fresh UI A revocation; exact credential-matched new401; independent B peer visibility | PASS | PASS |
| Native generic failure after revoked-credential rediscovery | PASS | PASS |
| Authentication-specific sync/refresh notification display | FAIL | FAIL |
| Active app-password web submission rejected | PASS | PASS |
| Complementary API token rejection; not DAVx5 evidence | PASS | PASS |
| Follow-up owned resource cleanup/restoration | PASS | PASS |
| Final cross-task Task6 environment cleanup | NOT RUN | NOT RUN |

## Actual execution and source boundaries

Installed at.bitfire.davdroid4.5.21-ose/code405210002 is unchanged, with the original vendor APK provenance/TLS fingerprint recorded in the original report. Actual clients used the supported DAVx5 app proxy, owned reverse9050→19050 and exact-host TLS observation edge18444→verified upstream8444. No DNS/hosts/trust widening, insecure TLS flag, provider edit/principal switch, fake web session or cookie installation. Existing ChromePID17109, original standard tab and Incognito/provider context retained. All device actions used the command returned by the fresh supported device_open binding; observers only read.

Controlled setup created separate synthetic owner/viewer/outsider accounts in each existing dedicated dataset. Viewer role was applied only to the owned viewer and its address book. Confirmed random account passwords and independent app credentials were setup, not acceptance evidence; no browser sessions were manufactured. Actual DAVx5 downloaded the viewer contact, advertised/read the book as read-only, and restored attempted Android edits/deletions rather than issuing server writes. Account-scoped server checks show both owned visible and foreign contact names/timestamps unchanged and neither deleted. **No actual viewer PUT403 is claimed:** the actual client enforced advertised read-only behavior and did not send PUT/DELETE.

For cross-account acceptance, actual DAVx5 supplied the valid outsider app credential against the other account’s exact synthetic contact href. It received PROPFIND404 and displayed a generic configuration failure. Normal discovery using the same outsider credential succeeded with207, and its REPORT returned only its own synthetic contact. Both policies have credential-matched method/path/status and response checks in the JSON. This is actual client execution, not a curl substitution.

## Fresh, attributable revocation reruns

Each policy used original user1 and its original provider/local MFA, two independently named UI-created credentials, and separate actual profiles `Task5F <policy> attribution_A/B`. Creation and A revocation each completed genuine provider Identification/password and original-owner TOTP. Complete action start/end times are recorded. The TLS observer compares exact private credentials in memory to safe subject labels; credentials/headers are never persisted in packet evidence. A request’s credential identity is exact; UI causality is still temporal and not inferred from arbitrary statuses.

| Policy | A UI revocation completed UTC | First new exact-A request UTC | Exact-B marker download UTC | Native B visibility UTC |
|---|---|---|---|---|
| true | 2026-11-10T05:01:06.849Z | 2026-11-10T05:01:57.461858+00:00 /401 | 2026-11-10T05:03:18.964209+00:00 /207 | 2026-11-10T05:03:24.067210+00:00 |
| false | 2026-11-10T05:08:26.380Z | 2026-11-10T05:09:26.308842+00:00 /401 | 2026-11-10T05:09:44.227788+00:00 /207 | 2026-11-10T05:09:49.082844+00:00 |

The B marker was created **after** A revocation. Its vCard appeared in the exact-B REPORT response, Android displayed it, and the native edit screen confirmed “Saving to” the independently configured B profile; no edit was made there. These fresh cases resolve acceptance attribution without inventing historical UI timestamps. A and B were revoked through UI, profiles removed, and exact own credential/contact rows removed through guarded context cleanup.

## Disabled web POST, not merely a hidden form

A dedicated active app password was created through normal UI on `_android_disabled_01` while that same test dataset temporarily ran true policy. Chrome’s supported per-site JavaScript exception for **kith.test only** kept the genuine server-rendered password form static through the ownership-gated false cutover. No form/DOM/session injection occurred. Its original CSRF token and masked password field were retained, and the pinned CLI submitted the form under false policy. Read-only network observation confirmed POST `/users/log-in`, the genuine CSRF value and active app-password value matched in memory,302 then200, and the visible message **“Password login is disabled.”** The app password authenticated to DAV with207 before/during/after the submission. The exception was removed via native Chrome settings and the original JavaScript list restored. Steady false policy still renders no local password form; this case tests the actual route using a genuine pre-cutover form.

API checks are separate complementary probes: enabled401, disabled403, each now carries its policy field. They are not actual-client or browser evidence. The enabled web rejection remains the original actual browser outcome; no API status is substituted for it.

## Native authentication-error display: exhausted limitation

Both policies produced exact-credential401 after controlled revocation. Foreground explicit Sync now and Refresh list, complete notification-shade inspection, DAVx5 Account settings, Android Accounts/Account sync, and Android notification-channel inspection did not show an authentication-specific error. The master/error/user-interaction channels were ON and unchanged. A separate owned admin client in each mode also tested background delivery: the private edge held only its already-generated401 for2 seconds, and recorded that pinned Home completed before delivery. No authentication notification appeared there either. This latency variation did not change authentication, TLS or status/body and did not apply to the fresh A/B cases.

Revoked-credential rediscovery did show **“Couldn't find CalDAV or CardDAV service.”** Native generic client failure therefore PASSes; the more specific sync-authentication notification does **not**. Safe read-only client diagnostics include UnauthorizedException/“Not authorized anymore”; raw client log UI was not opened to avoid possible secret disclosure. [Pinned client source](https://github.com/bitfireAT/davx5-ose/blob/v4.5.21-ose/core/src/main/kotlin/at/bitfire/davdroid/sync/SyncNotificationManager.kt) routes unauthorized errors to notifications, but source intent is not treated as observed UI evidence. No Kith production defect or justified Kith source fix was established. The exact-message display remains a concrete pinned-client/API29 observation failure after supported attempts, rather than an unprepared account/setup gap.

## Contact/resource reconstruction and historical limits

| Policy / contact id | Resource | Origin | Edits | Delete origin | Cleanup |
|---|---|---|---|---|---|
| false / 1 | `10802f96-6e44-4df8-b7fe-9cb54fc1e709.vcf` | Android Contacts | Kith edit; Android edit | Android Contacts | retained soft-deleted contact/tombstone; original Task5 evidence intentionally preserved |
| false / 2 | `c8f18035-63fc-4810-bcc1-3cd7acd45eb0.vcf` | Kith UI after A revocation | Kith edit | Kith UI | retained soft-deleted contact/tombstone; original Task5 evidence intentionally preserved |
| true / 1 | `953106d6-7fdf-4bef-abaf-88c464c5d50a.vcf` | Android Contacts | Kith edit; Android edit | Kith UI | retained soft-deleted contact/tombstone; original Task5 evidence intentionally preserved |
| true / 2 | `f52f8d72-6698-457b-93ae-533735014919.vcf` | Kith UI | no edit case claimed | Android Contacts | retained soft-deleted contact/tombstone; original Task5 evidence intentionally preserved |
| true / 3 | `8ce9593b-c78d-47ea-8085-8c27721618a3.vcf` | Kith UI after A revocation | no edit case claimed | Kith UI | retained soft-deleted contact/tombstone; original Task5 evidence intentionally preserved |
| true / 6 | `ca7c60ee-a184-41ab-9de0-2ee37202f9b7.vcf` | genuine Kith Create Contact UI after A revocation | not an edit test; dedicated peer marker | genuine Kith UI, followed by ownership-guarded context hard deletion | hard deleted through Contacts.hard_delete_contact after UI soft-delete; exact owned marker only |
| false / 5 | `bf03f33a-f28f-49d9-b38b-51f54790dc1d.vcf` | genuine Kith Create Contact UI after A revocation | not an edit test; dedicated peer marker | genuine Kith UI, followed by ownership-guarded context hard deletion | hard deleted through Contacts.hard_delete_contact after UI soft-delete; exact owned marker only |

Enabled Android-origin resource953106d6… used PUT201/204 and was later deleted in Kith. Different enabled resourcef52f8d72… was created in Kith and deleted by Android: its DELETE204 and subsequent duplicate DELETE404 are both preserved. The duplicate404 requester was not credential-tagged, so it is not independently attributed or called a product defect.

Original packet timestamps are recovered only from the original private safe request log. Historical UI action/peer-visibility times that were never stored remain null; no file mtime or guessed timestamp substitutes for them. The original five contact identities/resources/create/delete times come from retained account-scoped DB rows; original intermediate peer UI outcomes remain explicitly execution-report claims. All historical background/foreground packet identities remain uncertain. The fresh cases above, complete new action boundaries and exact subject matching are independently assessable in the [supplement JSON](task-5-followup-2026-11-10.json). Early follow-up compressed-response flags are marked unusable; later decoded checks and actual UI/state observations govern acceptance.

## Owned cleanup, not Task 6 teardown

Final read-only checks in both datasets: **0** follow-up users/accounts/credentials/contacts; original owner1 remains. Eight setup/native-test users and eight owned accounts were removed; six setup credentials disappeared with their accounts, plus two native-error credentials, one web credential and four UI A/B credentials were removed (13 total). Six new synthetic contacts were removed, including two own original-account peer markers purged through the normal Contacts write coordinator after UI soft-delete. Normal audit/change records may remain. Original Task5’s five soft-deleted contacts/four revoked credential audit rows are deliberately preserved as historical evidence, not relabeled as final teardown.

Ten new follow-up profiles were removed; failed cross-account/revoked rediscovery attempts created no extra profile. The original two DAVx5 accounts remain. App proxy restored System default, hostlocalhost/port9050 defaults unchanged, logging disabled, user/system CA policy and already-granted Contacts permissions unchanged. JavaScript exception removed; AOSP restored. Own reverse9050 and observer forward19224 removed; temporary proxy/edge stopped. Own session list empty, Device panel released without shutdown. Final live false PID60034/retained exec56775, fixturePID94030 retained; pool16/ownership600000. Same provider context/count4 and original standard tab preserved. Unlabelled browser metadata target was left untouched.

**Task 6 final cleanup is NOT RUN.** Retain CA alias kith-oidc-owner-049f/fingerprint08:4F:54:51:D3:16:34:A0:58:3E:0F:15:0B:E7:69:74:4F:5E:A7:EA:D3:DD:40:7B:62:69:A9:90:78:F8:D4:B4, drivers, provider/fixture/runtime/databases, original reverse4000 and prior browser restoration files for root final review. No commits, pushes, delegation or production/provider source edits.

Verification: Python adapter compilation, Node syntax checks and git diff whitespace check passed.297 own diagnostic paths checked,0 required secret sanitization;3 public/report files scanned with0 known-secret matches.28 private credential/password fields scrubbed and the web transfer-secret file removed after owned cleanup. Original public partial-artifact hashes verified unchanged.
