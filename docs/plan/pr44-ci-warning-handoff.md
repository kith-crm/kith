# PR 44 CI warning remediation handoff

Use this as the work brief for a new coding session. Implement the warning remediation plan with subagents and independent review, preserving meaningful behavioral tests and the recovery fixes already on this branch. Work from the evidence below rather than treating every log line as a defect or trying to obtain a warning-free log through suppression.

## Starting state

- Repository: `kith-crm/kith`; local workspace was `/Users/basharqassis/Projects/kith`.
- Branch: `feat/stack-40-consolidated`.
- PR: https://github.com/kith-crm/kith/pull/44, targeting `release/0.5.0`.
- Audited head: `9838388e1e159cd8a38a0316f5b0f1794b9f3d8a`.
- CI run: https://github.com/kith-crm/kith/actions/runs/40782716142. All four jobs completed successfully despite the warnings.
- The QA implementation was committed and pushed, and the PR description updated. Warning remediation has not been implemented. This handoff and its JSON inventory are new local documentation; inspect Git state before assuming they have been committed or pushed.
- Baseline verification: 1,800 ExUnit tests passed, 14 real-hook JavaScript tests passed, 14 browser scenarios passed, and `mix quality` passed. Line coverage was 54.59%; the existing 90% threshold was unchanged. CI exports coverage from its single test run and treats the report as diagnostic; test failures remain blocking.

First read repository instructions, inspect `git status`, confirm the current branch/head and PR checks, and preserve any subsequent user changes. Do not reset to the audited commit. This snapshot was collected on 29 October 2026; refresh advisory ranges and available releases before choosing upgrades.

## Durable evidence

Use [the complete warning inventory](pr44-ci-warning-audit.json), reading its metadata/plan first and filtering findings by category or priority rather than dumping the entire JSON into context. It contains a six-step plan and 198 entries, each with an ID, origin, assessment, action, validation criteria and source link:

- 71 Hex advisory IDs across 17 packages. All 71 locked versions matched the fetched OSV affected ranges; 60 IDs also appeared in the production Docker dependency build.
- 19 npm advisory IDs across DOMPurify and Trix, from audits of both lockfiles.
- 28 Sobelow findings, checked against application source and trust boundaries.
- 31 OTP `xmerl_ucs` missing-spec warnings from PLT construction.
- 10 dependency compiler entries, 11 CI/tooling entries, 18 test-runtime causes and 9 PostgreSQL test diagnostic classes.
- One additional finding from inspecting the sanitizer bundled inside Trix.

These are inventory entries, not 198 independently exploitable application vulnerabilities. Some entries group repeated instances of one cause. Conditional/non-applicable findings and one unattributed connection-lifecycle error are explicitly identified.

Raw logs and a searchable report were also written under `/tmp/kith-ci-warning-audit.*`, but the next session must not depend on those files surviving. Recollect logs if necessary:

```sh
gh pr view 44 --json headRefOid,statusCheckRollup,body
gh run view 40782716142
gh api repos/kith-crm/kith/actions/jobs/123148149221/logs > /tmp/pr44-test.log
gh api repos/kith-crm/kith/actions/jobs/123148149244/logs > /tmp/pr44-browser.log
gh api repos/kith-crm/kith/actions/jobs/123148148708/logs > /tmp/pr44-dialyzer.log
gh api repos/kith-crm/kith/actions/jobs/123150236454/logs > /tmp/pr44-docker.log
```

Job logs can expire. The JSON preserves individual advisory IDs and source locations, so it remains useful without raw logs. Use `https://api.osv.dev/v1/vulns/<advisory-id>` to refresh Hex advisory records. Audit npm independently at the repository root and under `assets/`.

## Implementation order

### 1 Production dependency security

Update compatible dependency closures, not isolated transitive packages through forced overrides. Fixed floors from the audit include Bandit 1.14.1, HPAX 1.0.4, Mint 1.10.2, Phoenix 1.8.9, LiveView 1.1.33, Plug 1.19.5, PlugCrypto 2.2.1 and Req 0.6.1. HtmlSanitizeEx 1.4.5 fixes the reported issues on the 1.4 branch; the 1.5 branch has separate fixed versions. These are historical advisory floors, not guarantees about all advisories at implementation time.

The custom note scrubber excludes HTML5/CSS features implicated in several sanitizer advisories, but it still reaches the vulnerable traversal engine. Req fetches user-configured Monica/Immich URLs; timeouts do not bound decompression expansion. Bandit and Mint HTTP/2 exposure depends on actual negotiated protocols and deployment; do not infer complete protection merely from Caddy being present.

Handle Decimal separately: current Ecto/Jason/CLDR/Flop dependency constraints include Decimal 2.x, while the audited fixes include 3.0.0/3.1.2. Bound untrusted numeric strings/exponents before parsing or expansion, then update compatible parent packages. Do not force Decimal 3 into parents that require 2.x. The application rounds with literal precision 2; distinguish that from the separate exponent issue.

Hackney, Tesla and LazyHTML were absent from the production dependency build/tree. They are pulled into test tooling, particularly Wallaby. Hackney 4.x conflicts with several current 1.x parent constraints. Upgrade parents or deliberately migrate retained tests; do not silently discard browser tests.

Add explicit dependency-audit enforcement. `mix deps.get` and `npm ci` currently print security reports without making those reports a blocking security policy. Any exception must name the exact advisory, feature boundary, owner and review date. Cloak currently uses AES-GCM rather than affected CTR ciphers, Cloak PBKDF2 fields are unused, and Swoosh's affected Microsoft Graph adapter is not configured. Recheck those boundaries rather than globally ignoring their packages.

### 2 Application security findings

- **Real missing protection:** `browser_json` in `lib/kith_web/router.ex` fetches a session but omits `protect_from_forgery`. It serves WebAuthn JSON routes. Add CSRF protection and update actual callers/tests with valid tokens. Do not apply session CSRF rules indiscriminately to bearer-only REST routes. SameSite cookies and WebAuthn origin validation are defenses, not replacements for the missing check.
- **Unsafe stored-key decoding:** `lib/kith/accounts.ex:523` and `lib/kith_web/controllers/webauthn_controller.ex:223` decode DB-stored COSE keys using unrestricted `binary_to_term`. Centralize bounded safe decoding, validate the key shape, and handle malformed stored data without crashing. The audit did not establish direct arbitrary request-to-ETF execution.
- **File confinement:** `Storage.read/1` bypasses key validation; `Local.full_path/1` only joins paths. Centralize the root/key policy across reads, writes, deletion and serving. `UploadsController` already authorizes account/type and rejects dot paths, but an `exists?` check followed by serving is not an atomic filesystem guarantee. Declare filesystem/symlink trust assumptions and test actual check/use behavior; `Path.expand` plus a prefix check alone does not solve symlink races.
- **False positives require evidence:** browser CSP is supplied by `KithWeb.Plugs.CSP`; duplicate matching uses static parameterized SQL; vCard output uses fixed non-HTML MIME types; several upload reads consume server-owned Plug/Phoenix temporary paths. Preserve regression evidence and use narrowly documented scanner exceptions, not category-wide ignores.

Sobelow currently runs without an explicit failing policy. After fixing actionable issues and documenting exact false positives, make remaining actionable findings block CI. Keep changes reviewable rather than hiding the existing report wholesale.

### 3 Repair the editor bundle actually shipped

The root lockfile has Trix 2.1.18, while `assets/package-lock.json` has 2.1.17. Esbuild resolves the editor from `assets/`; 2.1.17 is affected by the two Trix paste/drag-and-drop advisories.

More importantly, both installed Trix distributions embed DOMPurify 3.2.7 in their distributed JavaScript, independently of the separate locked DOMPurify 3.3.3 package. The latest Trix 2.1.19 tarball inspected during the audit still embeds DOMPurify 3.4.2, while the standalone patched npm release was 3.4.17. A DOMPurify lockfile override or a green npm audit alone cannot replace Trix's embedded copy.

Align both lockfiles and obtain an upstream rebuilt editor distribution or a reviewed, reproducible source build with a patched sanitizer. Inspect the generated asset's actual provenance/version. Verify relevant upstream paste/drag/drop payloads against the real editor, normal formatting and persisted server sanitation. Optional DOMPurify mode prerequisites are recorded per advisory; do not label all 17 DOMPurify reports as proven editor exploits.

### 4 Test diagnostics and lifecycle reliability

Capture expected negative-fixture logs at the responsible test boundary while retaining exact behavior assertions. SMTP `:boom`, missing files/keys, intentionally invalid imports, retries and injected SQL constraints are largely intentional. Do not remove the negative tests or raise the global Logger level to make CI quiet.

Separate metrics-authentication tests from one initialized exporter integration. The current test explicitly accepts either 200 or 503 because PromEx is disabled, causing an expected warning and a weak assertion.

One `Postgrex.Protocol` message at CI time `22:52:25.190` says a database client exited. Its responsible test was not identified. Trace process/test/query ownership and ensure spawned work stops before sandbox ownership ends. Do not mark this benign or suppress it without attribution. PostgreSQL unique/FK/CHECK/NOWAIT failures listed in the inventory are intentional test controls; keep raw server evidence available.

### 5 CI and compiler warning boundaries

- Upgrade `setup-node@v4` and `upload-artifact@v4` to reviewed releases with supported native action runtimes. Audited latest releases were setup-node 7.1.0 and upload-artifact 7.0.2, both declaring Node24. Project Node22 is a separate setting. `punycode` and `url.parse` warnings occur in action tooling contexts; trace remaining warnings after upgrading their owners.
- Scope ESM to `assets/js/` or use a deliberate `.mjs` boundary. Do not blindly set all of `assets/` to module mode: generated `assets/vendor/heroicons.js` is CommonJS.
- Add exact ExUnit ignore filters for browser boot/control/server/seed scripts. Keep warnings for genuinely misnamed tests and verify discovery does not lose tests.
- Clarify the informational coverage report's expected exit 3 without weakening real test or report-generation failures. Do not lower coverage thresholds or add filler tests.
- Address concurrent cache writers and include BEAM versions in compiled cache keys. Do not serialize the whole workflow just to avoid a cache reservation message.
- Treat Alpine PostgreSQL locale/local-trust initialization messages as CI service configuration, not evidence of production authentication settings. Choose explicit locale/auth policy only with startup and sorting/search checks.

Dependency compiler ownership is recorded individually. Upgrade/fix upstream ASN.1 compiler declarations, metrics range patterns, SweetXML typing, optional PromEx Cowboy handling and Oban Web helpers where appropriate. Do not add unused Cowboy merely to silence an optional-feature warning. `plug_content_security_policy` appears unused because the application has its own CSP plug; confirm references and remove it if redundant. Tesla builder warnings originate in test dependency code.

The 31 `xmerl_ucs` annotations occur during OTP PLT construction. They are not 31 application type errors. The two skipped application Dialyzer findings are existing generated CLDR contract exclusions. Re-evaluate narrow exclusions after upgrades; do not add general compiler/Dialyzer warning suppression.

## Development and test standards

Use subagents for bounded ownership areas, with an independent reviewer for integrated changes. Discover available providers/models through the live catalog. Prefer native same-provider subagents when supported. For T3-owned worktree tasks use `delegate_task`; do not create ordinary top-level threads as a substitute for subagents. Track delegated review rounds by task ID. Coordinate shared files such as `mix.exs`, lockfiles and CI configuration.

Keep tests independent of the implementation: explicit expected values and meaningful contents/ownership/mappings, not just counts or expected values computed by the production helper under test. Use async for isolated cases, and serialize tests that mutate application configuration, adapters, telemetry registration or schema.

For TOCTOU coverage, use messages/barriers and independent database connections when testing database concurrency. A shared sandbox connection can serialize away the race. Prove the intended lock is present and the obsolete lock is absent. Existing importer lock tests use `FOR NO KEY UPDATE NOWAIT` as a positive control because an incidental FK `KEY SHARE` lock would otherwise make a stronger lock probe misleading. Preserve those tests and the fixes in `9838388`.

Requests must remain outside persistence transactions. Completed importer responses/checkpoints commit together and preserve exact counts on retry. Retries intentionally do not restore rows the user deleted after a committed response. Email state/snooze-generation protection is not exactly-once SMTP delivery. Preserve these contracts during dependency upgrades.

## Validation and delivery

Read `test/playwright/fixtures/pr44/README.md` for prerequisites. The local PostgreSQL port was 5434; use a distinct test partition because the default local database previously contained tables from another branch.

```sh
npm ci
npm ci --prefix assets
npm run test:js
MIX_TEST_PARTITION=pr44_warning_qa mix test
mix quality
MIX_ENV=test mix assets.vendor
MIX_ENV=test mix assets.build
PORT=4017 PR44_S3_PORT=9017 PR44_MONICA_PORT=8097 npm run test:pr44
```

The browser script requires PostgreSQL and Mailpit, starts its own Phoenix/Monica/fake-S3 processes, uses a unique default database partition, and intentionally runs one worker because control actions drain whole queues. Install Playwright Chromium and asset tools if this is a fresh checkout. Do not mix `PR44_E2E`/`REVIEW_S3` exports into ordinary ExUnit sessions.

After dependency changes, validate a cold production build and release contents as well as warm local tests. Run affected request/auth/editor regressions before the full suite. Repeat randomized async/concurrency tests where new changes warrant it. Check fresh dependency audits, compiler diagnostics and genuine application type errors; a successful install or a warm build is insufficient.

Keep the inventory current: mark each warning fixed, accepted with exact evidence, or unresolved with the remaining investigation. Report changed behavior, validation and material limits; update PR 44's description after implementation. Register the PR with T3's `link_pull_request` and verify it is linked before finishing. Use normal pushes when publishing completed changes; do not force-push, merge or deploy as part of this brief.

Completion means actionable production security issues are repaired or explicitly mitigated, scanner exceptions are narrow and justified, expected test noise is local, the unexplained lifecycle error is attributed, and real failures still block CI. Do not trade correctness or useful tests for a high coverage percentage or an artificially silent log.

## Implementation follow-up (29 October 2026)

Remediation is implemented and independently reviewed in four rounds. Final local validation passed: 1,843 ExUnit tests, 14 JavaScript tests, all 19 browser scenarios, `mix quality`, entirely fresh core/application PLTs and application Dialyzer, fresh dependency audits, and a cold production release with a final application refresh. The two existing generated CLDR exclusions and the 90% coverage target are unchanged.

Every inventory entry now has an explicit fixed, accepted or unresolved disposition. ASN.1 declaration, metrics range and SweetXML typing warnings remain upstream issues; optional Cowboy and OTP PLT diagnostics remain visible with documented boundaries. Four exact Decimal/Cloak advisory exceptions expire on 29 November 2026. Hosted CI action/cache/artifact and platform evidence remains pending the remediation push.

The three `pr44-*-compatibility.json` files record the complete dependency graphs, code usages, intervening release notes and breaking-change decisions. This full review was retrospective after the user clarified the requirement; future upgrades follow the pre-upgrade review policy in `docs/dependency-audit.md`.
