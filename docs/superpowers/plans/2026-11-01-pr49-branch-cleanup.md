# PR49 Branch Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify PR49 by removing investigation artifacts, keeping useful regression coverage, and giving retained tooling permanent names and clear execution commands.

**Architecture:** Preserve the investigation at an immutable Git commit instead of building an archive system. Keep the existing smoke harnesses and regression tests, remove the historical migration experiment, and rename their existing interfaces consistently. Consolidate current dependency decisions and security-check usage into one concise document.

**Tech Stack:** Elixir/Mix/ExUnit, Bash, Python, Node/Playwright, Docker, GitHub Actions.

**Spec:** The binding requirements are recorded in the “Cleanup specification” section of this document, distilled from the user's review instructions. Read that section together with every task.

## Global Constraints

- Planning only until the user authorizes execution. Creating this plan does not authorize cleanup, commits, pushes, PR edits, or deployment.
- Simplification is the goal: no new services, archive infrastructure, testing frameworks, compatibility aliases, or CI jobs.
- Preserve application behavior, dependency versions, ciphertext compatibility, authentication policy, and meaningful regression coverage.
- Preserve active security gates and `scripts/security/sobelow-exceptions.json`; it is CI configuration, not generated evidence.
- Preserve fixture bytes, licenses and provenance when renaming fixture directories.
- Only remove migration-version-specific verification; keep the ordinary production migration smoke check and current release checks.
- Retained reusable tooling must use purpose-based names throughout filenames, modules, environment variables, fixtures, report fields and callers.
- Historical references may retain PR numbers. Do not rewrite archived reports to imply fresh validation.
- Generated outputs belong under ignored `tmp/` directories, never committed evidence directories.
- Do not modify unrelated pre-existing plans or remove the broader PR44 regression harness; rename that harness and preserve its scenarios.
- Execution is sequential: one fresh implementer per task, then independent task review for spec compliance and quality, then one final review. Workers do not spawn workers. Follow host orchestration rules for dispatch, isolated workspaces and review fixes.

## Cleanup specification

The user requested evidence gathering before changes, then a simplification plan targeting subagent-driven development. The agreed direction is to remove historical artifacts, consolidate current documentation, trim one-time verification, remove PR44 naming from reusable tooling, document how retained checks run, and verify the resulting branch.

The reviewed snapshot is `be8259183cfe0b61e639b9fd2eb4b4604e7df969`; the reviewed PR base is `2a9785c635f0cbf3a1cb65a0faa49c2a32c14543`. Revalidate both the actual execution HEAD and PR base before execution; never reset existing work to these hashes. Historical evidence remains available at:

https://github.com/kith-crm/kith/tree/be8259183cfe0b61e639b9fd2eb4b4604e7df969/docs/plan

Acceptance requirements:

1. Raw implementation logs/reports and unpublished upstream experiments added by PR49 leave the current tree; their immutable historical location remains documented.
2. One current dependency/security document replaces the four overlapping remediation documents and snapshots listed in Task 1.
3. Release/proxy smoke tools remain runnable, with permanent names; the Oban schema 12/14 roundtrip is archived in Git history rather than maintained as a generic release requirement.
4. Existing browser, TLS, GeoIP and Redis checks keep their assertions and prerequisites; reusable interfaces lose PR44 naming.
5. Existing CI calls the renamed browser harness. Manual checks have exact commands and prerequisites, without adding jobs or another command-wrapper layer.
6. Validation distinguishes fresh results from historical evidence. No claim that old reports cover the cleaned tree.

## Execution setup and review gates

- Record execution-start HEAD, PR base, working-tree state and available prerequisites in the SDD ledger. Do not overwrite user changes.
- Resolve isolation using the host's supported workspace mechanism; do not create shell worktrees for delegated tasks.
- Use the installed SDD skill's per-plan ignored workspace for briefs, reports and review packages. Do not commit these scratch artifacts.
- For each task, give the worker this specification, that task's full text, exact owned files, and a report path. Record its starting SHA. The report must state changes, commands/results and limitations.
- Review each task's complete starting-SHA-to-ending-SHA diff, with separate compliance and quality verdicts. Fix small review findings directly when host instructions require it, then verify affected behavior; other review routing follows host instructions and SDD.
- Commits belong to execution, not this planning turn. Use one focused commit per implementation task. Do not push, edit the remote PR or merge without authorization.

### Task 1: Remove investigation artifacts and consolidate current documentation

**Files:**
- Delete: `docs/plan/pr44-implementation-evidence/` (51 tracked files in reviewed snapshot).
- Delete: `docs/plan/pr44-upstream/` (98 tracked files in reviewed snapshot).
- Delete: `docs/plan/pr44-remediation-research.json`.
- Delete: `docs/plan/pr44-security-upgrade-evidence.json`.
- Delete after consolidation: `docs/plan/pr44-dependency-remediation-plan.md`, `docs/plan/pr44-security-upgrade-review.md`.
- Create: `docs/dependency-security.md`.
- Modify: remaining current documents that link to these removed paths, as discovered by the reference scan below. Historical plans retain their narrative; repair necessary links to immutable historical URLs rather than rewriting their content.

**Interfaces:** Consumes the immutable reviewed snapshot. Produces `docs/dependency-security.md`, with sections `Current dependency decisions`, `Maintenance follow-ups`, `Running checks`, and `Historical evidence`. Later tasks fill the exact current check commands into `Running checks`.

- [ ] **Step 1: Inventory and verify historical recovery.**

```bash
git cat-file -e be8259183cfe0b61e639b9fd2eb4b4604e7df969:docs/plan/pr44-implementation-evidence/pot-reviewed-validation.json
git ls-tree -r --name-only be8259183cfe0b61e639b9fd2eb4b4604e7df969 docs/plan/pr44-upstream
rg -n 'pr44-(implementation-evidence|upstream|remediation-research|security-upgrade-evidence|dependency-remediation-plan|security-upgrade-review)' docs README.md
```

Expected: historical tree resolves; all incoming references are accounted for before deletion. Confirm the commit is reachable on the remote using read-only GitHub access.

- [ ] **Step 2: Write the concise current document.** Read the final policy/implementation sections of the two Markdown documents and the final validation and maintenance reports before deleting them. Record latest-compatible policy; retained ASN1 Compiler, Bunt, Fuse and POT maintenance uncertainty; the decision to retain the ASN helper and POT with application guards; current security gates; and validation limitations. Preserve any still-actionable decision discovered in those final sections. Link the immutable tree above and the historical final-validation report. Do not copy package inventories, historical failures, prose transcripts, test counts or image IDs into a new report.
- [ ] **Step 3: Delete only the listed artifacts and replace incoming links.** Use explicit `git rm` paths. Link current decisions to the new document; link historical evidence to its exact old path under the immutable commit. Leave other `docs/plan/pr44-*` documents inherited from the PR base alone.
- [ ] **Step 4: Verify documentation integrity.** Repeat the reference scan. Every surviving reference to a deleted file must resolve through an immutable GitHub URL, not a missing relative path. Compare `git diff --name-status` to the deletion inventory. Keep the new document concise; no replacement evidence dump.
- [ ] **Step 5: Commit.** Suggested message: `docs: consolidate dependency decisions and remove historical artifacts`.

### Task 2: Simplify and rename production smoke tooling

**Files and exact moves:**
- `scripts/security/pr44_release_smoke.sh` → `scripts/security/release_smoke.sh`.
- `scripts/security/pr44_release/` → `scripts/security/release/`.
- `scripts/security/pr44_proxy_smoke.sh` → `scripts/security/proxy_smoke.sh`.
- `scripts/security/pr44_proxy/` → `scripts/security/proxy/`.
- Modify: `docs/dependency-security.md`.
- Keep unchanged: `scripts/security/dependency_graph.exs`, `dependency_audit.exs`, `sobelow_check.exs`, `sobelow-exceptions.json`.

**Interfaces:** Consumes a prebuilt image argument and optional report directory. Produces `scripts/security/release_smoke.sh IMAGE [REPORT_DIRECTORY]` and `scripts/security/proxy_smoke.sh IMAGE [REPORT_DIRECTORY]`, defaulting to `tmp/security/release` and `tmp/security/proxy`. Use `KITH_RELEASE_PROBE`, `KITH_PROXY_BROWSER_URL`, `KITH_PROXY_REPORT_DIRECTORY`; report keys `release_check` and `proxy_identity`; module `Kith.ReleaseSmoke`, `Kith.SignupIdentityObserver`, `Kith.ProxyIdentityProbe`; headers `X-Kith-Probe-ID`, `x-kith-verified-client`, `x-kith-socket-peer`.

- [ ] **Step 1: Capture behavior before edits.** Read both runners and all four helpers. List retained checks and their report producers/consumers in the worker report. Confirm the migration roundtrip is the sole consumer of `expect_version/1`, `constraints/0`, and `retained_jobs/1`.
- [ ] **Step 2: Remove the historical roundtrip.** Delete `run("roundtrip")`, its three private helpers, and `release_eval oban-roundtrip ...`. Remove the `release_eval` shell function only if it now has no callers. Keep the subsequent `Kith.Release.migrate()` invocation and every other check, including legacy ciphertext interoperability. Remove any roundtrip-specific result assertion if present.
- [ ] **Step 3: Move files and update coupled interfaces atomically.** Use `git mv` for the four moves above. Apply the exact interfaces in this task to producers and consumers together. Replace remaining PR44-only fixture labels with `release-smoke` or `proxy-smoke` purpose labels; use `/tmp/kith-signup-observations.jsonl` consistently. Remove PR44 from mount paths, synthetic secrets, request IDs, fixture account names and log markers. Keep output/report matching synchronized. Preserve shell executable permissions and cleanup traps. Do not change proxy trust addresses or runtime behavior.
- [ ] **Step 4: Run static checks.**

```bash
bash -n scripts/security/release_smoke.sh
bash -n scripts/security/proxy_smoke.sh
node --check scripts/security/proxy/browser.mjs
python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/security/proxy/assert_response.py").read_text())'
rg -n -i 'pr44|roundtrip|oban_roundtrip' scripts/security
```

Expected: parsers succeed; the search finds no PR44 identifiers or removed migration mode in retained scripts. Parse embedded Python heredocs as well, without running Docker side effects during syntax checks.
- [ ] **Step 5: Document exact manual usage.** Add Docker, Python, installed Node dependencies/Chromium and prebuilt-image prerequisites. Commands are `bash scripts/security/release_smoke.sh kith:review`, `bash scripts/security/proxy_smoke.sh kith:review`, and `MIX_ENV=test mix run --no-start scripts/security/dependency_graph.exs`. Explain that smoke checks create disposable local services and output under ignored `tmp/security/`. Dynamic runs occur once in Task 4 against the final tree.
- [ ] **Step 6: Commit.** Suggested message: `refactor: give security smoke checks permanent names`.

### Task 3: Give regression fixtures permanent names and execution commands

**Files and exact moves:**
- `test/fixtures/geoip_pr44/` → `test/fixtures/geoip/`.
- `test/fixtures/tls_pr44/` → `test/fixtures/tls/`.
- `test/playwright/fixtures/pr44/` → `test/playwright/fixtures/regressions/`.
- `test/playwright/pr44-regressions.spec.ts` → `test/playwright/regressions.spec.ts`.
- Modify callers: `test/kith/ip_geolocation_upgrade_test.exs`, `test/kith/tls_transport_boundary_test.exs`, `test/fixtures/rate_limiter_redis/probe.ex`, `test/playwright/fixtures/s3/fake_s3.py`, `config/test.exs`, `mix.exs`, `package.json`, `.github/workflows/ci.yml`, `.gitignore`.
- Modify: moved harness README and `docs/dependency-security.md`. Update other executable callers only if the inventory scan identifies them; record that bounded addition in the report.

**Interfaces:** Browser command `npm run test:regressions`; harness variables `KITH_E2E`, `KITH_TEST_SERVER`, `KITH_TEST_MONICA_URL`, `KITH_TEST_MONICA_PORT`, `KITH_TEST_S3_PORT`, `KITH_TEST_FIXTURE_TOKEN`; control marker `KITH_TEST_RESULT=`; Redis variable `KITH_TEST_REDIS_URL`; browser logs `tmp/browser-regressions/`; default database partition prefix `browser_regressions_`. Do not rename generic existing variables such as `PORT`, `DB_PORT`, `REVIEW_S3` or `PLAYWRIGHT_BASE_URL`.

- [ ] **Step 1: Inventory complete producer/consumer pairs.**

```bash
git grep -n -i pr44 -- config scripts test .github package.json mix.exs .gitignore
```

Read every returned executable caller. Separate historical README test counts from active instructions. Existing PR44 browser checks predate this PR but remain maintained; preserve all their scenarios during this rename.
- [ ] **Step 2: Move fixtures and rename coupled interfaces.** Use `git mv` for the four moves. Apply the variable mapping above across shell, Python, Elixir, TypeScript and config. Rename `PR44Control` to `Kith.RegressionControl`; use `/__kith_fixture__` for fixture identity endpoints and `kith-fixture-token` for their synthetic bearer value in all matching producers/consumers. Replace other PR44-only strings with `regression` purpose labels, keeping assertions and fixture values synchronized. Update `test_ignore_filters`, package script, CI command/artifact path and `.gitignore`. Remove the obsolete script name rather than retaining an alias. Do not alter the package dependency graph or lockfiles for a script-key rename.
- [ ] **Step 3: Simplify the moved README.** Keep prerequisites, safety guards, commands, overrides, isolation and diagnostics. Remove accumulated historical execution counts and point to the immutable history for those. Add the Redis invocation below to the central check document; retain its requirement for an isolated Redis instance at version 7 or newer.

```bash
KITH_TEST_REDIS_URL=redis://127.0.0.1:6384 MIX_ENV=test mix run --no-start test/fixtures/rate_limiter_redis/probe.ex
```

- [ ] **Step 4: Verify fixture preservation and wiring.** Compare GeoIP database and license hashes against the execution-start tree; attribution remains intact. Run `bash -n test/playwright/fixtures/regressions/run.sh`; parse changed Python using `ast.parse` to avoid generated bytecode. Run `npx playwright test --project=e2e --list` and confirm the renamed suite is discovered. Run `git grep -n -i pr44 -- config scripts test .github package.json mix.exs .gitignore`; expect no remaining active PR44 identifiers. Inspect CI diff to ensure job behavior, security gates and artifact collection remain intact.
- [ ] **Step 5: Commit.** Suggested message: `refactor: name regression harnesses by purpose`.

### Task 4: Validate the final cleanup and prepare handoff

**Files:** No planned application edits. Fix only cleanup regressions discovered here; update `docs/dependency-security.md` if a documented command is wrong. Store run output in ignored directories and validation results in the SDD report. Prepare the proposed PR description in the ignored workspace, without publishing it.

**Interfaces:** Consumes the completed Tasks 1–3 tree. Produces fresh validation evidence, an explicit limitations list, and a proposed concise PR description linking current decisions and immutable historical evidence.

- [ ] **Step 1: Check final scope.**

```bash
git diff --check
git status --short
mix format --check-formatted
git grep -n -i pr44 -- config scripts test .github package.json mix.exs .gitignore
```

Expected: clean diff/formatting and no PR44 identifiers in active tooling. Compare cleanup-start-to-final diffs for `lib/`, dependency manifests/locks and migrations: no application/dependency changes; only the planned `mix.exs` fixture filters and `package.json` script name may change. Check deleted relative documentation links and ignored output paths.
- [ ] **Step 2: Run application and security checks once.** Use the documented local test database setup; do not point probes at shared services.

```bash
mix test
npm run test:js
MIX_ENV=test mix run --no-start scripts/security/dependency_graph.exs
MIX_ENV=test mix run --no-start scripts/security/dependency_audit.exs
MIX_ENV=test mix run --no-start scripts/security/sobelow_check.exs
```

Expected: suites and existing security gates pass; generated reports remain ignored. Do not rewrite security exception hashes to bypass a failure; investigate it against the unchanged reviewed application sources.
- [ ] **Step 3: Run the renamed browser and manual integrations once.** With PostgreSQL/Mailpit and isolated Redis prerequisites satisfied, run `npm run test:regressions` and the Task 3 Redis command. Build `docker build -t kith:review .`, then run both Task 2 smoke commands. Expect all scenarios to pass and disposable resources to be cleaned up. If prerequisites are unavailable, report exactly which commands were not run; static parsing is not a smoke-test pass. Do not silently substitute historical results.
- [ ] **Step 4: Request final independent review.** Review the entire cleanup-start-to-final range and inspect the resulting PR diff against its actual current base. Reviewer checks preservation of meaningful coverage, complete naming migrations, evidence accessibility, retained security gates, and simplification rather than new infrastructure. Supply existing run results; do not ask the reviewer to repeat passing suites without a new reason.
- [ ] **Step 5: Prepare handoff.** Record the deletion/retention summary, fresh checks and limitations. Draft a PR description replacing current-tree raw-evidence links with the new concise document and immutable historical links. Leave remote editing, push and merge to a separately authorized execution step. If validation required fixes, commit them with `fix: resolve cleanup verification findings`; otherwise no empty validation commit.

## Completion checklist

- [ ] Investigation output removed from the current tree and recoverable from the documented immutable commit.
- [ ] Current decisions and usage documented without copying historical evidence dumps.
- [ ] Reusable names are purpose-based across all producer/consumer interfaces.
- [ ] One-time migration experiment removed; current migration/release behavior checks retained.
- [ ] No lost regression assertions, fixture provenance or security gates.
- [ ] Fresh validation results and any unrun checks reported explicitly.
- [ ] No cleanup work starts as a side effect of writing this plan.
