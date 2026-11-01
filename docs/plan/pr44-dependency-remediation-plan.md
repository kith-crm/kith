# PR44 dependency remediation implementation plan

> Current implementation: retain the working ASN helper and verify narrow POT input, throttling and form fixes. See [current decisions](#retention-decisions-and-pot-integration-fixes) and [current validation](pr44-implementation-evidence/pot-reviewed-validation.json). The latest-compatible policy still applies; earlier research/validation snapshots below are historical.

Research date: 1 November 2026. Source head: `3ac2faba0012b461b573f03c739d4abeac097511`. This plan addresses the [security review](pr44-security-upgrade-review.md). The accompanying [research evidence](pr44-remediation-research.json) records both Kith usage and resolved dependency edges.

The first deliverable is a working application with **all seven CVEs removed and no advisory exceptions**. This can be achieved without replacing authentication, adding a secrets service, or rewriting stored ciphertext. The second deliverable is the requested latest-version and maintenance policy across the entire graph. It has three reproducible version conflicts and several upstream release dependencies; it must remain explicitly incomplete until those are resolved. A green security audit alone is insufficient to declare the second deliverable complete.

## Corrections established by research

| Previous uncertainty | Verified fact | Decision |
| --- | --- | --- |
| Cloak requires a new service and mandatory re-encryption | The configured format is a fixed TLV tag followed by AES-GCM IV, MAC and ciphertext. OTP and Cloak 1.1.4 interoperate both ways in a synthetic probe. Kith already owns an OTP AES-GCM Ecto type. | Replace Cloak's integration with a small Ecto type using maintained OTP crypto and the **existing byte format and key**. Do not introduce OpenBao for encryption. |
| All latest CLDR targets can be upgraded together | Calendars 2.4.4 requires DigitalToken `~> 1.0`; DigitalToken 2.1.0 is incompatible. The resolver selects Calendars 2.4.3 when DigitalToken 2.1.0 is pinned. | For the security change, choose Calendars **2.4.4** and retain DigitalToken **1.0.0**. Final DigitalToken 2.1.0 requires an upstream Calendars release accepting 2.x. This is an explicit latest-version blocker, not an exception to conceal. |
| Latest direct dependencies imply latest transitive dependencies | The latest-direct probe resolves Peep 4.4.0 and ExHashRing 6.0.4. Latest releases are 5.0.1 and 7.0.0. | Require compatible parent releases or parent replacement. Do not force overrides. |
| Newer circuit-breaker wrappers remove Fuse | ExternalService 3.2.3, BreakerBox 0.5.1 and ReqFuse 0.3.2 all still require Fuse. | Reject all three as Fuse-removal solutions. |
| ConCache is a maintained replacement by the release-age rule | ConCache 1.1.1 was released **23 September 2024**, despite newer repository activity. | Reject it under the two-year rule. |
| Nebulex removes all stale dependencies | Nebulex 3.1.0 and its local adapter 3.1.0 both require NimbleOptions. | Select it to remove Cachex's stale helpers, but retain NimbleOptions as a separate release blocker. |
| POT's current drift window is the previous period | `addwindow: 1` moves the reference interval forward; `window: 1` then checks around it. Kith accepts the current, next and second-next 30-second intervals. | Preserve this behavior in a compatibility fixture, then deliberately change to previous/current/next only in the separately reviewed TOTP migration. Do not call the change behavior-preserving. |

The exact CLDR constraint is published in [Calendars 2.4.4 metadata](https://hex.pm/api/packages/ex_cldr_calendars/releases/2.4.4). Cachex's [4.1.1 manifest](https://hex.pm/api/packages/cachex/releases/4.1.1) and PromEx's [1.12.0 manifest](https://hex.pm/api/packages/prom_ex/releases/1.12.0) establish the other incompatible pairs. Actual solver failure logs accompany the research.

## Evidence already obtained

All probes ran in temporary Mix projects, leaving Kith's `mix.exs`, `mix.lock` and application files unchanged. The temporary projects resolve the complete union of Kith's dev/test/runtime Hex dependencies, including optional dependencies selected by other roots. Heroicons is omitted from the probes because it is a non-OTP asset Git checkout; its unchanged tag remains in the final application.

| Probe | Result | What this establishes |
| --- | --- | --- |
| Current graph | 107 Hex nodes; 198 installed edges; every installed requirement matches | Baseline includes unchanged parents and children |
| Latest direct Hex roots | 105 nodes; 197 installed edges; no requirement mismatch | Widened direct requirements are solvable; Poolboy and unicode_util_compat disappear. This is not a compilation or behavior test. |
| Security group with Cloak removed | Resolver succeeds; fresh unfiltered audit reports no retired or security-advisory packages | A dependency graph closing all seven CVEs exists |
| Final security choice with Calendars 2.4.4 and DigitalToken 1.0.0 | Resolver succeeds; same unfiltered audit passes | Security closure does not require the incompatible CLDR pair |
| Every installed Hex node pinned to its latest stable release | Resolver fails: Cachex requires ExHashRing 6.x | Complete latest graph cannot be obtained with current parents |
| PromEx 1.12.0 plus Peep 5.0.1 | Resolver fails | Independent second blocker |
| Calendars 2.4.4 plus DigitalToken 2.1.0 | Resolver fails | Independent third blocker |
| Cloak and OTP GCM interoperability | Synthetic empty, text and binary payloads pass both directions; altered MACs fail | An exact-format replacement is feasible without rewriting rows |

These results validate graph feasibility and a ciphertext contract. They do not establish that upgraded Kith compiles, passes tests or is production-ready. The full target application must pass the checks specified below.

## Required review method for every dependency change

Each implementation change must carry a two-sided compatibility record:

1. **Kith side:** affected modules, configuration, tests, scripts, vendored browser assets, protocols/macros, Ecto types and deployment paths. A search with no direct module references is not proof of no impact: transitive parsers, encoders and TLS clients execute underneath Kith.
2. **Tree side:** old and target parents, every active child requirement, optional integrations present in Kith, absent optional integrations, runtime floors, newly introduced/removed packages and all intervening release changes. Test dependencies of an upstream package are not automatically Kith dependencies.
3. **Behavior side:** a named verification that exercises the changed behavior through the real Kith boundary. Compilation proves neither correct pagination nor correct encryption, TLS, rate limits, metrics or HTTP retries.

The evidence JSON records all current and candidate nodes, optional edges and requirement matches, plus a per-upgrade usage/source record. Implementation must regenerate it from the actual final lockfile. Any changed package with missing release documentation needs a source diff and a named behavioral check before completion; “patch release” is not an exemption.

## Change 1 Close all seven CVEs

Owner role: application/security maintainer. This is one deployable change; keep the security gate failing while its components are incomplete.

### Dependency targets

| Package | Target | Tree conditions |
| --- | --- | --- |
| assent | 0.3.2 | Existing direct requirement permits it; preserve configured GitHub/Google strategies and actual HTTP adapter |
| phoenix_html | 4.4.0 | Compatible with current Phoenix/LiveView requirements |
| ssl_verify_fun | 1.1.9 | Shared by Assent's selected optional integration and required OctoFetch path |
| decimal | 3.2.0 | Require all CLDR parents below to accept 3.x |
| ecto / ecto_sql | 3.14.2 / 3.14.0 | Ecto SQL target requires Decimal 3 and Ecto 3.14.x; Postgrex 0.22.4 already permits Decimal 3 |
| ex_cldr / cldr_utils | 2.47.5 / 2.29.7 | Both add Decimal 3 support |
| ex_cldr_numbers | 2.38.3 | Accepts Decimal 3 and DigitalToken 1 or 2 |
| ex_cldr_calendars / ex_cldr_currencies | 2.4.4 / 2.17.2 | Calendars requires DigitalToken 1.x; explicitly retain 1.0.0 |
| cloak / cloak_ecto | Remove | Replace their only Kith integration as specified below |

Run a targeted `mix deps.update` for the changed direct packages and affected transitive group after updating requirements. Retain the reviewed `mix.lock`. Do not add every transitive package as a production root just because the research probes use exact pins. Do not use `override: true` or unlock the whole graph without reviewing the resulting deltas.

### Exact replacement for Cloak

Production and default configuration both select only `Cloak.Ciphers.AES.GCM`, tag `AES.GCM.V1`. Preserve:

```text
<<1, 10, "AES.GCM.V1", iv::binary-size(16), mac::binary-size(16), ciphertext::binary>>
cipher: :aes_256_gcm
AAD: "AES256GCM"
key: existing decoded CLOAK_KEY, exactly 32 bytes
```

Source contracts: [Cloak 1.1.4 GCM](https://github.com/danielberkompas/cloak/blob/v1.1.4/lib/cloak/ciphers/aes_gcm.ex), [tag encoder](https://github.com/danielberkompas/cloak/blob/v1.1.4/lib/cloak/tags/encoder.ex), and the [OTP crypto API](https://www.erlang.org/doc/apps/crypto/crypto.html). Retaining an existing authenticated format removes dependency code with the CTR/PBKDF2 findings without inventing a cryptographic algorithm. OTP is the maintained platform already in use, with approximately 12,353 GitHub stars in the initial evidence; this introduces no small, unverified crypto package.

Implementation steps:

1. Replace `use Cloak.Vault` and `use Cloak.Ecto.Binary` in `lib/kith/vault.ex` with OTP-backed functions and an ordinary `Ecto.Type`. Keep `Kith.Vault.EncryptedBinary` as the schema-facing name to minimize churn. It must return `{:ok, binary}` only on successful authenticated decryption; OTP's `:error` sentinel must never become `{:ok, :error}`.
2. Preserve `cast/load/dump(nil)` and binary round trips. Reject malformed/truncated headers, unknown tags, wrong keys and authentication failures. Generate a fresh 16-byte IV on every write using `:crypto.strong_rand_bytes/1`. Validate the key at application boot in both web and worker mode. Do not log keys or plaintext.
3. Keep `CLOAK_KEY` and its secret-file loading behavior unchanged. Move the decoded key into application configuration that contains no Cloak module references. Remove the unnecessary Vault supervisor child after callers use the ordinary functions/type. Ensure the release explicitly starts the OTP crypto application through its application dependencies.
4. Cover both actual database columns: `accounts.immich_api_key` and `imports.api_key_encrypted`. Existing Monica crawl/misc/document/photo jobs load the latter when executing; queue payloads need no credential rewrite. Verify key release and cancellation still erase the encrypted value as before.
5. Leave `Kith.EncryptedBinary` alone. Its TOTP/OAuth fields use a different AAD, envelope and SECRET_KEY_BASE-derived key. Substituting that type directly for the Cloak-backed columns would make existing credentials unreadable.
6. Remove cloak_ecto from `mix.exs` and both packages from the lockfile. Replace the current boundary test that documents Cloak's sentinel behavior with successful binary round trips and explicit rejection tests.

No bulk data migration or new ciphertext version is required for this choice. A database backup plus the unchanged CLOAK_KEY remains required for normal deployment recovery. Take synthetic fixture ciphertext generated by the old package into regression tests before removing it. Validate new writes with the old implementation in a compatibility probe: rollback to the preceding app version must still read them. A later key rotation is a separate operation with its own migration plan.

### Decimal behavior checks

Decimal 3 changes default precision from 28 to 34 digits and bounds parsing/exponents. Version 3.2 also changes invalid rounding/NaN cases to raise `Decimal.Error`. Inspect `Kith.Types.BoundedDecimal`, gift/debt/payment schemas, debt totals, importer casts and all formatting call sites. Keep the application's stricter finite bounds. Test accepted maximum money values, exponent/digit rejections, negative/zero amounts, mixed payments, fixed-scale rounding and Postgrex persistence. Do not restore unbounded parsing to make old tests pass. See the [Decimal changelog](https://github.com/ericmj/decimal/blob/v3.2.0/CHANGELOG.md).

### Gate and acceptance

Delete the exception list, acceptance messages, owner/expiry machinery and `accepted_advisories` output from `scripts/security/dependency_audit.exs`. Preserve independent Hex/root-npm/assets-npm status recording and raw logs. Explicitly pass empty ignore variables to the Hex subprocess. A negative control using the old vulnerable lock must fail; the changed lock must pass with zero advisories and no ignored section. Both npm audits must still pass. Compile and test actual Kith, including OAuth callback identity, attribute-name rejection, TLS mismatch rejection, stored Immich credentials and continuing Monica jobs.

## Change 2 Upgrade framework and application APIs

Owner role: application maintainer. Depends on Change 1. Use separate reviewable commits for each group below, keeping all required checks blocking.

| Upgrade group | Kith work | Dependency-tree work | Acceptance |
| --- | --- | --- | --- |
| Flop 0.29.1 + Flop Phoenix 0.27.0 | In `contacts/contact.ex`, replace `@derive {Flop.Schema, ...}` with `use Flop.Schema` and `@flop_options`; keep the same filterable/sortable fields and limits. Update `flop_config.ex` documentation. Decide and encode stable tie ordering explicitly. | Flop Phoenix 0.27 requires Flop 0.29. The new schema behavior replaces the protocol; default primary-key tie-breaking affects query results even though public validate-and-run calls still exist. | Contacts with equal display names paginate deterministically without duplicates; tenant/search/archive/favorite/tag filters and max limit 100 remain enforced. Check invalid and saved query params. |
| Req 0.7.5 + ExAws 2.7.0 | Audit `BoundedHTTP`, Monica API/misc/photo/document paths, Immich, Weather and Geocoding. Kith sets `params:` and passes configurable URLs, so test URLs already carrying overlapping params. Preserve the 20 MiB streaming limit and disabled archive/decompression handling. | Req replaces step internals with Req.Finch/Req.Plug adapters; inspect unchanged Assent, ExAws and Tz consumers. Keep absent Hackney/JOSE adapters absent. ExAws's manifest, rather than a stale changelog summary, controls optional requirements. | Original credentials, pagination, redirects, query precedence, retry signing and error normalization work through actual fixtures. Req 0.7.3 reverted the GET-with-body method change from 0.7.0; verify the final 0.7.5 behavior, not only the major release notes. |
| LiveView 1.2.13 + Dashboard 0.9.1 + LiveReload 1.7.0 | Update direct constraints, vendored JS/client assets, components and form IDs. Audit global/rest attributes and editor/avatar hooks. | Current Phoenix 1.8.16 and target Dashboard support the new versions. Check optional LazyHTML/Jason integration, WebSock callbacks and native parser release contents. | Existing browser harness passes with no skips; uploads, reconnects, navigation, CSRF, editor paste/drop/save and image recovery still work. Fix new warnings rather than globally disabling them. |
| Sentry 14.0.1 | Keep custom `Kith.SentryReqClient`, `SentryFilter`, `before_send`, explicit LoggerHandler and final-attempt Oban reporting. Search found no removed enable_logs/enable_metrics settings to migrate. Define error-only telemetry categories explicitly if preserving current collection scope. | Custom HTTPClient callbacks remain present in the target. Sentry's optional Finch and LiveView edges are active; OpenTelemetry packages are absent and need not be added. Review majors 11–14 and prevent duplicate Oban capture. | Capture a terminal job error once, verify filters and redaction on the outbound envelope, exercise enabled and disabled DSNs, and verify flush/shutdown behavior and bounded buffering. Default data collection must not expand accidentally. |
| LoggerJSON 7.0.4 | Existing runtime tuple syntax is supported again from 7.0.1; move to `LoggerJSON.Formatters.Basic.new/1` during runtime setup for one-time configuration. | Check Jason/Decimal encoding and runtime availability during release migrations. Do not call dependency code from compile-time config. | Structured logs keep required fields and exclude credentials; app/worker/migrate processes all boot and emit parseable JSON. |
| Hammer 7.5.1 + Redix 1.10.0 | Introduce supervised named Hammer backend modules and a common `hit` wrapper. Update login/signup/API plugs and Monica host limiter. Preserve limits and explicitly define retry milliseconds versus HTTP seconds. | Remove Hammer 6 backend configuration and Poolboy. Add the separately packaged Redis backend only for the supported Redis deployment path; resolve and audit its exact release instead of assuming Redix alone supplies it. | Concurrent hits cannot exceed budget; denied hits recover; retry-after rounds up to seconds; ETS and real Redis modes work. The worker-mode Monica limiter starts even when no web endpoint starts. |
| Geolix 2.1.0 + adapter 0.7.0 | Existing API continues; verify configured and missing local DB paths and city/country/region normalization. | Adapter 0.7's floor is Elixir 1.9, met by pinned 1.19.5. It still retains mmdb2_decoder, so this upgrade does not satisfy its replacement item. | Local IPv4/IPv6 database lookups and absent/unknown-IP fallbacks pass. |
| Sobelow 0.18.1 | Update scanner and inspect `scripts/security/sobelow_check.exs` against the output. | New detection rules can expose findings; JSON/fingerprint compatibility is documented, but malformed-source and invocation failures are more explicit. | Actual scan succeeds, all findings addressed, scanner-failure negative control fails and logs remain archived. |

Primary references include [Flop's changelog](https://github.com/woylie/flop/blob/0.29.1/CHANGELOG.md), [Req's changelog](https://github.com/wojtekmach/req/blob/v0.7.5/CHANGELOG.md), [Sentry's target migration guide](https://github.com/getsentry/sentry-elixir/blob/14.0.1/pages/upgrade-14.x.md), [LoggerJSON 7.0.1 compatibility notes](https://github.com/Nebo15/logger_json/releases/tag/7.0.1), and [Hammer's migration guide](https://github.com/ExHammer/hammer/blob/master/guides/upgrade-v7.md). The downloaded target packages also supply changelogs and manifests; their file hashes are recorded in the evidence.

Finish compatible smaller updates from the inventory: CBOR, Credo, Dialyxir, ExMachina, IDNA, CLDR utilities/data, esbuild, Tailwind, Sleeplocks and Tz. Source diffs compensate for missing packaged changelogs: CBOR 1.0.2 converts an additional CaseClauseError to a decode error; Dialyxir 1.4.8 adds warning classes and line/column handling; Sleeplocks 1.1.4 changes owner-death handoff, monitor flushing and repeat acquisition. Verify malformed WebAuthn/COSE handling, the real Dialyzer gate and concurrent cache fills respectively. IDNA 7.1 removes unicode_util_compat and changes international-domain handling underneath SMTP. Tz changes timezone data and period-boundary behavior relevant to reminder dispatch. Tailwind/esbuild wrapper updates do not automatically establish the version of their downloaded binaries. Record each changed node, including unchanged parents, in the compatibility ledger.

## Change 3 Replace the Cachex closure

Owner role: application maintainer. Select **Nebulex 3.1.0 plus nebulex_local 3.1.0**, subject to the shared NimbleOptions blocker below. The initial evidence records 1,405 stars and original user endorsements for Nebulex; both chosen packages released on 18 October 2026. Avoid optional decorator/shards/ex2ms dependencies when Kith does not use those features.

Replace all direct Cachex usages in `cache.ex`, `application.ex`, `geocoding.ex`, `weather.ex`, `ip_geolocation.ex`, `storage.ex` and `duplicate_detection.ex`, plus test setup/callers. Route them through `Kith.Cache`, returning a single documented hit/miss/error contract. Do not expose Cachex-specific `{:commit, value}` tuples in application logic.

Preserve TTLs: default and geocoding 24 hours, Weather/IP geolocation one hour, storage usage and duplicate counts five minutes. Reads must not extend TTL. Preserve per-account key isolation, delete-on-write invalidation and duplicate-count fallback when the cache is unavailable. Verify concurrent cache fills do not overwrite a newer invalidation; choose locking or generation checks for expensive fills. Exercise app and worker modes and cache-process restarts. Cache contents are disposable, so rollout needs no database migration.

Acceptance: Cachex, Eternal, Jumper, Unsafe, ExHashRing and Sleeplocks are absent from the final graph, no source references remain, and existing duplicate/storage behavior plus TTL/concurrency checks pass. Removing ExHashRing rather than upgrading it resolves its parent-version conflict by eliminating the unused capability. Nebulex's own required NimbleOptions remains visible and must not be represented as a fully clean maintenance result.

## Change 4 Replace forwarded IP parsing safely

Owner role: application and deployment maintainers. Select existing **Plug 1.20.3 / Plug.RewriteOn**, removing RemoteIp and Combine.

The source reads the first forwarded address without RemoteIp's proxy-chain algorithm. Therefore deployment must supply one authoritative address. In the current single-Caddy deployment, overwrite a dedicated upstream header with Caddy's connection peer IP, e.g. `header_up X-Kith-Client-IP {remote_host}`, and read only that header. If there is an additional ingress/CDN, derive the address through Caddy's explicitly trusted-proxy configuration before setting it; never accept an arbitrary incoming header chain.

Gate rewriting on the actual socket peer matching an explicit ingress allowlist. Docker's current broad `172.16.0.0/12` default includes unrelated containers and is not an identity boundary. Give Caddy a controlled ingress network/address or an equivalent enforced network policy. App port 4000 remains private. Outside that configured ingress, preserve the actual socket IP and ignore the forwarded header. Update `TRUSTED_PROXIES` handling instead of leaving an unused RemoteIp configuration.

Acceptance: forged X-Forwarded-For and X-Kith-Client-IP from external clients and direct untrusted peers cannot change rate-limit/audit identity; valid IPv4/IPv6 through Caddy works; a malformed header does not crash; login/signup throttling and request audit logs use the same verified client IP. See [Caddy header controls](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) and [Plug.RewriteOn's source](https://github.com/elixir-plug/plug/blob/v1.20.3/lib/plug/rewrite_on.ex).

## Changes requiring upstream releases or architecture decisions

These items have concrete next deliverables and blocking conditions. They are not permission to ignore a CVE or to claim policy compliance. No messages, issues or PRs have been sent to upstream maintainers as part of this research.

Service choices below specify the architecture that could meet the release-age and popularity requirements; they are not claims that services are drop-in Hex packages. Before adoption, attach original adopter feedback that supports the requested community-praise criterion, not only project marketing or GitHub stars. Where that evidence is missing, replacement selection remains incomplete. Do not introduce a new service merely to make the dependency count smaller.

| Item | Required work | Exit condition |
| --- | --- | --- |
| DigitalToken 2.1.0 | Prepare a Calendars patch extending the 2.4.4 requirement to support DigitalToken 2; test token/calendar/number formatting across both versions. Do not just edit the root version. | A reviewed upstream release accepts 2.x and Kith resolves Calendars latest + DigitalToken latest together. Until then DigitalToken 1.0.0 is an explicit unfinished latest-version item. |
| Peep 5.0.1 and stale Prometheus core | Prepare PromEx compatibility work for Peep 5 plus a Peep-only distribution that does not require telemetry_metrics_prometheus_core. Current `storage_adapter: PromEx.Storage.Peep` only selects runtime behavior; the core package remains a required dependency. Check metrics plugin histogram/bucket conversion and dashboard behavior. | Released maintained parent graph supports Peep 5 and omits the stale core. Preserve `/metrics` authentication, disabled-exporter 503, metric names/labels/types/buckets and all five Application/BEAM/Phoenix/Ecto/Oban dashboards. If upstream does not release, this remains blocked; replacing it with standalone Peep would trade a higher-star parent for a 105-star library and require owned plugin/dashboard code. |
| NimbleOptions | Current parents include Finch, Flop, Peep, Redix and Sentry; selected Nebulex adds another parent. Prepare a compatibility request/patch for a maintained upstream release with supported Elixir/OTP CI, or plan coordinated parent changes. | A genuine maintained release inside the age threshold, or complete graph removal. A fork/version bump merely to reset the date is not an accepted maintenance fix. |
| NimblePool | Finch owns this dependency; Req, Swoosh, Sentry and PromEx consume Finch. | Maintained upstream release or tested parent transport migration. Removing only Kith's direct Finch declaration is insufficient. |
| WebSock | Both Bandit and WebSockAdapter require the interface. | Framework-supported maintained release or a compatible replacement used by both parents, with full LiveView/WebSocket verification. Changing only the HTTP server does not close it. |
| ASN1 compiler | Wax 0.7.0 requires asn1_compiler 0.1.1 for builds. Prepare an upstream Wax build change using OTP ASN.1 compilation and verify clean native/BEAM release builds and WebAuthn attestation formats. | Released Wax graph removes the stale helper, with real registration and signed assertion tests. No auth-service migration is required merely to replace a build helper. |
| Bunt | Credo 1.7.19 still requires it. Prepare an upstream switch to maintained ANSI formatting while retaining machine-readable and terminal output. | Released Credo graph removes/replaces Bunt or Bunt issues a maintained release. Keep Credo's analysis checks. |
| MMDB2 decoder | Locus 2.3.17 removes the old decoder but has only 122 stars. No high-star, recent-release, in-process equivalent was established. | Keep replacement selection blocked under the user's criteria. A Locus integration is technically specified below but must not be silently marked as satisfying popularity requirements. |
| POT | NimbleTOTP is ineligible on age; Totally 2.0.0 is recent but a small Gleam library with new runtime dependencies and no established high-star evidence. | Select **OpenBao 2.7.2 TOTP** if a qualifying maintained service is required; complete the service migration below before deleting POT. Keep this separate from urgent CVE closure. |
| Fuse | Three recent wrappers retain Fuse; no qualifying native replacement was established. | Select **Envoy 1.40.2** only as an explicit egress architecture migration, with the behavior contract below. Do not install Envoy and claim Fuse semantics are reproduced. |

### GeoIP integration if a qualifying package becomes available

Locus 2.3.17 accepts the local path directly: `:locus.start_loader(:city, path)`. For supervised startup use `:locus.loader_child_spec(:city, path)`; do not invent a `{:local, path}` source tuple. The [release source](https://github.com/g-andrade/locus/blob/2.3.17/src/locus.erl) accepts binary or string paths and internally normalizes them to a filesystem source. Lookup returns `{:ok, map}`, `:not_found` or `{:error, reason}` with binary map keys. Normalize these to Kith's existing `%{city, country, region}` shape and preserve one-hour cache and absent-DB behavior. Test reload atomicity and corrupt-file handling before selection. This technical candidate remains disqualified by the unfulfilled popularity criterion.

### POT migration to a maintained service

OpenBao's initial evidence records 8,806 stars and release 2.7.2 on 26 October 2026. Its [TOTP secrets engine](https://openbao.org/docs/secrets/totp/) can import enrollment material and validate user codes. It is a separate operated service, not a Hex dependency replacement with the same availability characteristics.

Replace secret-only validation with `Accounts.verify_totp(user, code)`, updating both `user_session_controller.ex` and `api/auth_controller.ex`; add a persisted provider/key reference to the user so validation does not require passing secret material. Move enrollment/disable operations through the same provider boundary. Define a stable server-generated key name per user; never trust a client-supplied OpenBao key identifier. Import existing secrets without logging them, verify RFC 6238 vectors and the intended six-digit/30-second window, then switch validation per migrated user. Keep recovery codes governed by the existing database transaction. Explicitly handle service timeouts as verification failures, never bypass MFA, and verify that code reuse and concurrent requests cannot evade replay policy. Preserve backup/restore and operator recovery before removing local secrets. Use an outbox/reconciliation operation for provider provisioning/deletion so a database rollback cannot silently leave an enabled user without the corresponding key.

Before committing to the service, audit its exact release and container digest, authentication, TLS, least-privilege token policy, HA/unseal procedure, account deletion and startup dependencies. Do not put synchronous network I/O inside Ecto `dump/load`. The important change is that an MFA login now depends on the service; tests and operations must cover its outage. Ory Kratos is unnecessary for this narrower capability and is not selected.

### Fuse migration to a maintained egress proxy

Envoy's initial evidence records 29,159 stars, release 1.40.2 on 27 October 2026 and published production adopters. Its [resource circuit breakers](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking) are different from [outlier ejection](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier); failure isolation needs the latter too.

Introduce fixed egress routes for LocationIQ and OpenWeather only, preserving upstream HTTPS verification/SNI and preventing a generic open proxy. Route both app and worker callers consistently. Configure at most one retry layer. Limit concurrent/pending work and propagate retry/error outcomes to the current Kith result tuples. With single-host clusters, explicitly disable panic-mode routing to ejected hosts and allow full ejection; otherwise a supposedly open circuit can keep sending requests.

Specify policy before removing Fuse: current Geocoding installs threshold 5 with 60-second failure/reset windows; Weather uses threshold 3 with five-minute windows. Both melt on 429/timeout/network errors and reset on successful calls. Default Envoy outlier handling treats 5xx as failures and does not count 429, so it does not match. Require custom HTTP failure mapping and deterministic fixtures for 429, 5xx, timeout, reset, recovery and concurrent calls. Any deliberate difference in the counting/reset model must be documented as a behavior change. Preserve cached-result fallback. Removing Fuse is blocked until this contract and service rollout pass, not merely until an Envoy image starts.

## Release and acceptance sequence

1. Implement and verify Change 1 first. It has a reproducible advisory-free graph and exact ciphertext compatibility. All four ignored advisory IDs disappear; no downgrade of the security gate is allowed.
2. Implement Change 2 in groups, checking Kith behavior and whole-tree changes after each resolution. Do not describe the latest-direct probe as the final all-latest graph.
3. Implement Changes 3 and 4 with cache/proxy tests. Review their graph removals rather than counting a direct dependency deletion alone.
4. Complete upstream work and the separately scoped replacements. Preserve the unresolved status for any package whose current available releases cannot meet the requested constraints. A deadline cannot create an upstream release; no fabricated dates or promise of full closure is part of this plan.
5. Rebuild with fresh dependencies and compile caches on the supported Linux/musl target. Run `mix quality`, full ExUnit and `npm run test:js`; run the complete `npm run test:pr44` browser suite with no skips. Exercise app/worker/migration modes and preserve Oban schema 12→14 rollback guarantees. Use the documented fixtures and isolated database.
6. Run unfiltered Hex and both npm audits, inspect retired packages, verify all installed constraints, and evaluate every remaining package's most recent release date. Review any new optional adapter or service image introduced by replacements. Archive the final graph, audit logs and behavior evidence.
7. Update the original audit documentation and PR description to state only checks actually run on the final head. Completion means zero CVEs, zero ignored advisories, all retained dependencies at mutually compatible latest releases and no unresolved maintenance-policy packages. Until that is true, the report remains open even if the CVE milestone has shipped.

This turn produces the plan and research evidence only. Kith application code, dependency locks, CI configuration and remote PR content are unchanged.

## Implementation and verification, 1 November 2026

**The zero-CVE application change is implemented and verified. The complete latest-version and maintenance policy remains unfinished.** The research statements above describe the original baseline; they are retained as historical evidence, not current findings. Final machine-readable checks are in [pr44-implementation-evidence](pr44-implementation-evidence/).

The initial local branch and PR head both matched `3ac2faba0012b461b573f03c739d4abeac097511`. Only the four supplied research documents were untracked. No applicable AGENTS.md was present. No unrelated edits, merge or deployment were performed. Implementation and independent-review subagents handled bounded source areas; the coordinator serialized manifests/locks and ran integrated acceptance checks.

Implemented changes:

- Removed all four advisory exceptions and their acceptance path. Every Hex advisory/retirement and either npm audit failure blocks. The gate overwrites both inherited Hex ignore variables with empty values, runs all three audits even after a failure, and retains raw outcomes. Six subprocess tests cover each individual failure, simultaneous failures, invocation failure and inherited suppression. The vulnerable baseline lock is an actual seven-advisory negative control; both npm audits still run.
- Replaced Cloak/Cloak Ecto with an ordinary Ecto binary type backed by OTP AES-256-GCM. It preserves decoded `CLOAK_KEY`, the exact `<<1,10,"AES.GCM.V1",iv::binary-size(16),mac::binary-size(16),ciphertext::binary>>` envelope and `AES256GCM` AAD. Legacy/new ciphertext interoperability, both persisted credential columns and queued-job key retention/release are tested. `Kith.EncryptedBinary` remains a different format.
- Upgraded compatible framework/API roots and their resolved children. Migrated Flop schema options and deterministic filtered pagination, Req authorization/query/stream/redirect behavior, Hammer supervised ETS/Redis backends and retry units, Sentry error-only collection/redaction and LoggerJSON formatting. Updated LiveView forms/client assets, GeoIP record normalization, Decimal money boundaries and Sobelow-reviewed rendering boundaries. Actual OAuth/TLS, signed S3 retry, provider, metrics/dashboard, editor and import fixtures exercise retained consumers.
- Replaced Cachex's entire helper closure with Nebulex/Local. Explicit millisecond TTLs now enforce intended expiry; the previous Cachex `ttl:` options were ineffective, so this is an intentional correction. Per-key locking and backend identity tags protect fills/promotions/restarts. DB-derived reads bypass caches in transactions, and current enclosing commit owners invalidate afterward, including merge, purge, CardDAV and media writes. Connected nodes receive acknowledged invalidation; disconnected/unreachable nodes can retain entries until bounded TTL. Future enclosing transactions must own their after-commit invalidation.
- Removed RemoteIp/Combine in favor of exact ingress identities and a Caddy-overwritten canonical header. The app port stays private; the dedicated ingress trusts only Caddy's `/32`. HTTP, LiveView signup, rate limits and request logs share verified transport identity. Login/signup helpers previously were unused: enforcing the existing 10/minute and 5/minute policies is a deliberate behavior change. Actual Caddy tests found and fixed invalid upstream HTTP-version configuration and WebSocket fallback. Both access/error logs omit query strings and header payloads.
- Removed stale `tailwindcss-animate` from both npm graphs. Existing Tailwind native CSS preserves flash/selection motions and transition durations. The browser fixture now regenerates compressed assets before boot: a stale `.gz` file initially hid the changed stylesheet, and the new real-motion assertion detected it.

Verified final application checks:

| Check | Actual result |
| --- | --- |
| Complete Hex lock/active optional edges/runtime floors | 98 packages, 197 installed edges; zero constraint/floor failures |
| Unfiltered audit gate with inherited suppression sentinels | Hex: zero advisories/retirements; root npm: zero; assets npm: zero |
| Final ExUnit, including `slow` and `external` | 1,970 tests, zero failures; no tag exclusions/skips |
| `mix quality` | Passed compile, format, strict Credo, source-bound Sobelow and Dialyzer; only two pre-existing generated CLDR type warnings remain in the existing Dialyzer rule |
| JavaScript / browser | 14 JS tests and 21 mandatory browser tests passed, zero skips |
| Real Redis backend | Four tests passed against Redis 7, including shared budgets and unavailable-backend behavior |
| Cold production build | `docker build --no-cache`, Linux/arm64 musl, pinned Elixir 1.19.5 / OTP 28.5.0.5; passed |
| Final production image | App/worker/migrate boot, missing/invalid key rejection, four DSN modes, metrics auth/assets, legacy/new credentials and continuing job lifecycle passed |
| Oban preservation | Migration/rollback 12→14→12→14 retained jobs and constraints |
| Connected production nodes | Cache TTLs and symmetric invalidation; worker media/duplicate mutations invalidate web reads |
| Actual Caddy / Chromium | IPv4/IPv6, untrusted/malformed/forged headers; WebSocket 101; signup sixth attempt blocked, login eleventh blocked, API twenty-first blocked; access and actual 502 error redaction passed |

The final image ID, measured reports, raw selected logs and checksums are recorded in `pr44-implementation-evidence/validation.json`. Remote CI was not rerun and no claim is made about a new hosted CI result. Tests use synthetic credentials and local provider fixtures; live provider accounts, Linux/amd64, older runtime matrices and embedded standalone-tool Rust/Go dependency inventories are not claimed as verified.

### Remaining blockers and concrete upstream work

Exactly two installed Hex packages remain below latest: **DigitalToken 1.0.0** (Calendars 2.4.4 rejects 2.1.0) and **Peep 4.4.0** (PromEx 1.12.0 rejects 5.0.1). Calendars was not silently downgraded; no transitive override or fork was adopted.

Nine Hex packages still violate the two-year rule: **asn1_compiler, Bunt, Fuse, mmdb2_decoder, NimbleOptions, NimblePool, POT, telemetry_metrics_prometheus_core and WebSock**. Both npm graphs also retain **@types/trusted-types 2.0.7**, required by DOMPurify's published declarations. Types-only/optional status does not exempt it. All other installed npm packages are current stable releases; installed constraints pass in both graphs.

Concrete unreleased work is retained in [pr44-upstream](pr44-upstream/): Calendars DigitalToken 1/2 compatibility; PromEx Peep 5 plus optional Core; Wax OTP ASN.1 compiler replacement, including partial-failure restoration; and Credo native ANSI output. Isolated probes test the changed parent closure and preserve original/candidate parity. Independent review found real probe/compiler defects, which were corrected and retested. These artifacts are not published releases and do not establish full Kith adoption or every upstream runtime/device matrix. NimbleOptions, NimblePool, WebSock and declaration maintenance requests are drafted with actual parent lists and acceptance contracts; no message/issue/PR was sent upstream.

MMDB2/POT/Fuse replacement selection or architecture gates remain unmet. Locus and Totally do not establish the required popularity/adopter case; NimbleTOTP and ConCache fail release age; Fuse wrappers retain Fuse. OpenBao and Envoy remain unapproved service migrations with the original adoption gates. POT's current/future-window behavior was not changed. No authentication or infrastructure rewrite was introduced to reduce package count.

A clean audit, successful resolver, candidate patch or green local build does **not** close those blockers. Full plan completion requires genuine compatible maintained releases or qualifying implemented replacements and their complete application/release verification.

## Policy revision: latest compatible and maintained older packages

The user subsequently selected **“Allow latest compatible releases and older maintained packages without forcing replacements.”** This replaces the original absolute-latest and two-year replacement requirements. Original research, release dates, probe failures and strict-policy assessments above remain historical evidence; they are not rewritten as successful absolute-latest upgrades.

The current requirements are:

- No CVE or retirement exception, inherited advisory suppression, incompatible constraint override, or weakened audit failure handling.
- Use the latest compatible stable dependency graph, preserving current parent releases when a newer child requires an incompatible manifest. Calendars **2.4.4 + DigitalToken 1.0.0** and PromEx **1.12.0 + Peep 4.4.0** therefore satisfy this requirement. The corresponding all-latest conflicts remain recorded facts, but no longer block acceptance. No fork or parent downgrade is needed.
- A release older than two years triggers a maintenance review, not mandatory replacement. Review actual support/repository status, package scope and source, current parent integration and tested compatibility. Release age alone establishes neither abandonment nor maintenance. Explicit archival/deprecation, unknown support and limited activity must be reported accurately; a parent retaining a package alone does not prove its upstream is maintained.
- Retain the existing verified application where those reviews support retention. New infrastructure, unpublished forks, authentication changes and replacements selected only to satisfy age/popularity are unnecessary under this policy. Existing replacement/adoption criteria still govern any replacement that is actually proposed.
- Keep compatible-version and maintenance decisions separate from advisory handling. The strict gate remains unchanged, with both Hex ignore variables explicitly empty for the audit subprocess and both npm audits blocking.

Current package-by-package maintenance evidence is recorded in [maintenance-review.json](pr44-implementation-evidence/maintenance-review.json); the policy decision and fresh audit/graph references are recorded in [policy-review.json](pr44-implementation-evidence/policy-review.json). The earlier `validation.json` and test logs continue to describe the same application/lock snapshot. Documentation-only policy changes do not constitute a new application test run or upstream release.

Unreleased Calendars/PromEx/Wax/Credo candidate patches remain available for optional future contributions. They are not adopted or required merely to satisfy the revised policy; no upstream communications, push, merge or deployment are authorized by this policy change.

### Results under the revised policy

Both latest-compatible selections are accepted. Maintenance evidence supports retaining **mmdb2_decoder, NimbleOptions, NimblePool, telemetry_metrics_prometheus_core, WebSock and @types/trusted-types**. Prometheus Core remains on a release/support responsiveness watchlist; its merged code fix and project ownership provide maintenance evidence despite the old release date.

**ASN1 Compiler, Bunt, Fuse and POT remain maintenance followups.** Their upstream maintenance support is unconfirmed by the reviewed evidence. They are not asserted abandoned, vulnerable or incompatible, and release age alone does not force their replacement. Conversely, absence of archival/deprecation does not justify calling them confirmed maintained. Full maintenance-policy closure is not claimed while these four statuses remain unresolved.

Fresh strict Hex/root-npm/assets-npm audits pass and the graph remains **98 Hex packages / 197 installed edges**, with zero installed-constraint or runtime-floor failures. Application code, dependency manifests/locks, audit gate, build configuration and tests exactly match the earlier verified source fingerprints. The full application/release suites were not needlessly rerun for this documentation-only policy revision. No dependency override, fork or infrastructure/authentication migration was introduced.

## Retention decisions and POT integration fixes

Following the user's preference for a minor ASN fork only when justified, **retain ASN1 Compiler 0.1.1**. The prepared Wax alternative introduces an owned compiler lifecycle, caching, partial-failure recovery and packaging code. No demonstrated Kith CVE or current build/compatibility failure justifies that extra ownership. The current helper passes the new cold Linux/arm64 musl build and complete application tests. No fork was created; upstream maintenance remains unconfirmed.

**Retain POT 1.0.2 with reviewed Kith boundaries.** Independent RFC 4226/6238 SHA1/SHA256/SHA512 vectors, time boundaries, existing Base32 secret/encryption compatibility and the exact configured window agree. This establishes tested algorithm/integration behavior, not an upstream maintenance commitment or full MFA security certification. Bunt and Fuse remain at their existing versions as discussed; no Credo fork or egress service was introduced.

The bounded POT review reproduced and fixed three application integration defects:

1. Non-binary OTP/recovery values and malformed/empty secrets could raise request errors. Kith now rejects them before authentication; compatible padded/lowercase Base32 secrets still work.
2. A valid five-minute browser challenge allowed repeated second-factor guesses without a budget. Browser verification now has a separate **10 attempts/minute per verified IP**, and browser/API verification share **10 attempts/minute per user** after first-factor proof. Existing password-login and API-IP rules remain separate. Denials return 429 and a rounded-up Retry-After; backend failures do not authorize a session/token.
3. Both TOTP/recovery form inputs were enabled, required and shared an ID. Actual Chromium OTP submission posted a valid code plus an empty duplicate; recovery's hidden OTP field failed native form validation. The inactive input is now disabled and recovery has a distinct ID. Real OTP login succeeds; recovery submits one code, consumes exactly one recovery record and rejects subsequent reuse.

The configured **current and next two 30-second intervals** remain unchanged. The old “previous period” documentation was corrected. Stateless TOTP/signed-challenge reuse remains unchanged; no accepted-counter persistence or replay protection was added. POT's binary comparisons are not claimed constant-time. These are explicit existing characteristics, not a claim of complete RFC deployment/security compliance. OTP auto-submit retains native `form.submit()` and JS digit checks, so it bypasses native HTML constraint validation; recovery's native validity is exercised. Successful CSRF-protected submission is verified, without claiming a new invalid-CSRF negative test.

Baseline regressions were observed before fixing: **15 targeted tests / six failures**, duplicate OTP POST values in Chromium, and an invalid recovery form despite a valid visible recovery code. Final checks pass:

- **1,986 ExUnit tests**, including all slow/external tests and 16 new review regressions; zero failures/skips.
- **23 mandatory browser tests**, including both real TOTP flows; **14 JavaScript tests** and **five real Redis tests**; zero failures/skips.
- `mix quality`, strict Hex/root-npm/assets-npm audits and the complete **98-node / 197-edge** Hex constraint/floor check.
- A new **cold Linux/arm64 musl production build**, app/worker/migration modes, new OTP/guard/budget probes in actual web/worker processes, existing Oban 12→14→12→14 rollback, credential/cache/metrics/assets checks, and actual Caddy/WebSocket/identity/redaction checks.

Package versions and `mix.lock` are unchanged. The current implementation, image ID, source fingerprints, measured outputs, prior failure controls and limitations are in [pot-reviewed-validation.json](pr44-implementation-evidence/pot-reviewed-validation.json), with detailed [POT review](pr44-implementation-evidence/pot-security-review.json). Earlier validation and policy-only “unchanged source” statements apply to their historical snapshots; this new report covers the application changes above. Upstream maintenance uncertainty remains recorded, without labeling retained packages actively maintained or silently claiming the original all-latest/two-year policy is met. Nothing was pushed, merged or deployed.
