# Final independent whole-change review — 2026-11-10

Reviewed BASE f8048bab163750feb4458d8389dbff05237f5115 through HEAD e94560b210717204c908389d231f948dda11ef51 plus the pending Task5/Task6 evidence and runbook changes. This gate covers the local-validation changes, not a new review of the preexisting feature implementation. Read CLAUDE.md, the local-validation plan, binding feature design, ledger, implementation/review evidence, full production/test delta, local harness sources and public evidence. No delegation, device operation, provider/database mutation, secret inspection, broad test rerun or commit. The only write is this review.

## Specification/scope verdict

**QUALIFIED ACCEPTANCE for completing the authorized local validation and cleanup work. Full feature/release acceptance is not established. No blocking implementation or evidence correction identified.**

The production change is limited to generic prompt=login together with existing max_age=0 for linking and reauthentication (lib/kith/auth/oidc.ex:74). Ordinary login is unaffected. Existing integer auth_time/60-second boundary checks remain at lines168–170; no provider-name branching, token fabrication, MFA bypass or signature/TLS relaxation is introduced. Regression assertions cover both sensitive intents and ordinary-login omission.

The supported local Authentik authorization profile genuinely executes Identification, database Password and UserLogin on every authorization (scripts/oidc-local/freshness-flow.py:27). It intentionally changes ordinary authorization interaction too. This is a bounded deployment configuration, not an upstream fix or a proof that stock repeated prompt/max_age behavior works. Original delayed failures remain in the historical Android matrix. Supplemental delayed repeated credentials plus local MFA evidence in both policies is accepted with its explicit original-owner and same-provider-session qualifications. Disabled explicit linking remains policy-cutover evidence, not steady-false unlink availability.

Actual Android fixture/provider observations are separated from desktop runs, and DAVx5 observations from protocol/API probes. Fresh DAVx5 A/B cases establish exact-A post-revocation401, exact-B receipt of a newly created marker, and native B visibility. Actual viewer read-only enforcement is client-side suppression/restoration, not a claimed PUT403. Cross-account404 has the valid own-book control. Disabled web rejection uses a genuine retained form submitted after the disclosed policy cutover. Historical unknown timestamps, duplicate DELETE404 and ambiguous packet attribution remain unknown; newer attributable runs do not rewrite them.

The unchanged standard Android runner, full native selection/copy and clipboard-content/original-restoration checks, and external-keyboard traversal remain unverified. Authentication-specific DAVx5 notification remains FAIL in both policies despite generic native failure and actual401 PASS. These limitations prevent an unconditional acceptance label; they do not establish an additional justified Kith code fix. Historical135-file/2614-position boolean metadata loss is explicitly preserved and unreconstructed.

## Quality/security verdict

**ACCEPTABLE for qualified closure; no critical or important finding.**

Ownership gates bind resources to run/worktree labels, with exact-object legacy adoption, and bind process termination to recorded command/start/run identity. Compose is isolated and digest-pinned, has no Docker socket, and keeps database/provider upstream ports loopback-only. Test controls are gated by test mode plus explicit harness environment and run bearer token. Separate databases, process records and ports isolate the desktop freshness runner. The production TLS adapter is unchanged. Desktop ephemeral leaf-SPKI trust is documented separately from Android USER-CA/hostname verification; it should not be generalized into a claim of production/browser trust-policy equivalence.

Structured proxy evidence retains status/shape booleans, not codes, credentials, cookies or JWT values. Successful RP sessions/challenges, not decoded proxy booleans, establish application validation. The public screenshot shows empty login fields. The scoped known-value secret scan is correctly qualified; this review does not claim a universal secret audit or reconstruct deleted raw evidence.

The three test-only stabilizations preserve assertions: next-interval accepted TOTP avoids the observed rollover, explicit initial candidate selection makes negative-index rejection meaningful, and the metrics process barrier waits for startup collection. No production policy relaxation accompanies them.

Independent read-only checks confirmed only the original audit/lamma containers, five volumes and original networks remain, and none of the eleven recorded owned ports listens. Safe retained state contains eight inventory/diagnostic files and a305-entry removal manifest; no runtime.env/run.json or private key state remains. Device restoration is supported by the worker report and sanitized inventory, not independently replayed here. Original profiles/tab, reverse4000, retained packages/caches and clipboard limits are disclosed. Cleanup does not imply that historical tombstones were individually purged before the owned database volume was removed.

## Minor findings

1. **Evidence-only state prevents the documented fresh start.** scripts/oidc-local/up.sh:5 checks directory existence, while ownership.py:10 requires run.json. Task6 deliberately retains .oidc-local/task6 but removes run.json. Thus rerunning README's opening up.sh command now fails before setup. Document archiving the safe evidence directory outside .oidc-local before a new run, preserving the audit artifacts. This is a reproducibility/runbook issue, not a destructive cleanup or acceptance blocker.
2. **One safe inventory permission differs from the report.** .superpowers/sdd/2026-11-10-local-oidc-device-validation/task-6-report.md:23 says inventories are0600; final-verification.json was0644 at review time. Both enclosing directories are0700 and the file contains only safe verification outcomes, so no credential exposure is demonstrated. Set that file to0600 or qualify the statement.

## Verification and closing gate

Independently read final logs:2779 tests/0 failures in135.4s; Hex no advisory packages, both npm audits zero vulnerabilities, Sobelow32 source-bound reviewed exceptions and no unreviewed findings. git diff --check passed. All four source JSON hashes in the final record independently match, and Task5 original/supplement criterion counts reconcile exactly. These are inspected execution records, not independently rerun tests.

The controller may close the validation work and make the final documentation commit under the existing repository commit/test requirements. Resolve or acknowledge the two minor items; no additional runtime/device experiment is required by this review. Replace final-review PENDING only with this qualified verdict, while retaining historical artifacts and all failed/unexecuted acceptance criteria. Do not relabel the overall feature or stock-provider profile as fully accepted.

Controller disposition: both minor findings resolved before the closing commit: restart archival guidance added to scripts/oidc-local/README.md; safe final-verification.json mode set to0600.
