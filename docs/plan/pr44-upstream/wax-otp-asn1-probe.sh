#!/usr/bin/env bash
set -euo pipefail
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE

# Requires Python 3, curl, patch, Elixir/Mix and a complete OTP distribution
# including the ASN.1 compiler. It changes only the supplied/new temporary dir.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../.." && pwd)
if [[ $# -gt 0 ]]; then
  evidence_dir=$1
  mkdir -p -- "$evidence_dir"
  evidence_dir=$(cd -- "$evidence_dir" && pwd)
  if [[ -e "$evidence_dir/original" || -e "$evidence_dir/candidate" ]]; then
    echo 'Use a fresh evidence directory; existing copies are never overwritten.' >&2
    exit 2
  fi
else
  evidence_dir=$(mktemp -d "${TMPDIR:-/tmp}/kith-wax-otp-asn1.XXXXXX")
fi
printf '%s\n' "$evidence_dir"
elixir --version > "$evidence_dir/runtime.log"
curl --fail --silent --show-error --location https://repo.hex.pm/tarballs/wax_-0.7.0.tar --output "$evidence_dir/wax_-0.7.0.tar"
python3 - "$evidence_dir" <<'PY'
import hashlib, io, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1]); data = (root / 'wax_-0.7.0.tar').read_bytes()
assert hashlib.sha256(data).hexdigest() == '473b3378608418747e67746b7164576f1690a4ed1e044a4c8085a754269d21ce'
with tarfile.open(fileobj=io.BytesIO(data)) as outer:
    contents = outer.extractfile('contents.tar.gz').read()
for name in ['original', 'candidate']:
    folder = root / name; folder.mkdir()
    with tarfile.open(fileobj=io.BytesIO(contents), mode='r:gz') as package:
        package.extractall(folder, filter='data')
PY
for variant in original candidate; do
  if [[ -f "$repo_root/.tool-versions" ]]; then
    cp -- "$repo_root/.tool-versions" "$evidence_dir/$variant/.tool-versions"
  fi
done
(
  cd -- "$evidence_dir/candidate"
  patch --batch --forward -p1 < "$script_dir/wax-otp-asn1.patch" > "$evidence_dir/patch.log"
)
for source in "$evidence_dir/original/asn1/"*.asn1; do
  cmp -- "$source" "$evidence_dir/candidate/asn1/$(basename -- "$source")"
done
for variant in original candidate; do
  (
    cd -- "$evidence_dir/$variant"
    MIX_ENV=test mix deps.get > "$evidence_dir/$variant-resolve.log" 2>&1
    MIX_ENV=test mix compile --warnings-as-errors > "$evidence_dir/$variant-compile.log" 2>&1
  )
done
export WAX_SCHEMA_FIXTURES="$evidence_dir/legacy-fixtures.etf"
(
  cd -- "$evidence_dir/original"
  WAX_SCHEMA_FIXTURES_OUT="$WAX_SCHEMA_FIXTURES" MIX_ENV=test mix run "$script_dir/wax-otp-asn1-probe.exs" > "$evidence_dir/original-probe.log" 2>&1
)
(
  cd -- "$evidence_dir/candidate"
  MIX_ENV=test mix run "$script_dir/wax-otp-asn1-probe.exs" > "$evidence_dir/candidate-probe.log" 2>&1
  MIX_ENV=test mix compile --verbose > "$evidence_dir/incremental.log" 2>&1
  if grep -q 'Compiling 3 Wax ASN.1 schemas' "$evidence_dir/incremental.log"; then
    echo 'Incremental compilation unexpectedly regenerated unchanged schemas.' >&2; exit 1
  fi
  rm -- src/AndroidKeyAttestationV2.erl
  MIX_ENV=test mix compile --warnings-as-errors > "$evidence_dir/missing-output.log" 2>&1
  test -f src/AndroidKeyAttestationV2.erl
  MIX_ENV=test mix clean > "$evidence_dir/clean.log" 2>&1
  test ! -f src/AndroidKeyAttestationV1.erl
  MIX_ENV=test mix compile --warnings-as-errors > "$evidence_dir/recompile.log" 2>&1
  cp -- asn1/AndroidKeyAttestationV1.asn1 "$evidence_dir/schema-before-negative-control.asn1"
  python3 - <<'PY_INVALID'
from pathlib import Path
source = Path('asn1/AndroidKeyAttestationV1.asn1')
text = source.read_text()
assert 'DEFINITIONS IMPLICIT TAGS ::=' in text
source.write_text(text.replace('DEFINITIONS IMPLICIT TAGS ::=', 'DEFINITIONS INVALID_TOKEN ::=', 1))
PY_INVALID
  if MIX_ENV=test mix compile > "$evidence_dir/invalid-schema-negative.log" 2>&1; then
    echo 'Malformed ASN.1 unexpectedly passed compilation.' >&2; exit 1
  fi
  cp -- "$evidence_dir/schema-before-negative-control.asn1" asn1/AndroidKeyAttestationV1.asn1
  MIX_ENV=test mix compile --warnings-as-errors > "$evidence_dir/restored-compile.log" 2>&1
  MIX_ENV=test mix run "$script_dir/wax-otp-asn1-probe.exs" > "$evidence_dir/restored-probe.log" 2>&1
  # Regression: a successful earlier schema can leave changed outputs behind
  # when a later schema fails. Restoring inputs must never reuse that success.
  cp -- asn1/AndroidKeyAttestationV1.asn1 "$evidence_dir/v1-before-mixed-control.asn1"
  cp -- asn1/AndroidKeyAttestationV2.asn1 "$evidence_dir/v2-before-mixed-control.asn1"
  python3 - <<'PY_MIXED'
from pathlib import Path
first = Path('asn1/AndroidKeyAttestationV1.asn1')
text = first.read_text(); field = '    osPatchLevel  [706] EXPLICIT INTEGER OPTIONAL'
assert field in text
first.write_text(text.replace(field, field + ',\n    probeFlag  [707] EXPLICIT NULL OPTIONAL', 1))
second = Path('asn1/AndroidKeyAttestationV2.asn1')
text = second.read_text(); assert 'DEFINITIONS IMPLICIT TAGS ::=' in text
second.write_text(text.replace('DEFINITIONS IMPLICIT TAGS ::=', 'DEFINITIONS INVALID_TOKEN ::=', 1))
PY_MIXED
  if MIX_ENV=test mix compile > "$evidence_dir/mixed-schema-negative.log" 2>&1; then
    echo 'Mixed valid/invalid schemas unexpectedly passed compilation.' >&2; exit 1
  fi
  test ! -f _build/test/lib/wax_/.mix/.compile.wax_asn1
  if cmp -s src/AndroidKeyAttestationV1.erl "$evidence_dir/original/src/AndroidKeyAttestationV1.erl"; then
    echo 'Mixed regression did not produce the intended partial earlier output.' >&2; exit 1
  fi
  cp -- "$evidence_dir/v1-before-mixed-control.asn1" asn1/AndroidKeyAttestationV1.asn1
  cp -- "$evidence_dir/v2-before-mixed-control.asn1" asn1/AndroidKeyAttestationV2.asn1
  MIX_ENV=test mix compile --warnings-as-errors > "$evidence_dir/mixed-restored-compile.log" 2>&1
  for module in AndroidKeyAttestationV1 AndroidKeyAttestationV2 AndroidKeyAttestationV3; do
    for extension in erl hrl; do
      cmp -- "src/$module.$extension" "$evidence_dir/original/src/$module.$extension"
    done
  done
  printf '%s\n' 'PASS: restored Erlang/header outputs exactly match all three legacy schemas' > "$evidence_dir/mixed-restored-equivalence.log"
  MIX_ENV=test mix run "$script_dir/wax-otp-asn1-probe.exs" > "$evidence_dir/mixed-restored-probe.log" 2>&1
  MIX_ENV=prod mix hex.build --output "$evidence_dir/wax-candidate.tar" > "$evidence_dir/package.log" 2>&1
)
python3 - "$evidence_dir" <<'PY'
import io, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1]); folder = root / 'release-source'; folder.mkdir()
with tarfile.open(root / 'wax-candidate.tar') as outer:
    contents = outer.extractfile('contents.tar.gz').read()
with tarfile.open(fileobj=io.BytesIO(contents), mode='r:gz') as package:
    package.extractall(folder, filter='data')
assert (folder / 'mix/wax_asn1.exs').is_file()
assert not (folder / '_build').exists()
assert not (folder / 'src').exists()
PY
if [[ -f "$repo_root/.tool-versions" ]]; then
  cp -- "$repo_root/.tool-versions" "$evidence_dir/release-source/.tool-versions"
fi
(
  cd -- "$evidence_dir/release-source"
  MIX_ENV=prod mix deps.get > "$evidence_dir/release-resolve.log" 2>&1
  MIX_ENV=prod mix compile --warnings-as-errors > "$evidence_dir/release-compile.log" 2>&1
  HEX_IGNORE_ADVISORIES= HEX_IGNORE_RETIREMENTS= MIX_ENV=prod mix hex.audit > "$evidence_dir/release-audit.log" 2>&1
  MIX_ENV=prod mix release --overwrite > "$evidence_dir/release-build.log" 2>&1
  WAX_RELEASE_PROBE_SCRIPT="$script_dir/wax-otp-asn1-release-probe.exs" _build/prod/rel/wax_/bin/wax_ eval 'Code.eval_file(System.fetch_env!("WAX_RELEASE_PROBE_SCRIPT"))' > "$evidence_dir/release-probe.log" 2>&1
  if grep -q 'asn1_compiler' mix.lock; then
    echo 'Stale ASN.1 helper remains in the candidate closure.' >&2; exit 1
  fi
)
printf '%s\n' 'PASS: legacy/candidate compatibility, compiler negative control, fresh packaged production release'
