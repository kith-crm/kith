#!/usr/bin/env python3
"""Reproduce the unreleased PromEx candidate in isolated Mix consumers."""
import argparse
import concurrent.futures
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
PACKAGE_URL = "https://repo.hex.pm/tarballs/prom_ex-1.12.0.tar"
PACKAGE_SHA256 = "6357484941489ba2fee64bb1e9f2a1e86309545304f9e90144e3c10e553c958b"
VARIANTS = ("probe-peep4-original", "probe-peep5", "probe-peep5-core")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(arguments, directory, environment, log):
    with (directory / log).open("wb") as output:
        result = subprocess.run(arguments, cwd=directory, env=environment, stdout=output,
                                stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        raise RuntimeError(f"{arguments} failed ({result.returncode}); see {directory / log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, help="New directory; existing paths are rejected")
    args = parser.parse_args()
    workspace = args.workspace or Path(tempfile.mkdtemp(prefix="kith-promex-upstream-"))
    if args.workspace:
        workspace.mkdir(parents=True, exist_ok=False)
    workspace = workspace.resolve()
    print(f"Workspace: {workspace}", flush=True)
    with urllib.request.urlopen(PACKAGE_URL, timeout=60) as response:
        archive = response.read()
    if digest(archive) != PACKAGE_SHA256:
        raise RuntimeError("PromEx archive checksum mismatch")
    original = workspace / "original"
    original.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as outer:
        contents = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        inner.extractall(original, filter="data")
    shutil.copytree(original, workspace / "candidate")
    environment = os.environ.copy()
    for name in ("MIX_BUILD_PATH", "MIX_BUILD_ROOT", "MIX_DEPS_PATH", "MIX_LOCKFILE"):
        environment.pop(name, None)
    environment.update(MIX_ENV="prod", HEX_IGNORE_ADVISORIES="", HEX_IGNORE_RETIREMENTS="")
    environment.setdefault("ERL_FLAGS", "+S 2:2")
    command(["patch", "--batch", "-p1", "-i", str(HERE.parent / "promex-peep5-optional-core.patch")],
            workspace / "candidate", environment, "patch.log")
    for variant in VARIANTS:
        project = workspace / variant
        project.mkdir()
        (project / "config").mkdir()
        shutil.copyfile(REPO / ".tool-versions", project / ".tool-versions")
        shutil.copyfile(HERE / "probe.exs", project / "probe.exs")
        shutil.copyfile(HERE / "graph.exs", project / "graph.exs")
        parent = "original" if variant == "probe-peep4-original" else "candidate"
        peep = "4.4.0" if parent == "original" else "5.0.1"
        core = '\n      {:telemetry_metrics_prometheus_core, "== 1.2.1"},' if variant.endswith("-core") else ""
        (project / "mix.exs").write_text('''defmodule PromExUpstreamProbe.MixProject do
  use Mix.Project
  def project do
    [app: :promex_upstream_probe, version: "0.0.0", elixir: "~> 1.19", deps: [
      {:prom_ex, path: "../%s"},
      {:peep, "== %s"},%s
      {:phoenix, "== 1.8.16"},
      {:ecto, "== 3.14.2"},
      {:oban, "== 2.24.2"}
    ]]
  end
  def application, do: [extra_applications: [:logger]]
end
''' % (parent, peep, core))
        (project / "config/config.exs").write_text('import Config\nconfig :logger, level: :warning\n')

    def verify(variant):
        project = workspace / variant
        local_environment = environment.copy()
        local_environment["PROMEX_PROBE_ORIGINAL"] = "1" if variant.endswith("-original") else "0"
        command(["mix", "deps.get"], project, local_environment, "resolve.log")
        command(["mix", "run", "probe.exs"], project, local_environment, "probe-final.log")
        command(["mix", "run", "--no-start", "graph.exs"], project, local_environment, "graph.log")
        command(["mix", "hex.audit"], project, local_environment, "audit.log")
        return json.loads((project / "resolved-graph.json").read_text())

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        graphs = dict(zip(VARIANTS, pool.map(verify, VARIANTS)))
    require(graphs["probe-peep5"]["core_installed"] is False, "Core leaked into Peep-only closure")
    require(graphs["probe-peep4-original"]["core_installed"] is True, "Original Core dependency missing")
    require(graphs["probe-peep5-core"]["core_installed"] is True, "Explicit Core dependency missing")
    contracts = [json.loads((workspace / variant / "plugin-contract.json").read_text()) for variant in VARIANTS]
    require(bool(contracts[0]) and contracts[0] == contracts[1] == contracts[2], "Metric contracts differ or are empty")
    dashboards = {}
    for family in ("application", "beam", "phoenix", "ecto", "oban"):
        outputs = [(workspace / variant / "dashboards" / f"{family}.json").read_bytes() for variant in VARIANTS]
        require(bool(outputs[0]) and outputs[0] == outputs[1] == outputs[2], f"Parity failed for {family}")
        dashboards[family] = digest(outputs[0])
    exported_lines = {}
    for family in ("phoenix", "ecto", "oban"):
        outputs = [sorted(line for line in (workspace / variant / "scrape.prom").read_text().splitlines()
                          if f"kith_prom_ex_{family}" in line) for variant in VARIANTS]
        require(bool(outputs[0]) and outputs[0] == outputs[1] == outputs[2], f"Parity failed for {family}")
        exported_lines[family] = len(outputs[0])
    report = {"status": "passed", "unreleased_candidate": True, "package_url": PACKAGE_URL,
              "package_sha256": PACKAGE_SHA256, "variants": graphs,
              "identical_metric_definitions": len(contracts[0]), "dashboard_sha256": dashboards,
              "identical_representative_export_lines": exported_lines,
              "limits": ["No upstream release or Kith adoption is established.",
                         "Only the current Kith Elixir/OTP runtime is tested.",
                         "Application/BEAM variable samples are exercised but not byte-compared.",
                         "Ecto/Oban/Phoenix representative events are synthetic; no live DB/job/router server.",
                         "Kith /metrics auth and disabled-exporter503 are tested separately in Kith, not this consumer.",
                         "Existing optional Plug.Cowboy compiler warning is outside this patch.",
                         "NimbleOptions, NimblePool and WebSock maintenance blockers remain in this closure."]}
    (workspace / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {workspace / 'report.json'}", flush=True)


if __name__ == "__main__":
    main()
