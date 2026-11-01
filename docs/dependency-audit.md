# Kith Dependency Audit

**Purpose:** Enumerate all Hex and npm dependencies for the Kith PRM application, verify license compatibility, document excluded packages, and provide notes for critical integration points.

**Date:** March 2026

---

## 1. Hex Runtime Dependencies

| Package | Version | Purpose | License |
|---------|---------|---------|---------|
| bandit | ~> 1.6 | HTTP server (replaces Cowboy) | MIT |
| cachex | ~> 4.0 | In-memory cache (geocoding TTL, lookup tables) | MIT |
| dns_cluster | ~> 0.1 | DNS-based node clustering for distributed deployments | MIT |
| ecto_sql | ~> 3.12 | SQL query DSL and migration runner | Apache 2.0 |
| ex_aws | ~> 2.5 | AWS SDK core (shared config, credentials, signers) | MIT |
| ex_aws_s3 | ~> 2.5 | S3 file storage operations (upload, download, presign) | MIT |
| ex_cldr | ~> 2.40 | CLDR locale data, pluralization, language tags | Apache 2.0 |
| ex_cldr_dates_times | ~> 2.20 | Locale-aware date and time formatting | Apache 2.0 |
| ex_cldr_numbers | ~> 2.33 | Locale-aware number and currency formatting | Apache 2.0 |
| floki | ~> 0.36 | HTML parser (email template rendering and testing) | MIT |
| gen_smtp | ~> 1.2 | SMTP adapter for Swoosh (relay-based email sending) | MIT |
| gettext | ~> 0.26 | i18n translation extraction and runtime lookup | Apache 2.0 |
| hammer | ~> 6.2 | Rate limiting (login, API endpoints) | MIT |
| hammer_backend_redis | ~> 6.2 | Redis storage backend for Hammer (optional; see notes) | MIT |
| jason | ~> 1.4 | JSON encoding and decoding | Apache 2.0 |
| logger_json | ~> 6.0 | Structured JSON logging for production environments | MIT |
| oban | ~> 2.18 | PostgreSQL-backed background job processing | Apache 2.0 |
| oban_web | ~> 2.10 | Oban dashboard UI for job monitoring | Apache 2.0 |
| phoenix | ~> 1.7.18 | Web framework (router, controllers, plugs) | MIT |
| phoenix_ecto | ~> 4.6 | Ecto changeset and repo integration for Phoenix | MIT |
| phoenix_html | ~> 4.2 | HTML helpers and safe HTML generation | MIT |
| phoenix_live_dashboard | ~> 0.8 | Runtime dashboard (metrics, processes, ETS) | MIT |
| phoenix_live_view | ~> 1.0 | Server-rendered reactive UI via WebSockets | MIT |
| plug_content_security_policy | ~> 0.2 | Content-Security-Policy header management | MIT |
| plug_remote_ip | ~> 0.2 | Real IP resolution behind Caddy reverse proxy | MIT |
| postgrex | ~> 0.19 | PostgreSQL wire protocol driver | Apache 2.0 |
| pot | ~> 1.0 | TOTP/HOTP one-time password generation (2FA) | MIT |
| prom_ex | ~> 1.9 | Prometheus metrics exporter via Telemetry | MIT |
| redix | ~> 1.5 | Redis client (required when RATE_LIMIT_BACKEND=redis) | MIT |
| remote_ip | ~> 1.2 | Trusted proxy configuration and IP parsing | MIT |
| req | ~> 0.5 | HTTP client for Immich API integration | Apache 2.0 |
| assent | ~> 0.2 | Social OAuth with PKCE (Google, GitHub, etc.) | MIT |
| sentry | ~> 10.8 | Error tracking and exception reporting (production) | MIT |
| swoosh | ~> 1.17 | Email composition and delivery abstraction | MIT |
| telemetry_metrics | ~> 1.0 | Telemetry metric definitions (counters, gauges) | Apache 2.0 |
| telemetry_poller | ~> 1.1 | Periodic Telemetry event polling (VM, memory) | Apache 2.0 |
| timex | ~> 3.7 | Timezone-aware date/time arithmetic and parsing | MIT |
| wax | ~> 0.6 | WebAuthn/FIDO2 passkey authentication | MIT |

---

## 2. Hex Dev/Test Dependencies

| Package | Version | Purpose | Type |
|---------|---------|---------|------|
| credo | ~> 1.7 | Static code analysis and style enforcement | Dev/Test |
| dialyxir | ~> 1.4 | Dialyzer type checking with readable output | Dev |
| esbuild | ~> 0.8 | JavaScript bundling (wraps esbuild binary) | Dev |
| ex_machina | ~> 2.8 | Test factory definitions for Ecto schemas | Test |
| mox | ~> 1.2 | Behaviour-based mock library for concurrent tests | Test |
| phoenix_live_reload | ~> 1.5 | Dev-mode live code reloading via file watchers | Dev |
| tailwind | ~> 0.2 | TailwindCSS CLI integration for asset compilation | Dev |

Browser tests use Playwright. On 2026-10-29, the unused Wallaby dependency and case template were removed after confirming no test used them. All existing browser specs were retained; this also removes the test-only Hackney/Tesla closure.

---

## 3. npm Dependencies (assets/package.json)

| Package | Version | Purpose | License |
|---------|---------|---------|---------|
| alpinejs | ^3.14 | UI micro-interactions (dropdowns, modals, toggles) | MIT |
| heroicons | ^2.1 | SVG icon set (outline and solid variants) | MIT |
| trix | ^2.1 | Rich text editor for contact notes and journal entries | MIT |

All npm packages are runtime dependencies bundled via esbuild into `priv/static/assets`.

---

## 4. Prohibited Packages

The following packages are explicitly excluded from Kith:

### waffle
**Excluded.** Waffle is a file upload library that wraps ex_aws internally. Kith uses `ex_aws` and `ex_aws_s3` directly for full control over S3 operations (presigned URLs, multipart uploads, direct streaming). Waffle adds an unnecessary abstraction layer and is not actively maintained at the level required for production use.

### absinthe
**Excluded.** Kith does not expose a GraphQL API. The API design decision was finalized as REST with `?include=` compound document patterns and cursor-based pagination (see ADRs). Adding Absinthe would introduce schema duplication, N+1 complexity, and maintenance overhead with no benefit given the current client model.

### ueberauth
**Excluded.** Kith uses `assent` for OAuth/PKCE social authentication. Ueberauth is a heavier framework with a plug-based strategy system that conflicts with Kith's custom session management. Assent provides a cleaner, composable API and supports PKCE out of the box, which is required for secure OAuth flows.

---

## 5. Critical Package Notes

### wax — WebAuthn/FIDO2
- **Atom:** `:wax` (NOT `:wax_`)
- `wax_` is a different, unrelated package. Using the wrong atom will silently include the wrong library.
- Verify in `mix.exs`: `{:wax, "~> 0.6"}`
- Do not rely on autocomplete or copy-paste from `:wax_` references.

### ex_aws + ex_aws_s3 — File Storage
- Both packages are required separately and must both appear in `deps`.
- `ex_aws` provides the core HTTP signing, credentials, and config machinery.
- `ex_aws_s3` provides the S3-specific request builders and response parsers.
- Neither is a transitive dependency of the other in the Hex graph.

### redix — Redis Client
- Only required when `RATE_LIMIT_BACKEND=redis` environment variable is set.
- In deployments using only ETS-backed Hammer (default), redix is still included in the dependency list but the Redis pool is not started.
- Guard the Redis supervisor startup behind the env var in `application.ex`.

### prom_ex — Prometheus Metrics
- Replaces the deprecated `prometheus_ex` package, which is no longer maintained.
- `prom_ex` integrates with Telemetry events natively and exposes a `/metrics` endpoint compatible with Prometheus scraping.
- Do not add `prometheus_ex` or `prometheus_phoenix` — they conflict with `prom_ex`.

### plug_remote_ip — Real IP Behind Caddy
- Required for correct rate limiting and audit logging when Kith runs behind the Caddy reverse proxy.
- Without this plug, all requests appear to originate from `127.0.0.1`, defeating IP-based rate limiting via Hammer.
- Configure trusted proxy CIDR ranges explicitly; do not trust all forwarded headers blindly.

---

## 6. License Compatibility

All packages listed in this audit are licensed under MIT or Apache 2.0. Both licenses are:

- Compatible with each other for combined works.
- Compatible with Kith's intended licensing model.
- Permissive (no copyleft obligations on proprietary or closed deployments).

No GPL, LGPL, AGPL, or other copyleft licenses are present in the dependency tree. License status should be re-verified via `mix licenses` (using `mix_audit` or a dedicated license checker) at each major dependency upgrade.

---

## 7. Version Pinning

All versions listed use `~>` (pessimistic) constraints:

- `~> X.Y` allows patch increments (`X.Y.z`) but not minor bumps — used for stable libraries with strong semver discipline.
- `~> X.Y.Z` allows only patch increments — used for libraries with a history of breaking minor changes.

**At implementation time, pin each dependency to the latest stable patch release** (e.g., `~> 1.7.18` rather than `~> 1.7`). Record the resolved lockfile (`mix.lock`) in version control. Run `mix hex.audit` in CI to detect known vulnerabilities in resolved versions.


## Upgrade review policy

Before changing a package, inspect its code usages and the complete dependency graph, including unchanged parents, transitive children, optional adapters and build tools. Read the upstream changelogs and breaking-change notes across every intervening release; record runtime floors, schema/protocol changes, and any unavailable release documentation. Resolve compatible parent closures without forced overrides, then validate the affected behavior and cold production release. The PR44 reviews are recorded in `docs/plan/pr44-dependency-compatibility.json`, `docs/plan/pr44-npm-compatibility.json`, and `docs/plan/pr44-ci-action-compatibility.json`.
