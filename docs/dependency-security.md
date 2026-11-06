# Dependency security

## Current dependency decisions

Use the latest mutually compatible stable releases. A release older than two years triggers a maintenance review, not automatic replacement. Review support, repository status, package scope, parent integration and tested compatibility; release age and parent usage alone prove neither maintenance nor abandonment. Existing replacement and adoption criteria still apply to proposed replacements.

Calendars 2.4.4 with DigitalToken 1.0.0 and PromEx 1.12.0 with Peep 4.4.0 are accepted compatible selections. Do not force newer children through incompatible constraints, downgrade their parents or adopt unpublished forks merely to satisfy an absolute-latest target.

Retain ASN1 Compiler 0.1.1: no demonstrated Kith advisory, build or compatibility failure justifies owning the prepared alternative's compiler lifecycle, cache, failure recovery and packaging. Retain POT 1.0.2 with the application guards and regression coverage described below. Retain the existing Bunt and Fuse versions. No age-only replacement, authentication rewrite or new infrastructure is required by this policy.

POT integration rejects malformed OTP/recovery values and invalid secrets while preserving compatible Base32 secrets and encrypted credentials. Browser second-factor verification has a separate 10 attempts/minute budget per verified IP; browser and API verification share 10 attempts/minute per user after first-factor proof. Existing password-login and API-IP limits remain separate. Denials return 429 with a rounded-up Retry-After; backend failure cannot authorize a session or token. Only the active OTP/recovery form input is enabled, and recovery codes are consumed once.

The accepted TOTP window remains the current and next two 30-second intervals. Stateless TOTP and signed-challenge reuse remain possible; no accepted-counter persistence or replay protection was added. POT comparisons are not claimed constant-time. OTP auto-submit uses JavaScript digit checks and native `form.submit()`, bypassing native HTML constraint validation; recovery uses native validation. Successful CSRF-protected submission was verified historically, without a new invalid-CSRF negative test. Algorithm vectors and integration tests do not establish complete MFA security certification.

## Maintenance follow-ups

Upstream maintenance remains unconfirmed for **ASN1 Compiler, Bunt, Fuse and POT**. Retention does not label them confirmed maintained, abandoned, vulnerable or incompatible. Full maintenance-policy closure remains open until support evidence is established or a justified replacement is implemented and verified.

The reviewed evidence supports retaining the other older dependencies under the revised policy. Keep Prometheus Core on a release/support responsiveness watchlist: accepted project work supports retention, but the installed release does not thereby contain unreleased fixes. See the historical [maintenance review](https://github.com/kith-crm/kith/blob/be8259183cfe0b61e639b9fd2eb4b4604e7df969/docs/plan/pr44-implementation-evidence/maintenance-review.json) for the bounded evidence and its limitations.

Unpublished Calendars, PromEx, Wax and Credo experiments remain optional historical contribution material; they are neither adopted nor required. A clean audit or passing local build does not establish upstream maintenance or authorize upstream communication or deployment.

## Running checks

Install the locked Mix dependencies and both npm dependency graphs before running these checks from the repository root:

```bash
mix ci.audit
MIX_ENV=test mix run --no-start scripts/security/dependency_graph.exs
mix quality
```

`mix ci.audit` runs Hex, root npm, assets npm and the reviewed Sobelow check. It clears inherited Hex ignore variables, runs every check even after a failure and exits unsuccessfully if any check fails. Output goes directly to the terminal and CI logs. No CVE/retirement exceptions, inherited suppression, incompatible overrides or weakened failure handling are permitted. The optional dependency graph check verifies installed constraints and runtime floors.

`mix quality` includes compilation, formatting, strict Credo, the source-bound Sobelow gate and Dialyzer for local pre-commit checks. CI runs Sobelow once through `mix ci.audit`. Keep `scripts/security/sobelow-exceptions.json`: each reviewed exception is tied to exact source and an expiry; changed, expired, stale or unreviewed findings fail closed. Sobelow diagnostics remain under ignored `tmp/` paths.

The production smoke checks require Docker with a running daemon, Python 3, the installed root Node dependencies and Playwright Chromium (`npx playwright install chromium`), and a prebuilt production image tagged `kith:review`. They consume the image without building it. Run them from the repository root:

```bash
bash scripts/security/release_smoke.sh kith:review
bash scripts/security/proxy_smoke.sh kith:review
```

Both runners accept an optional second argument for the report directory. Their defaults are `tmp/security/release` and `tmp/security/proxy`. They create disposable local services and remove them on exit; generated reports and logs belong under ignored `tmp/security/`. The release check verifies ordinary production migrations, runtime modes, encrypted credential interoperability, cache behavior, metrics and security budgets. The proxy check uses the actual Caddy configuration and Chromium to verify transported client identity, signup/login/API budgets and log redaction.

The maintained browser regressions require PostgreSQL, Mailpit, the installed
Mix/npm dependencies and Playwright Chromium. Run the isolated local harness:

```bash
npm run test:regressions
```

It starts Phoenix and deterministic Monica/S3 fixtures, uses a unique test
database partition by default, and writes logs under `tmp/browser-regressions/`.
See the [harness instructions](../test/playwright/fixtures/regressions/README.md)
for setup, port overrides, isolation and diagnostics.

The Redis rate-limiter probe requires an isolated Redis instance at version 7 or
newer; run it separately from ordinary ExUnit tests:

```bash
KITH_TEST_REDIS_URL=redis://127.0.0.1:6384 MIX_ENV=test mix run --no-start test/fixtures/rate_limiter_redis/probe.ex
```

## Historical evidence

The removed investigations and upstream experiments are recoverable from the immutable [reviewed tree](https://github.com/kith-crm/kith/tree/be8259183cfe0b61e639b9fd2eb4b4604e7df969/docs/plan). The [final POT/ASN validation report](https://github.com/kith-crm/kith/blob/be8259183cfe0b61e639b9fd2eb4b4604e7df969/docs/plan/pr44-implementation-evidence/pot-reviewed-validation.json) records the tested source snapshot; the [policy review](https://github.com/kith-crm/kith/blob/be8259183cfe0b61e639b9fd2eb4b4604e7df969/docs/plan/pr44-implementation-evidence/policy-review.json) records the revised acceptance policy.

Those reports are historical, not fresh validation of the cleaned tree. Production verification covered Linux/arm64 musl, synthetic credentials and local provider fixtures; it did not establish Linux/amd64, every runtime/device matrix, live provider accounts or embedded standalone-tool Rust/Go dependency inventories. Remote CI was not rerun for that validation. Historical audit results are point-in-time evidence, and maintenance reviews do not predict future maintainer responsiveness.
