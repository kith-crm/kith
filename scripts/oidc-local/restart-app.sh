#!/usr/bin/env bash
# Restart only owned Kith. Provider/proxy and private provider credentials persist.
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
[[ "${KITH_OIDC_PASSWORD:?set password policy}" =~ ^(true|false)$ ]]
[[ "${KITH_OIDC_DATABASE_SUFFIX:?use a fresh database suffix}" =~ ^_[a-z0-9_]+$ ]]
python3 scripts/oidc-local/ownership.py check
python3 scripts/oidc-local/ownership.py stop kith
for _ in {1..60}; do
  if ! kill -0 "$(cat .oidc-local/kith.pid)" 2>/dev/null; then break; fi
  sleep 1
done
set -a
source .oidc-local/runtime.env
set +a
export MIX_ENV=test KITH_OIDC_E2E=1 ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"
run_marker="--kith-run=$(python3 -c 'import json; print(json.load(open(".oidc-local/run.json"))["run_id"])')"
nohup mix run --no-start "$PWD/scripts/oidc-local/server.exs" "$run_marker" < /dev/null > .oidc-local/kith.log 2>&1 &
echo "$!" > .oidc-local/kith.pid
sleep 1
python3 scripts/oidc-local/ownership.py record kith
for _ in {1..120}; do
 if python3 scripts/oidc-local/check.py > .oidc-local/check.log 2>&1; then
  python3 - <<'PY'
import json,os,pathlib
pathlib.Path('.oidc-local/app-mode.json').write_text(json.dumps({'password':os.environ['KITH_OIDC_PASSWORD'],'database_suffix':os.environ['KITH_OIDC_DATABASE_SUFFIX']}))
PY
  echo 'PASS owned Kith restarted with selected policy/database'
  wait "$(cat .oidc-local/kith.pid)"
  exit $?
 fi
 sleep 1
done
exit 1
