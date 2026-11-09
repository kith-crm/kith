#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
[[ -d .oidc-local ]] || python3 scripts/oidc-local/setup.py
for kind in kith proxy; do
  if [[ -f ".oidc-local/$kind.pid" ]] && kill -0 "$(cat ".oidc-local/$kind.pid")" 2>/dev/null; then
    echo 'Owned host process already running; use down.sh before restarting'; exit 1
  fi
done
python3 scripts/oidc-local/ownership.py check
project=$(python3 scripts/oidc-local/ownership.py project)
compose=(docker compose --env-file .oidc-local/runtime.env -p "$project" -f scripts/oidc-local/compose.yml)
"${compose[@]}" config --quiet
"${compose[@]}" up -d > .oidc-local/up.log 2>&1
ready=0
for _ in {1..300}; do
  if curl -fsS http://127.0.0.1:19049/-/health/ready/ >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Owned Authentik readiness failed; preserve restricted .oidc-local logs and inspect owned project state'; exit 1; }
provisioned=0
for _ in {1..30}; do
  if "${compose[@]}" exec -T --user root server ak shell < scripts/oidc-local/provision.py > .oidc-local/provision.log 2>&1; then provisioned=1; break; fi
  sleep 2
done
[[ "$provisioned" == 1 ]] || { echo 'Provider provisioning failed; restricted .oidc-local/provision.log'; exit 1; }
run_marker="--kith-run=$(python3 -c 'import json; print(json.load(open(".oidc-local/run.json"))["run_id"])')"
nohup python3 "$PWD/scripts/oidc-local/proxy.py" "$run_marker" < /dev/null > .oidc-local/proxy.log 2>&1 &
echo "$!" > .oidc-local/proxy.pid
python3 scripts/oidc-local/ownership.py record proxy
set -a
source .oidc-local/runtime.env
set +a
export MIX_ENV=test KITH_OIDC_E2E=1 ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"
nohup mix run --no-start "$PWD/scripts/oidc-local/server.exs" "$run_marker" < /dev/null > .oidc-local/kith.log 2>&1 &
echo "$!" > .oidc-local/kith.pid
sleep 1
python3 scripts/oidc-local/ownership.py record kith
for _ in {1..120}; do
  if python3 scripts/oidc-local/check.py > .oidc-local/check.log 2>&1; then cat .oidc-local/check.log; wait "$(cat .oidc-local/kith.pid)"; exit $?; fi
  kill -0 "$(cat .oidc-local/kith.pid)" || { echo 'Owned Kith exited; restricted diagnostic .oidc-local/kith.log'; exit 1; }
  sleep 1
done
echo 'Verified readiness failed; diagnostics retained in ignored .oidc-local'
exit 1
