# Monica HTTP Attempt Rate Limiting Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Apply the configured Monica request budget to every outbound attempt in a separate PR from merged PR #52.

**Architecture:** A shared Monica HTTP boundary owns per-attempt throttling while Req retains retries, redirects and transport handling. All Monica callers use that boundary and preserve their worker policies.

**Tech Stack:** Elixir, Req 0.7.5, Finch, Oban, Hammer ETS/Redis.

**Spec:** The approved six-step conversation plan; the Global Constraints below capture its binding requirements.

## Global Constraints

- Every outbound Monica HTTP attempt, including photo listings, document downloads, retries, and redirect hops, must acquire exactly one slot from the existing per-host RateLimiter using MONICA_RATE_LIMIT_PER_MINUTE (55 only as fallback).
- Keep the existing ETS/Redis backend and its node-local/shared semantics. Do not introduce another limiter, change unrelated HTTP consumers, or add concurrency.
- Preserve bearer authentication and redirect credential stripping, bounded response handling, binary document behavior, worker cancellation checks, finite retry limits, and timeout policies.
- Honor Retry-After and avoid overlapping photo-worker/client retry loops. Preserve test request-option injection without allowing it to bypass the limiter accidentally.
- Test real attempt dispatch, not just wrapper calls. Deterministic admission tests must verify configured values, host isolation, concurrent callers, retries, redirects, and no double charging. Use controlled test-bucket resets for synchronization; retain existing short-window limiter tests for time-based refill.
- No secrets in logs or fixtures. Do not change field labels, contact backfill behavior, or other unrelated import logic.

## Task 1: Implement a shared Monica HTTP request boundary

Create lib/kith/imports/sources/monica_api/http.ex and focused tests in test/kith/imports/sources/monica_api/http_test.exs. Design a small get(url, options) interface building on Kith.BoundedHTTP and Req 0.7.5. Apply RateLimiter.wait! for the actual outgoing request host immediately before each HTTP attempt (initial, retry, redirect), exactly once. Inspect installed Req source to choose a hook/adapter seam that actually executes on retries/redirects; demonstrate with tests. Keep Req transport injection and ordinary request options, existing response shapes, response limit, binary safety, auth/redirect behavior and retry/timeouts. Use Req's bounded retry and Retry-After handling rather than inventing a second retry loop. Document the seam and its rationale in code where necessary. If BoundedHTTP requires a small reusable request seam, keep existing consumers unchanged in behavior and run its tests.

Use test-first development with captured RED and GREEN output. Cover concurrent same-host requests sharing a budget, different hosts independent, configured budgets above/below fallback (without a real minute wait), each retry including transport failure and 429 consuming a slot, each redirect hop charged against its host, and no double charge. Include real local HTTP transport tests where mocks hide Req execution behavior. Run focused tests and self-review, commit only task files, and write the specified report with commands/output, files, concerns, and commit SHA. Do not dispatch any subagents.

## Task 2: Route all callers through the boundary and document configuration

Depends on Task 1. Migrate lib/kith/imports/sources/monica_api.ex and the MonicaMiscDataWorker, MonicaPhotoSyncWorker, MonicaDocumentImportWorker to the new boundary. Remove outer wait calls so attempts aren't counted twice; retain misc rate-wait observability where practical through the shared boundary without losing cancellation checks. Remove the photo-specific fixed 65-second retry loop and use the shared Req retry mechanism with finite retries, respecting Retry-After. Keep other per-caller retry/timeout policies. All photo API and document download calls must participate. Examine config/runtime.exs, .env.example and Docker Compose environments; make the env option consistently available in both supported dev/prod setups. Correct misleading default-limit comments and document restarts, actual configuration, per-host semantics and ETS vs Redis scope. Add regression tests at caller seams proving photos/documents use the limiter and preserving credential behavior, binary handling, response limits, cancellation and retry outcomes. Cover default/config override behavior and invalid input in existing configuration-test conventions.

Use test-first development with RED/GREEN evidence. Run focused worker/source/HTTP tests, self-review and commit. Write the specified report. Do not dispatch any subagents.

## Completion validation

After task reviews and a whole-branch review, run all local equivalents of .github/workflows/ci.yml: dependency fetch, warnings-as-errors compile, formatting, strict Credo, DB setup/migrations, full tests with coverage export and informational report, both npm installs, ci.audit, JS tests, assets/browser regressions, Dialyzer, Docker build/version/non-root verification. No publish or merge. Push the new branch and create a PR against release/0.5.0 with evidence and limitations. Link the PR to the thread immediately.
