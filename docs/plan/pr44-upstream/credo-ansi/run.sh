#!/usr/bin/env bash
# Isolated candidate; does not change Kith's dependency resolution.
set -euo pipefail
artifacts="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$artifacts/../../../.." && pwd)"
reports="${1:-$repo_root/tmp/security/credo-ansi}"
mkdir -p "$reports"
reports="$(cd "$reports" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cp "$repo_root/.tool-versions" "$scratch/.tool-versions"
export MIX_ENV=prod HEX_IGNORE_ADVISORIES= HEX_IGNORE_RETIREMENTS=
unset MIX_LOCKFILE MIX_BUILD_ROOT MIX_BUILD_PATH MIX_DEPS_PATH
curl --fail --silent --show-error --location --max-time 60 https://repo.hex.pm/tarballs/credo-1.7.19.tar -o "$scratch/credo.tar"
python3 - "$scratch/credo.tar" <<'PY'
import hashlib,pathlib,sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()=='2d8bc95d5a7bb99dd2613621d4f08c6a3575c3fd4b62e6a2b48a100352a557b8'
PY
mkdir -p "$scratch/archive" "$scratch/original" "$scratch/fixture/lib"
tar -xf "$scratch/credo.tar" -C "$scratch/archive"
tar -xzf "$scratch/archive/contents.tar.gz" -C "$scratch/original"
cp -R "$scratch/original" "$scratch/candidate"
patch -d "$scratch/candidate" -p1 < "$artifacts/credo-ansi.patch" > "$reports/patch.log"
printf 'defmodule Bad do\n  def bad(x), do: x==nil\nend\n' > "$scratch/fixture/lib/bad.ex"
for variant in original candidate; do
  mkdir "$scratch/consumer-$variant"
  cat > "$scratch/consumer-$variant/mix.exs" <<MIX
  defmodule CredoProbe.MixProject do
    use Mix.Project
    def project, do: [app: :credo_probe, version: "0.1.0", deps: [{:credo, path: "../$variant", runtime: false}]]
  end
MIX
  (
    cd "$scratch/consumer-$variant"
    mix deps.get > "$reports/$variant-resolution.log" 2>&1
    mix compile --warnings-as-errors > "$reports/$variant-compile.log" 2>&1
    cp mix.lock "$reports/$variant.mix.lock"
    CREDO_LOCK_COUNT="$reports/$variant-lock-count.txt" mix run --no-start -e 'File.write!(System.fetch_env!("CREDO_LOCK_COUNT"), to_string(map_size(Mix.Dep.Lock.read())))'
    set +e
    mix credo "$scratch/fixture" --strict --format json > "$reports/$variant.json" 2> "$reports/$variant.stderr"
    result=$?
    set -e
    [[ "$result" == 4 ]] || { echo "Expected real Credo findings to block, got $result" >&2; exit 1; }
    echo "$result" > "$reports/$variant.status"
    mix hex.audit > "$reports/$variant-audit.log" 2>&1
  )
done
(
  cd "$scratch/candidate"
  CREDO_ANSI_EXPECTED="$artifacts/expected.exs" CREDO_ANSI_REPORT_DIR="$reports" elixir "$artifacts/probe.exs" > "$reports/output-tests.log" 2>&1
)
python3 - "$reports" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);a=json.loads((p/'original.json').read_text());b=json.loads((p/'candidate.json').read_text());assert a==b and a['issues'];assert '"bunt"' not in (p/'candidate.mix.lock').read_text()
(p/'result.json').write_text(json.dumps({'status':'passed','scope':'isolated Credo parent candidate only','byte_parity_cases':int((p/'comparisons.txt').read_text()),'tests':2,'json_issues':len(a['issues']),'strict_exit_status':4,'candidate_hex_nodes':int((p/'candidate-lock-count.txt').read_text()),'bunt_removed':True},indent=2)+'\n')
PY
echo "Credo candidate checks passed; reports: $reports"
