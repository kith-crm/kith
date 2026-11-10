#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
python3 scripts/oidc-local/ownership.py check
: "${KITH_OIDC_PASSWORD:?true or false}"
: "${KITH_OIDC_DATABASE_SUFFIX:?separate database suffix}"
[[ "$KITH_OIDC_PASSWORD" =~ ^(true|false)$ && "$KITH_OIDC_DATABASE_SUFFIX" =~ ^_fresh_[a-z0-9_]+$ ]]
python3 - <<'PY'
import socket
for port in [8464,8465]:
 with socket.socket() as s:
  s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
  s.bind(('127.0.0.1',port))
PY
set -a
source .oidc-local/runtime.env
set +a
export MIX_ENV=test KITH_OIDC_E2E=1 ERL_FLAGS='+S 4:4'
export KITH_OIDC_APP_PORT=8464 KITH_OIDC_FIXTURE_PORT=8465
run_marker="--kith-run=$KITH_RUN_ID"
mix run --no-start "$PWD/scripts/oidc-local/server.exs" "$run_marker" &
app_pid=$!
sleep 1
python3 scripts/oidc-local/freshness-process.py record "$app_pid"
wait "$app_pid"
