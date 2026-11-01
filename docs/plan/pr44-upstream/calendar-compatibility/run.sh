#!/usr/bin/env bash
# Reproduce the narrow upstream candidate in fresh temporary Mix projects.
set -euo pipefail
artifact_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$artifact_dir/../../../.." && pwd)"
report_dir="${1:-$repo_root/tmp/security/calendar-compatibility}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cp "$repo_root/.tool-versions" "$scratch/.tool-versions"
export MIX_ENV=dev
export HEX_IGNORE_ADVISORIES= HEX_IGNORE_RETIREMENTS=
unset MIX_LOCKFILE MIX_BUILD_ROOT MIX_BUILD_PATH MIX_DEPS_PATH
unset CLDR_UNSAFE_HTTPS

curl --fail --location --max-time 60 --silent --show-error \
  https://repo.hex.pm/tarballs/ex_cldr_calendars-2.4.4.tar > "$scratch/calendars.tar"
python3 - "$scratch/calendars.tar" <<'PY'
import hashlib,pathlib,sys
expected='40a15cec56aa9c7752b4c9248cc321880f22ef2f3401b69c984c4da242b19a68'
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == expected
PY
mkdir "$scratch/archive" "$scratch/patched-calendars"
tar -xf "$scratch/calendars.tar" -C "$scratch/archive"
tar -xzf "$scratch/archive/contents.tar.gz" -C "$scratch/patched-calendars"
patch --directory "$scratch/patched-calendars" -p1 < "$artifact_dir/../ex_cldr_calendars-digital-token-2.patch"
export CALENDAR_COMPAT_SOURCE="$scratch/patched-calendars"

for token_version in 1.0.0 2.1.0; do
  project="$scratch/probe-$token_version"
  mkdir -p "$project/lib" "$project/config" "$report_dir/$token_version"
  cp "$artifact_dir/backend.ex" "$project/lib/backend.ex"
  cp "$artifact_dir/config.exs" "$project/config/config.exs"
  cp "$artifact_dir/$token_version.mix.lock" "$project/mix.lock"
  python3 - "$project/mix.exs" "$token_version" <<'PY'
import pathlib,sys
manifest='''defmodule CalendarCompatibility.MixProject do
  use Mix.Project
  def project do
    [app: :calendar_compatibility, version: "0.1.0", deps: [
      {:ex_cldr_calendars, path: System.fetch_env!("CALENDAR_COMPAT_SOURCE")},
      {:digital_token, "== __TOKEN_VERSION__"},
      {:ex_cldr_numbers, "== 2.38.3"},
      {:ex_cldr, "== 2.47.5"},
      {:cldr_utils, "== 2.29.7"},
      {:decimal, "== 3.2.0"},
      {:jason, "== 1.4.5"}
    ]]
  end
end
'''
pathlib.Path(sys.argv[1]).write_text(manifest.replace('__TOKEN_VERSION__',sys.argv[2]))
PY
  # Each fresh project owns its default deps/_build directories. Keep Mix's
  # environment-specific layout, which CLDR uses while resolving its priv data.
  (
    cd "$project"
    elixir --version > "$report_dir/$token_version/runtime.log"
    mix deps.get > "$report_dir/$token_version/resolution.log" 2>&1
    mix compile --warnings-as-errors > "$report_dir/$token_version/compile.log" 2>&1
    mix run --no-start "$artifact_dir/graph.exs" > "$report_dir/$token_version/graph.log" 2>&1
    mix run "$artifact_dir/probe.exs" > "$report_dir/$token_version/tests.log" 2>&1
    mix hex.audit > "$report_dir/$token_version/audit.log" 2>&1
    cp mix.exs mix.lock dependency-graph.json "$report_dir/$token_version/"
  )
done
echo "Narrow candidate probes passed; reports: $report_dir"
