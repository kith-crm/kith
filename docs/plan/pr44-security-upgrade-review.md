# PR44 dependency security and upgrade review

> Current policy: the user permits latest compatible releases and maintained older packages. See the [policy revision](#policy-revision-latest-compatible-and-maintained-older-packages). Original strict-policy blockers and research below are historical; the verified application and audit requirements remain unchanged.

Reviewed on 1 November 2026 against [PR 44](https://github.com/kith-crm/kith/pull/44), commit `3ac2faba0012b461b573f03c739d4abeac097511`.

**Recommendation: request changes.** The resolved Hex graph contains seven CVEs across six packages: two critical, one high and four medium. CI deliberately ignores four of them. Under the requested policy, all seven must be resolved by patched versions or removal of the affected packages. Existing application mitigations explain exposure but do not close these findings.

Of 107 Hex packages, 38 have a newer stable release and 17 have no stable release in the past two years. Those are overlapping measurements, not additive totals. The separate Git dependency, Heroicons, is already at its latest release, v2.2.0. Both fresh npm audits report zero vulnerabilities; this report's version inventory covers Mix dependencies, not a complete npm upgrade review.

## Research followup

The [implementation plan](pr44-dependency-remediation-plan.md) supersedes the provisional migration choices below. Isolated resolver probes establish three latest-version conflicts, including **Calendars 2.4.4 versus DigitalToken 2.1.0**, which the initial review missed. The security target retains DigitalToken 1.0.0 with Calendars 2.4.4. A verified OTP implementation can preserve the configured Cloak GCM format and key, so **bulk re-encryption is not required**. The plan records Kith call sites, complete dependency edges, concrete migrations and remaining upstream release blockers.

## Review findings

1. **High priority — the security gate explicitly suppresses four CVEs.** `scripts/security/dependency_audit.exs:3–10` lists the two Cloak and two Decimal advisories and passes them into `HEX_IGNORE_ADVISORIES` at lines 31–37. Owner `kith-crm maintainers` and expiry 29 November 2026 make these documented exceptions, not fixes. Delete the exceptions and their acceptance path. Run the audit with both ignore environment variables explicitly empty so inherited environment settings cannot suppress findings. CI must remain failing until remediation is complete.
2. **High priority — three additional CVEs are already failing hosted CI.** The [current run](https://github.com/kith-crm/kith/actions/runs/41247629224/job/124674260911) fails on Assent, Phoenix.HTML and ssl_verify_fun. Earlier passing runs in the PR body describe older advisory data; they do not establish current security. The local unfiltered audit reproduces all seven findings.
3. **High priority — retaining Decimal 2 is no longer necessary on the basis stated in the PR.** The locked CLDR parents reject Decimal 3, but their current releases accept it. Update the complete parent group and use Decimal 3.2.0. Ecto SQL 3.14.0 itself requires Decimal 3. A forced dependency override is unnecessary.
4. **High priority — Cloak and Cloak Ecto have no published fix and cross the replacement threshold.** Both last released on 6 April 2024. Merely selecting their latest versions leaves both advisories present. Plan and complete a format-compatible replacement; do not rename the exceptions or treat unused vulnerable features as CVE closure.
5. **Maintenance policy affects the complete graph.** Several stale packages are required by current Phoenix, Finch, Cachex, Credo and PromEx releases. Upgrading direct packages alone cannot meet a strict two-year release policy. The replacement backlog below identifies these cases explicitly.

## CVEs and required remediation

Severity labels below are those returned by `mix hex.audit`. Each CVE links to its Erlang Ecosystem Foundation advisory, which supplies the affected version range. Conditions describe the vulnerable feature and observed Kith usage, not a claim that a working exploit against Kith was demonstrated.

| CVE | Severity | Installed package | Affected releases | First fixed release | Required target and CI status |
| --- | --- | --- | --- | --- | --- |
| [CVE-2026-117666](https://cna.erlef.org/cves/CVE-2026-117666.html) / GHSA-7gw2-hphm-c5px | Critical | ssl_verify_fun 1.1.7 | >=1.0.1, <1.1.8 | 1.1.8 | Upgrade to **1.1.9**; currently blocks CI |
| [CVE-2026-117656](https://cna.erlef.org/cves/CVE-2026-117656.html) / GHSA-9fr5-g44g-9526 | Critical | assent 0.3.1 | >=0.1.25, <0.3.2 | 0.3.2 | Upgrade to **0.3.2**; currently blocks CI |
| [CVE-2026-95105](https://cna.erlef.org/cves/CVE-2026-95105.html) | High | cloak 1.1.4 | All published releases, from 0.1.0-pre | None published | **Replace and remove**; explicitly ignored in CI |
| [CVE-2026-117645](https://cna.erlef.org/cves/CVE-2026-117645.html) | Medium | phoenix_html 4.3.0 | >=1.0.0, <3.3.5; >=4.0.0, <4.4.0 | 3.3.5 / 4.4.0 | Upgrade to **4.4.0**; currently blocks CI |
| [CVE-2026-97853](https://cna.erlef.org/cves/CVE-2026-97853.html) / GHSA-6c27-994x-c52f | Medium | decimal 2.4.1 | >=0.1.0, <3.1.2 | 3.1.2 | Upgrade to **3.2.0** with CLDR/Ecto parents; explicitly ignored in CI |
| [CVE-2026-32686](https://cna.erlef.org/cves/CVE-2026-32686.html) / GHSA-rhv4-8758-jx7v | Medium | decimal 2.4.1 | >=0.1.0, <3.0.0 | 3.0.0 | Upgrade to **3.2.0**, which fixes both Decimal CVEs; explicitly ignored in CI |
| [CVE-2026-94206](https://cna.erlef.org/cves/CVE-2026-94206.html) | Medium | cloak_ecto 1.3.0 | cloak_ecto >=1.0.0-alpha.0; historical cloak >=0.7.0, <1.0.0-alpha.0 | None for cloak_ecto | **Replace and remove**; explicitly ignored in CI |

### TLS hostname verification

ssl_verify_fun accepts certain partial-label certificate wildcards across DNS label boundaries and can match wildcard DNS patterns to IP literals incorrectly. A certificate for the wrong host can therefore be accepted in affected calling modes. OTP's own hostname verification normally protects clients that retain SNI; the advisory identifies disabled SNI, direct hostname verifier calls and server-side client-certificate hostname checking as exposed cases. Kith's OTP 28 runtime does not justify suppressing the package advisory.

The locked parents are Assent's optional ssl_verify_fun integration and the required `prom_ex → octo_fetch → ssl_verify_fun` path. Their constraints permit 1.1.9. Upgrade the resolved package and exercise trusted/untrusted certificates, partial-label wildcards, IP literals, redirects and the actual HTTP client configurations. Keep certificate and hostname verification enabled.

### OAuth identity substitution

Assent's Apple strategy merges a browser-supplied, unsigned `user` object over verified ID token claims, permitting replacement of identity fields such as subject and email. Version 0.3.2 stops accepting that object by default; the optional name inclusion path preserves verified identity claims.

Kith currently exposes GitHub and Google strategies in `runtime.exs` and `oauth_controller.ex`; an Apple account takeover is not established against these configured routes. Nevertheless, upgrade Assent to 0.3.2. Verify provider identity mapping, account linking, state/PKCE and callback failure behavior. The existing `~> 0.2` requirement allows 0.3.2.

### HTML attribute injection

Phoenix.HTML escapes attribute values but older releases fail to validate attribute names. Attacker-controlled keys can inject event-handler attributes or break out of HTML markup, including through nested data/aria/phx attributes and HEEx attribute splats. Upgrade 4.3.0 to 4.4.0. Review dynamic attribute maps and ensure invalid names are rejected while ordinary component attributes still render. An HTML sanitizer for note content is a separate boundary and does not fix this renderer defect.

### Unauthenticated encryption in Cloak

Cloak's AES-CTR readers lack a MAC. An attacker able to modify stored ciphertext and predict plaintext can alter decrypted values through bit flipping. Kith configures AES-GCM, reducing exposure to this feature, but the published package remains affected and the advisory has no fixed version. Its ignored ID is `EEF-CVE-2026-95105`.

Replace `Kith.Vault` and `Kith.Vault.EncryptedBinary`. Compatibility verification must cover Immich keys and import credentials, including queued/retryable import jobs. The followup plan verifies an exact-format OTP replacement: retain the existing AES.GCM.V1 header, key and authenticated GCM format so existing rows and new writes remain readable in both versions. No bulk row rewrite is needed for that choice. Keep a verified backup and the unchanged key; schedule key rotation separately.

### Incorrect PBKDF2 work factor in Cloak Ecto

The field implementation supplies the configured output size where the PBKDF2 iteration count belongs: defaults produce 32 rounds rather than 600,000. An attacker with the stored hashes and configured secret can guess low-entropy values much faster than intended. Kith uses `pbkdf2_elixir` for password and recovery-code hashing and does not use Cloak's PBKDF2 fields; this is why the PR currently ignores `EEF-CVE-2026-94206`.

Remove cloak_ecto with the vault replacement. Bumping cloak alone cannot fix the advisory attached to cloak_ecto 1.3.0. If historical PBKDF2 fields exist outside current source, audit their stored values and rehash from verified source data; changing iteration configuration cannot repair existing hashes.

### Decimal resource exhaustion

CVE-2026-32686 allows small inputs with huge exponents to trigger excessive allocation during later arithmetic or formatting. Kith handles imported/user money and formats debt values, making those boundaries relevant. `Kith.Types.BoundedDecimal` limits input before parsing, but that mitigation does not patch Decimal.

CVE-2026-97853 separately allows a very large positive or negative rounding scale to consume excessive memory. Kith's observed `Decimal.round(2)` call uses a fixed scale. Input exponent bounds do not generally protect the `places` parameter, so keep both protections after upgrading. Both ignored EEF IDs must be removed.

## Upgrade groups and dependency constraints

### Security updates that can proceed immediately

Update `assent`, `phoenix_html` and `ssl_verify_fun` together. Current requirements permit all three target versions. Verify a fresh lockfile with the three new advisories absent. These updates do not resolve the four ignored CVEs.

### Decimal and CLDR migration

Update the following group together. Followup solver validation corrected the DigitalToken target to preserve compatibility with Calendars 2.4.4:

| Package | Current | Target | Why it belongs in the group |
| --- | --- | --- | --- |
| decimal | 2.4.1 | 3.2.0 | Fix both CVEs |
| cldr_utils | 2.29.5 | 2.29.7 | Current lock accepts Decimal 1/2; target adds Decimal 3 |
| ex_cldr | 2.47.2 | 2.47.5 | Target adds Decimal 3 support |
| ex_cldr_numbers | 2.38.1 | 2.38.3 | Target adds Decimal 3 and DigitalToken 2 support |
| digital_token | 1.0.0 | Retain 1.0.0 initially | Latest Calendars 2.4.4 also requires 1.x; 2.1.0 needs a compatible Calendars release |
| ex_cldr_calendars | 2.4.2 | 2.4.4 | Refresh CLDR closure and calendar behavior |
| ex_cldr_currencies | 2.17.1 | 2.17.2 | Refresh currency metadata and formatting |
| ecto | 3.13.6 | 3.14.2 | Old ecto_sql requires Ecto 3.13.x |
| ecto_sql | 3.13.5 | 3.14.0 | Target requires Ecto 3.14.x and Decimal 3 |

The target [CLDR](https://github.com/elixir-cldr/cldr/blob/v2.47.5/mix.exs), [CLDR Utils](https://github.com/elixir-cldr/cldr_utils/blob/v2.29.7/mix.exs) and [CLDR Numbers](https://github.com/elixir-cldr/cldr_numbers/blob/v2.38.3/mix.exs) manifests explicitly allow Decimal 3. Current Ecto, Postgrex and Jason already permit Decimal 3. Existing direct requirements permit the target CLDR/Ecto SQL releases.

Read Decimal's intervening major-version changes and validate parsing, bounded casts, debt/payment arithmetic, rounding, localized money output, import persistence and Postgrex round trips. Keep finite application limits even after the upstream fix. Regenerate locale code and rerun the cold production build.

### Framework and major API migrations

| Group | Planned changes | Required compatibility review |
| --- | --- | --- |
| LiveView | 1.1.33 → 1.2.13; widen `~> 1.1.0` to the reviewed 1.2 series | Server/client version alignment, vendored JS, hooks, navigation, uploads and actual browser scenarios |
| Dashboard | 0.8.7 → 0.9.1; widen `~> 0.8.3` | Authentication, routing, metrics and dashboard behavior |
| Req | 0.6.3 → 0.7.5; widen `~> 0.6.3` | Retry/timeout/error semantics, streaming, decompression/archive policy, response-size limits and OAuth/storage integrations |
| Hammer | 6.2.1 → 7.5.1; replace `~> 6.2` | Follow the [v7 migration guide](https://github.com/ExHammer/hammer/blob/master/guides/upgrade-v7.md). Replace old `Hammer.check_rate` and backend config, wire supervised backend modules and verify ETS/Redis behavior and retry-after units. Target removes the old Poolboy architecture. |
| LoggerJSON | 6.2.1 → 7.0.4; replace `~> 6.0` | Formatter configuration, field schema, metadata/redaction and log consumers |
| Sentry | 10.10.0 → 14.0.1; replace `~> 10.8` | Read majors 11–14, initialization, transport, logging integration, filtering and optional LiveView behavior |
| Flop | 0.26.3 → 0.29.1; widen `~> 0.26`; Flop Phoenix 0.26.0 → 0.27.0 | Paired dependency requirements, pagination/filter validation, saved query parameters, component options and sorting behavior |
| PromEx | 1.11.0 → 1.12.0 | Target's optional Ecto integration raises its floor to 3.14. Target still requires telemetry_metrics_prometheus_core 1.2.x and permits only Peep 3/4. |
| Peep | 3.5.0 → 5.0.1 desired | **Blocked even by latest PromEx 1.12.0.** Upstream parent support or an exporter migration is required; a forced override is not a reviewed solution. |
| ExHashRing | 6.0.4 → 7.0.0 desired | **Blocked by latest Cachex 4.1.1**, which requires 6.x. Replace the cache closure or obtain a compatible upstream release. |
| Sobelow | 0.14.1 → 0.18.1 | Compare scanner output/schema and source-specific exception matching; fail on scan errors and new findings |
| Asset wrappers | esbuild 0.10.0 → 0.10.1; tailwind 0.4.1 → 0.5.2 | Wrapper releases and downloaded binaries are separate versions. Rebuild minified assets and inspect browser behavior. |

These are upgrade plans and compatibility work items, not a claim that the target graph has been installed or tested. Before implementation, read intervening changelogs for every changed package, resolve the whole graph without overrides and record any new packages and their maintenance status.

## Replacement plans for packages without a release in two years

Cutoff: **1 November 2024**. Release dates below come from Hex release `inserted_at`, not repository push time or package metadata edits. Seventeen packages cross the cutoff. No release for two years is the requested replacement trigger; it does not by itself prove the project is abandoned. Developer-only and transitive packages remain included.

| Package and current version | Last stable release | Parent or use | Replacement plan and remaining constraint |
| --- | --- | --- | --- |
| asn1_compiler 0.1.1 | 2017-11-17 | wax_ WebAuthn | Ask Wax upstream to replace the build helper with maintained OTP ASN.1 tooling. If no release follows, evaluate managed/self-hosted WebAuthn through Ory Kratos; migrate credential IDs, public keys, counters, RP IDs and account links deliberately. No verified in-process replacement meeting all selection criteria. |
| bunt 1.0.0 | 2023-12-05 | Credo's terminal styling | Upstream Credo must remove/replace the formatter helper, or the project must adopt another maintained analyzer after mapping current rules. Do not silently drop Credo checks. Latest Credo is not sufficient evidence of removal. |
| cloak 1.1.4 | 2024-04-06 | Vault encryption | Replace with OpenBao Transit or a carefully scoped Ecto type using maintained Plug.Crypto/OTP authenticated encryption. Preserve the existing authenticated byte format; see followup plan. |
| cloak_ecto 1.3.0 | 2024-04-06 | Encrypted Ecto fields | Remove alongside cloak. Preserve null/binary handling, key versions, import retries and all existing credential rows. |
| combine 0.10.0 | 2017-08-09 | remote_ip header parsing | Remove with remote_ip; use maintained Plug.RewriteOn only behind a trusted proxy that strips incoming forwarded headers and writes canonical values. |
| eternal 1.2.2 | 2020-12-02 | Cachex ETS lifecycle | Replace Cachex closure with Nebulex 3.1.0 and a maintained adapter, or use existing Redis through Redix where suitable. Audit the entire replacement graph first. |
| fuse 2.5.0 | 2021-07-01 | Weather/geocoding circuit breakers | Evaluate Envoy 1.40.2 for outbound resource limits plus outlier detection. It is an infrastructure migration and does not reproduce Fuse's error-counting behavior automatically. Preserve circuit-open/fallback behavior and test outages. |
| jumper 1.0.2 | 2023-08-30 | Cachex | Remove with Cachex closure. |
| mmdb2_decoder 3.0.1 | 2022-06-20 | Geolix adapter | Evaluate Locus 2.3.17, which parses MaxMind DB independently. It is maintained but has only 122 stars, so it does not satisfy a strong high-star requirement; selection remains open. Preserve local DB mode, IPv4/IPv6, unknown-IP behavior and country/city output. |
| nimble_options 1.1.1 | 2024-05-25 | Multiple parents including Redix, Sentry, NimblePool and Peep | Request a supported release or parent migration. This shared validation dependency cannot be replaced by adding a different root package. Nebulex also depends on it, so Nebulex alone cannot satisfy the full policy. No verified replacement satisfying all criteria. |
| nimble_pool 1.1.0 | 2024-03-25 | Finch pooling | Upstream Finch release must replace/remove it or a transport migration must replace every Finch-using parent. Req and several integrations also use Finch. Do not replace the root Finch declaration while leaving the transitive package. No verified equivalent meeting all criteria. |
| poolboy 1.5.2 | 2019-01-22 | Hammer 6 | Upgrade Hammer to 7.5.1 and migrate its API/backends. Verify Poolboy disappears from the final graph. |
| pot 1.0.2 | 2021-08-07 | TOTP verification | Evaluate OpenBao TOTP 2.7.2, or Ory Kratos 26.2.0 for a broader identity migration. Preserve enrollment secrets, drift window, replay protection, recovery codes and outage behavior. NimbleTOTP 1.0.0 last released in March 2023 and is ineligible under this policy. |
| remote_ip 1.2.0 | 2024-06-10 | Endpoint client IP extraction | Replace with Plug.RewriteOn under enforced trusted-ingress boundaries. It is not a general replacement for RemoteIp's right-to-left proxy-chain algorithm. Where untrusted hops must be parsed, require equivalent trust validation before migration. |
| telemetry_metrics_prometheus_core 1.2.1 | 2024-03-24 | PromEx exporter | Latest PromEx still requires it. Plan exporter migration, potentially using current Peep directly or a maintained OpenTelemetry pipeline, after checking the whole graph. Preserve metric names, labels, buckets, scrape behavior and alerts. A root PromEx update does not close this item. |
| unsafe 1.0.2 | 2023-08-30 | Cachex | Remove with Cachex closure. The package name alone is not evidence of a vulnerability. |
| websock 0.5.3 | 2023-08-15 | Bandit and WebSockAdapter | Obtain an upstream maintained release or framework-supported replacement. Replacing this interface package independently can break WebSocket callbacks and LiveView. No verified replacement meeting all criteria; changing the HTTP server alone does not prove removal. |

### Candidate maintenance and popularity evidence

Stars are snapshots taken on the review date, not a security guarantee. A high star count, recent release and community praise are separate criteria. Small ecosystem libraries can have strong adoption without many stars; those candidates are not presented as satisfying the requested high-star requirement. Replacement packages and services need their own CVE audit before selection.

| Candidate | Latest verified release | GitHub stars | Fit and evidence |
| --- | --- | --- | --- |
| [OpenBao](https://github.com/openbao/openbao) | 2.7.2, 2026-10-26 | 8,806 | [Transit encryption](https://openbao.org/docs/secrets/transit/) and [TOTP verification](https://openbao.org/docs/secrets/totp/) address Cloak/POT capabilities. [OpenSSF/Linux Foundation community governance](https://openbao.org/community/) supports organizational continuity. This is a new operated service, with availability, key recovery and access-policy obligations; governance and stars alone do not establish independent user praise. |
| [Ory Kratos](https://github.com/ory/kratos) | 26.2.0, 2026-03-20 | 13,947 | Maintained identity service covering TOTP and WebAuthn. [Ory's product page](https://www.ory.com/kratos) includes a Fandom adopter account and describes these features. This is vendor-hosted adoption evidence, not an independent satisfaction survey. Migration scope is much larger than swapping a library. |
| [Nebulex](https://github.com/elixir-nebulex/nebulex) | 3.1.0, 2026-10-18 | 1,405 | Candidate for Cachex. Original user recommendations appear in [this caching discussion](https://www.reddit.com/r/elixir/comments/10f92ed) and [this user account](https://www.reddit.com/r/elixir/comments/zktqz8). These are qualitative endorsements, not benchmarks. Adapter releases and dependencies must be reviewed; NimbleOptions remains in the core graph. |
| [Envoy](https://github.com/envoyproxy/envoy) | 1.40.2, 2026-10-27 | 29,159 | [Published adopters](https://www.envoyproxy.io/) include large production users; its [circuit-breaking documentation](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking) explains resource limits. For Fuse-style failure isolation, separately configure outlier detection and test semantics. Operational adoption is evidenced; it is not an Elixir package replacement. |
| [Plug](https://github.com/elixir-plug/plug) | 1.20.3, already installed | 3,019 | Maintained framework component. [Plug.RewriteOn](https://hexdocs.pm/plug/Plug.RewriteOn.html) documents forwarded-IP support and proxy prerequisites. Existing Kith/Phoenix use provides concrete integration evidence; no independent praise claim is needed to establish that use. |
| [Plug.Crypto](https://github.com/elixir-plug/plug_crypto) | 2.2.1, already installed | 97 | Authenticated-encryption building block used by Plug; **does not meet high-star criterion independently**. Using OTP crypto directly relies on [Erlang/OTP](https://github.com/erlang/otp), 12,353 stars, but requires an owned Ecto envelope/migration design rather than a drop-in package. |
| [Locus](https://github.com/g-andrade/locus) | 2.3.17, 2026-10-01 | 122 | Current releases and MaxMind capability verified. **High-star and independent community-praise criteria not established.** Keep as an evaluation candidate, not an approved substitution. |
| [NimbleTOTP](https://github.com/dashbitco/nimble_totp) | 1.0.0, 2023-03-21 | 476 | **Rejected on release age**, despite commits in October 2026. |

Also reject ExternalService 3.2.3 as a way to remove Fuse: its release manifest still requires `fuse ~> 2.5`. A recently released wrapper can retain the same stale dependency.

Some replacement selections therefore remain open. No blanket claim that every candidate satisfies all three requested criteria is justified. Under the strict policy, unresolved transitive cases remain release blockers until a maintained upstream release or a fully evaluated replacement exists; they must not be silently waived.

## Implementation order and completion criteria

1. Remove the four advisory exceptions and enforce empty `HEX_IGNORE_ADVISORIES` and `HEX_IGNORE_RETIREMENTS` for security scans. Retain raw output and nonzero exit propagation. A negative control must demonstrate that an affected lockfile fails.
2. Upgrade Assent, Phoenix.HTML and ssl_verify_fun. Resolve the CLDR/Ecto/Decimal group to Decimal 3.2.0. Review the resulting graph and rerun unfiltered audits.
3. Replace Cloak/Cloak Ecto with a versioned authenticated-encryption solution. Verify old and new ciphertext interoperability, retryable jobs and backups before removing dependencies; the selected format-compatible replacement needs no row rewrite.
4. Migrate API-breaking groups in bounded changes: Hammer/Poolboy, LiveView/Dashboard, Req, Sentry, LoggerJSON, Flop and build wrappers. Upgrade the remaining compatible packages from the inventory below.
5. Complete the stale-package replacement backlog, including upstream-owned transitive interfaces. Resolve Peep 5 and ExHashRing 7 through compatible parent releases or parent replacement. Reassess alternatives for popularity, original adopter feedback, recent releases, licensing and their complete dependency graphs.
6. Require zero current Hex advisories with no ignored IDs, both npm audits passing at low severity, no retired resolved packages, and no packages crossing the release-age threshold. Run compilation, formatting, Credo, Sobelow, Dialyzer, focused integration tests, the full ExUnit suite, all browser regressions and a cold Linux production release. Verify database upgrade/rollback behavior, TLS, OAuth, encryption migration, monetary input/formatting, distributed rate limits and metrics continuity.
7. Correct the stale audit documentation. `docs/dependency-audit.md` incorrectly describes the `wax_` dependency as unrelated; the actual WebAuthn package here is `wax_`. Its claim that `~> X.Y` allows only patches is also wrong: it permits later minor releases below the next major. Use resolved versions as the inventory and refresh the PR body after successful verification.

This review changes documentation only. No dependencies, application code, CI policy, remote PR content or production data have been changed.

## Verification and evidence

The fresh command `env HEX_IGNORE_ADVISORIES= HEX_IGNORE_RETIREMENTS= mix hex.audit` returns failure and all seven advisories. `mix hex.outdated --all` identifies 38 upgrades and 12 packages whose latest versions are blocked by current requirements/parents. Both `npm audit --json` and the equivalent assets audit return zero vulnerabilities. Tests were not rerun for this documentation-only review; prior test successes do not validate the proposed upgrades.

The accompanying `pr44-security-upgrade-evidence.json` records every Hex package, current/latest versions, last-release dates, direct/transitive status, parent constraints, all seven advisory ranges, selected target manifests and GitHub evidence. Raw local outputs are in `tmp/security/pr44-review/`. Upstream sources were checked live on the review date; all targets must be checked again when implementation begins.

## Complete Mix dependency inventory

The following table covers all 107 Hex packages, including packages already current. “Blocked” is the result of `mix hex.outdated` for the existing graph, not a determination that migration is impossible. “Replace” denotes the two-year policy. All package links lead to official Hex metadata; prereleases are excluded from target selection.

| Package | Scope | Locked | Latest stable | Latest release date | Action |
| --- | --- | --- | --- | --- | --- |
| [asn1_compiler](https://hex.pm/packages/asn1_compiler) | Transitive | 0.1.1 | 0.1.1 | 2017-11-17 | Replace |
| [assent](https://hex.pm/packages/assent) | Direct | 0.3.1 | 0.3.2 | 2026-10-28 | Upgrade |
| [bandit](https://hex.pm/packages/bandit) | Direct | 1.14.1 | 1.14.1 | 2026-10-28 | Current |
| [bunt](https://hex.pm/packages/bunt) | Transitive | 1.0.0 | 1.0.0 | 2023-12-05 | Replace |
| [cachex](https://hex.pm/packages/cachex) | Direct | 4.1.1 | 4.1.1 | 2025-06-30 | Current |
| [castore](https://hex.pm/packages/castore) | Transitive | 1.0.22 | 1.0.22 | 2026-10-20 | Current |
| [cbor](https://hex.pm/packages/cbor) | Transitive | 1.0.1 | 1.0.2 | 2026-03-18 | Upgrade |
| [cc_precompiler](https://hex.pm/packages/cc_precompiler) | Transitive | 0.1.11 | 0.1.11 | 2025-08-02 | Current |
| [cldr_utils](https://hex.pm/packages/cldr_utils) | Transitive | 2.29.5 | 2.29.7 | 2026-05-10 | Upgrade |
| [cloak](https://hex.pm/packages/cloak) | Transitive | 1.1.4 | 1.1.4 | 2024-04-06 | Replace |
| [cloak_ecto](https://hex.pm/packages/cloak_ecto) | Direct | 1.3.0 | 1.3.0 | 2024-04-06 | Replace |
| [combine](https://hex.pm/packages/combine) | Transitive | 0.10.0 | 0.10.0 | 2017-08-09 | Replace |
| [comeonin](https://hex.pm/packages/comeonin) | Transitive | 5.5.1 | 5.5.1 | 2025-02-03 | Current |
| [credo](https://hex.pm/packages/credo) | Direct | 1.7.17 | 1.7.19 | 2026-06-05 | Upgrade |
| [db_connection](https://hex.pm/packages/db_connection) | Transitive | 2.10.2 | 2.10.2 | 2026-07-06 | Current |
| [decimal](https://hex.pm/packages/decimal) | Transitive | 2.4.1 | 3.2.0 | 2026-10-10 | Upgrade; blocked by current graph |
| [dialyxir](https://hex.pm/packages/dialyxir) | Direct | 1.4.7 | 1.4.8 | 2026-09-05 | Upgrade |
| [digital_token](https://hex.pm/packages/digital_token) | Transitive | 1.0.0 | 2.1.0 | 2026-09-21 | Upgrade; blocked by current graph |
| [ecto](https://hex.pm/packages/ecto) | Transitive | 3.13.6 | 3.14.2 | 2026-08-14 | Upgrade; blocked by current graph |
| [ecto_sql](https://hex.pm/packages/ecto_sql) | Direct | 3.13.5 | 3.14.0 | 2026-05-19 | Upgrade |
| [elixir_make](https://hex.pm/packages/elixir_make) | Transitive | 0.10.1 | 0.10.1 | 2026-10-24 | Current |
| [eqrcode](https://hex.pm/packages/eqrcode) | Direct | 0.2.1 | 0.2.1 | 2025-02-21 | Current |
| [erlex](https://hex.pm/packages/erlex) | Transitive | 0.2.9 | 0.2.9 | 2026-05-14 | Current |
| [esbuild](https://hex.pm/packages/esbuild) | Direct | 0.10.0 | 0.10.1 | 2026-10-19 | Upgrade |
| [eternal](https://hex.pm/packages/eternal) | Transitive | 1.2.2 | 1.2.2 | 2020-12-02 | Replace |
| [ex_aws](https://hex.pm/packages/ex_aws) | Direct | 2.6.1 | 2.7.0 | 2026-05-06 | Upgrade |
| [ex_aws_s3](https://hex.pm/packages/ex_aws_s3) | Direct | 2.5.9 | 2.5.9 | 2025-12-09 | Current |
| [ex_cldr](https://hex.pm/packages/ex_cldr) | Direct | 2.47.2 | 2.47.5 | 2026-06-28 | Upgrade |
| [ex_cldr_calendars](https://hex.pm/packages/ex_cldr_calendars) | Transitive | 2.4.2 | 2.4.4 | 2026-06-26 | Upgrade |
| [ex_cldr_currencies](https://hex.pm/packages/ex_cldr_currencies) | Transitive | 2.17.1 | 2.17.2 | 2026-05-10 | Upgrade |
| [ex_cldr_dates_times](https://hex.pm/packages/ex_cldr_dates_times) | Direct | 2.25.6 | 2.25.6 | 2026-03-15 | Current |
| [ex_cldr_numbers](https://hex.pm/packages/ex_cldr_numbers) | Direct | 2.38.1 | 2.38.3 | 2026-06-03 | Upgrade |
| [ex_cldr_territories](https://hex.pm/packages/ex_cldr_territories) | Direct | 2.12.0 | 2.12.0 | 2026-02-10 | Current |
| [ex_hash_ring](https://hex.pm/packages/ex_hash_ring) | Transitive | 6.0.4 | 7.0.0 | 2025-04-03 | Upgrade; blocked by current graph |
| [ex_machina](https://hex.pm/packages/ex_machina) | Direct | 2.8.0 | 2.8.2 | 2026-08-02 | Upgrade |
| [ex_phone_number](https://hex.pm/packages/ex_phone_number) | Direct | 0.4.12 | 0.4.12 | 2026-10-25 | Current |
| [expo](https://hex.pm/packages/expo) | Transitive | 1.1.1 | 1.1.1 | 2025-10-22 | Current |
| [file_system](https://hex.pm/packages/file_system) | Transitive | 1.1.1 | 1.1.1 | 2025-09-08 | Current |
| [finch](https://hex.pm/packages/finch) | Direct | 0.24.0 | 0.24.0 | 2026-09-29 | Current |
| [fine](https://hex.pm/packages/fine) | Transitive | 0.1.6 | 0.1.6 | 2026-04-09 | Current |
| [flop](https://hex.pm/packages/flop) | Direct | 0.26.3 | 0.29.1 | 2026-10-17 | Upgrade; blocked by current graph |
| [flop_phoenix](https://hex.pm/packages/flop_phoenix) | Direct | 0.26.0 | 0.27.0 | 2026-09-03 | Upgrade |
| [fuse](https://hex.pm/packages/fuse) | Direct | 2.5.0 | 2.5.0 | 2021-07-01 | Replace |
| [gen_smtp](https://hex.pm/packages/gen_smtp) | Direct | 1.3.0 | 1.3.0 | 2025-05-30 | Current |
| [geolix](https://hex.pm/packages/geolix) | Direct | 2.0.0 | 2.1.0 | 2026-04-06 | Upgrade |
| [geolix_adapter_mmdb2](https://hex.pm/packages/geolix_adapter_mmdb2) | Direct | 0.6.0 | 0.7.0 | 2026-04-04 | Upgrade |
| [gettext](https://hex.pm/packages/gettext) | Direct | 1.0.2 | 1.0.2 | 2025-11-08 | Current |
| [hammer](https://hex.pm/packages/hammer) | Direct | 6.2.1 | 7.5.1 | 2026-10-27 | Upgrade; blocked by current graph |
| [hpax](https://hex.pm/packages/hpax) | Transitive | 1.1.0 | 1.1.0 | 2026-09-24 | Current |
| [html_sanitize_ex](https://hex.pm/packages/html_sanitize_ex) | Direct | 1.5.6 | 1.5.6 | 2026-10-17 | Current |
| [idna](https://hex.pm/packages/idna) | Transitive | 6.1.1 | 7.1.0 | 2026-01-21 | Upgrade |
| [jason](https://hex.pm/packages/jason) | Direct | 1.4.5 | 1.4.5 | 2026-05-05 | Current |
| [jumper](https://hex.pm/packages/jumper) | Transitive | 1.0.2 | 1.0.2 | 2023-08-30 | Replace |
| [lazy_html](https://hex.pm/packages/lazy_html) | Direct | 0.1.13 | 0.1.13 | 2026-09-25 | Current |
| [libcluster](https://hex.pm/packages/libcluster) | Direct | 3.5.0 | 3.5.0 | 2025-01-09 | Current |
| [logger_json](https://hex.pm/packages/logger_json) | Direct | 6.2.1 | 7.0.4 | 2025-07-14 | Upgrade; blocked by current graph |
| [mime](https://hex.pm/packages/mime) | Transitive | 2.0.7 | 2.0.7 | 2025-05-15 | Current |
| [mint](https://hex.pm/packages/mint) | Transitive | 1.11.0 | 1.11.0 | 2026-09-28 | Current |
| [mmdb2_decoder](https://hex.pm/packages/mmdb2_decoder) | Transitive | 3.0.1 | 3.0.1 | 2022-06-20 | Replace |
| [mochiweb](https://hex.pm/packages/mochiweb) | Transitive | 3.5.0 | 3.5.0 | 2026-08-16 | Current |
| [mox](https://hex.pm/packages/mox) | Direct | 1.3.2 | 1.3.2 | 2026-09-11 | Current |
| [nimble_options](https://hex.pm/packages/nimble_options) | Transitive | 1.1.1 | 1.1.1 | 2024-05-25 | Replace |
| [nimble_ownership](https://hex.pm/packages/nimble_ownership) | Transitive | 1.0.2 | 1.0.2 | 2025-10-21 | Current |
| [nimble_pool](https://hex.pm/packages/nimble_pool) | Transitive | 1.1.0 | 1.1.0 | 2024-03-25 | Replace |
| [oban](https://hex.pm/packages/oban) | Direct | 2.24.2 | 2.24.2 | 2026-10-14 | Current |
| [oban_met](https://hex.pm/packages/oban_met) | Transitive | 1.3.3 | 1.3.3 | 2026-10-20 | Current |
| [oban_web](https://hex.pm/packages/oban_web) | Direct | 2.13.1 | 2.13.1 | 2026-10-08 | Current |
| [octo_fetch](https://hex.pm/packages/octo_fetch) | Transitive | 0.5.0 | 0.5.0 | 2026-03-24 | Current |
| [pbkdf2_elixir](https://hex.pm/packages/pbkdf2_elixir) | Direct | 2.3.1 | 2.3.1 | 2025-02-05 | Current |
| [peep](https://hex.pm/packages/peep) | Transitive | 3.5.0 | 5.0.1 | 2026-04-12 | Upgrade; blocked by current graph |
| [phoenix](https://hex.pm/packages/phoenix) | Direct | 1.8.16 | 1.8.16 | 2026-10-20 | Current |
| [phoenix_ecto](https://hex.pm/packages/phoenix_ecto) | Direct | 4.7.0 | 4.7.0 | 2025-11-07 | Current |
| [phoenix_html](https://hex.pm/packages/phoenix_html) | Direct | 4.3.0 | 4.4.0 | 2026-10-30 | Upgrade |
| [phoenix_live_dashboard](https://hex.pm/packages/phoenix_live_dashboard) | Direct | 0.8.7 | 0.9.1 | 2026-08-31 | Upgrade; blocked by current graph |
| [phoenix_live_reload](https://hex.pm/packages/phoenix_live_reload) | Direct | 1.6.2 | 1.7.0 | 2026-07-29 | Upgrade |
| [phoenix_live_view](https://hex.pm/packages/phoenix_live_view) | Direct | 1.1.33 | 1.2.13 | 2026-10-20 | Upgrade; blocked by current graph |
| [phoenix_pubsub](https://hex.pm/packages/phoenix_pubsub) | Transitive | 2.4.1 | 2.4.1 | 2026-10-08 | Current |
| [phoenix_template](https://hex.pm/packages/phoenix_template) | Transitive | 1.1.0 | 1.1.0 | 2026-09-21 | Current |
| [plug](https://hex.pm/packages/plug) | Transitive | 1.20.3 | 1.20.3 | 2026-07-09 | Current |
| [plug_crypto](https://hex.pm/packages/plug_crypto) | Transitive | 2.2.1 | 2.2.1 | 2026-10-23 | Current |
| [poolboy](https://hex.pm/packages/poolboy) | Transitive | 1.5.2 | 1.5.2 | 2019-01-22 | Replace |
| [postgrex](https://hex.pm/packages/postgrex) | Direct | 0.22.4 | 0.22.4 | 2026-08-07 | Current |
| [pot](https://hex.pm/packages/pot) | Direct | 1.0.2 | 1.0.2 | 2021-08-07 | Replace |
| [prom_ex](https://hex.pm/packages/prom_ex) | Direct | 1.11.0 | 1.12.0 | 2026-06-19 | Upgrade |
| [ranch](https://hex.pm/packages/ranch) | Transitive | 2.3.0 | 2.3.0 | 2026-09-08 | Current |
| [redix](https://hex.pm/packages/redix) | Direct | 1.5.3 | 1.10.0 | 2026-10-22 | Upgrade |
| [remote_ip](https://hex.pm/packages/remote_ip) | Direct | 1.2.0 | 1.2.0 | 2024-06-10 | Replace |
| [req](https://hex.pm/packages/req) | Direct | 0.6.3 | 0.7.5 | 2026-10-06 | Upgrade; blocked by current graph |
| [sentry](https://hex.pm/packages/sentry) | Direct | 10.10.0 | 14.0.1 | 2026-10-28 | Upgrade; blocked by current graph |
| [sleeplocks](https://hex.pm/packages/sleeplocks) | Transitive | 1.1.3 | 1.1.4 | 2026-04-10 | Upgrade |
| [sobelow](https://hex.pm/packages/sobelow) | Direct | 0.14.1 | 0.18.1 | 2026-10-29 | Upgrade |
| [ssl_verify_fun](https://hex.pm/packages/ssl_verify_fun) | Transitive | 1.1.7 | 1.1.9 | 2026-10-31 | Upgrade |
| [sweet_xml](https://hex.pm/packages/sweet_xml) | Direct | 0.7.5 | 0.7.5 | 2025-01-07 | Current |
| [swoosh](https://hex.pm/packages/swoosh) | Direct | 1.29.3 | 1.29.3 | 2026-10-28 | Current |
| [tailwind](https://hex.pm/packages/tailwind) | Direct | 0.4.1 | 0.5.2 | 2026-10-23 | Upgrade |
| [telemetry](https://hex.pm/packages/telemetry) | Transitive | 1.4.2 | 1.4.2 | 2026-05-11 | Current |
| [telemetry_metrics](https://hex.pm/packages/telemetry_metrics) | Direct | 1.2.0 | 1.2.0 | 2026-08-25 | Current |
| [telemetry_metrics_prometheus_core](https://hex.pm/packages/telemetry_metrics_prometheus_core) | Transitive | 1.2.1 | 1.2.1 | 2024-03-24 | Replace |
| [telemetry_poller](https://hex.pm/packages/telemetry_poller) | Direct | 1.3.0 | 1.3.0 | 2025-07-09 | Current |
| [thousand_island](https://hex.pm/packages/thousand_island) | Transitive | 1.6.0 | 1.6.0 | 2026-10-15 | Current |
| [tz](https://hex.pm/packages/tz) | Direct | 0.28.1 | 0.28.4 | 2026-09-15 | Upgrade |
| [unicode_util_compat](https://hex.pm/packages/unicode_util_compat) | Transitive | 0.7.1 | 0.7.1 | 2025-05-27 | Current |
| [unsafe](https://hex.pm/packages/unsafe) | Transitive | 1.0.2 | 1.0.2 | 2023-08-30 | Replace |
| [wax_](https://hex.pm/packages/wax_) | Direct | 0.7.0 | 0.7.0 | 2025-05-18 | Current |
| [websock](https://hex.pm/packages/websock) | Transitive | 0.5.3 | 0.5.3 | 2023-08-15 | Replace |
| [websock_adapter](https://hex.pm/packages/websock_adapter) | Transitive | 0.7.0 | 0.7.0 | 2026-10-27 | Current |
| [x509](https://hex.pm/packages/x509) | Transitive | 0.9.2 | 0.9.2 | 2025-07-18 | Current |

Git dependency: `heroicons`, pinned tag `v2.2.0`, latest verified `v2.2.0`, released 18 November 2024; current and inside the two-year threshold.

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
