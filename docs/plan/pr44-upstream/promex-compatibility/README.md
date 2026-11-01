# Unreleased PromEx / Peep compatibility candidate

This directory contains an upstream candidate, not an adopted Kith dependency or a published fix. Kith retains released PromEx 1.12.0 with Peep 4.4.0 until a reviewed parent release supports Peep 5 and makes Prometheus Core optional.

The adjacent patch:

- Permits Peep 5 alongside the existing 3/4 series.
- Makes `telemetry_metrics_prometheus_core` optional and compiles its adapter only when the dependency is available.
- Keeps Core as the default when installed; otherwise selects Peep. Explicit adapter configuration still wins.
- Returns the storage contract's `:prom_ex_down` when a Peep reporter is absent.
- Documents the explicit dependency needed by Core users.

Run the isolated reproduction from the repository root:

```sh
python3 docs/plan/pr44-upstream/promex-compatibility/run.py
```

It downloads the official PromEx 1.12.0 archive, verifies its SHA-256, applies the patch in a new temporary directory, and resolves three separate consumers without overrides: original PromEx + Peep 4.4/Core; candidate + Peep 5.0.1 without Core; candidate + Peep 5.0.1 with Core explicitly installed. Existing workspace paths are rejected. Direct root versions are fixed; transitive releases are resolved within their declared constraints, with the recorded run locks archived under `logs/`. The current repository `.tool-versions` is copied into each consumer; build/dependency directory and lockfile overrides are removed from their environment. Both Hex ignore variables are explicitly empty.

Each consumer runs four tests, emits a complete resolved Hex graph plus the actual path-parent edges, and performs a Hex audit. The fixture uses the five plugins selected by Kith: Application, BEAM, Phoenix, Ecto and Oban. It compares all generated metric definitions, renders all five bundled dashboards, and compares deterministic representative Phoenix/Ecto/Oban export lines across versions. It also exercises Application/BEAM telemetry and checks actual Core startup/scraping when installed.

The report separates this evidence from unverified behavior. Ecto/Oban/Phoenix events are synthetic; no database queries, live job execution or HTTP router server run in these consumers. Application/BEAM values vary and are not byte-compared. Kith's `/metrics` authentication and disabled-exporter 503 behavior are separate application/release checks. Only the pinned current Elixir/OTP runtime is tested; Peep 3 was not rerun with the candidate. Existing dependency compiler warnings, including the Oban static-analysis warning and optional `Plug.Cowboy` warning, remain visible in the archived logs; this patch does not add Cowboy or hide that warning.

A genuine upstream release and its supported runtime/integration matrix remain required. NimbleOptions, NimblePool and WebSock still occur in the Peep-only consumer closure and retain separate maintenance blockers. No issue, message or pull request has been sent upstream by this work.
