# Calendars / DigitalToken candidate

This is a **narrow upstream compatibility candidate**, not a Kith dependency change or evidence of released support. The adjacent patch widens Calendars 2.4.4's DigitalToken requirement to permit 1.x or 2.x. Kith must retain Calendars 2.4.4 with DigitalToken 1.0.0 until a genuine reviewed upstream release supports the requested combination.

The existing pin is deliberate: its source documents OTP JSON/polyfill and cross-build problems. DigitalToken 2.1 also raises its Elixir floor to `~> 1.17`, while Calendars advertises `~> 1.12`. A version-range edit alone does not resolve that runtime policy. Upstream must decide the supported floor or version-selection strategy and validate its full runtime matrix before merging or releasing this candidate. No upstream issue, message or PR has been sent.

From the repository root, run:

```sh
docs/plan/pr44-upstream/calendar-compatibility/run.sh
```

The harness verifies the official Calendars archive's SHA-256, applies the patch to a temporary copy, then creates separate cold Mix projects for DigitalToken **1.0.0** and **2.1.0**. It uses the repository's pinned tool versions, isolated dependency/build directories, frozen locks and empty Hex ignore variables. It does not modify Kith's manifest or lock, and uses no dependency overrides. Reports default to `tmp/security/calendar-compatibility`; an alternative report directory can be supplied as the first argument.

Each fixture checks token registry IDs/names/symbols and cryptocurrency formatting in English/French/Arabic, Gregorian leap-date roundtrips and localized month names, and exact fiat/decimal formatting. The graph check verifies installed Hex constraints and the changed path parent's active requirements. An unfiltered audit is included; a clean result applies only to this fixture.

The preserved historical cold runs used Elixir **1.19.5**, OTP **28** / ERTS **16.4.0.5**. Each passed **three tests with zero failures**. Both resolved seven Hex packages; the 1.x graph had 14 installed Hex edges and the 2.x graph had 12. The path Calendars parent adds three active edges separately. Sources, archive checksum, scope and blockers are recorded in `evidence.json`; the original logs are named `*.historical-tests.log`.

During artifact preparation, the packaged graph checker and test fixture were rerun successfully against both existing isolated builds: three tests per version, zero failures, and no installed-constraint mismatch. The shell runner passed syntax checking and the patch passed a dry run against the original package. The corrected full cold runner was then executed successfully on 1 November 2026: both versions passed three tests, all installed-constraint checks and unfiltered audits. Fresh logs are archived separately in `cold-1.0.0/` and `cold-2.1.0/`. The runner clears all inherited Mix path/lock overrides and uses each fresh project’s default build layout.

These fixtures intentionally exclude CLDR DatesTimes and the complete Kith graph. A probe combining the patched path parent with the Hex DatesTimes parent failed source resolution; no override was added to bypass it. This fixture therefore does **not** establish unchanged-parent, all-optional-integration or full-application compatibility. It also does not verify older OTP JSON/polyfill behavior, the full advertised Elixir matrix, release builds, or upstream adoption. DigitalToken's latest-version blocker remains open.
