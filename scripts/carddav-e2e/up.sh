#!/usr/bin/env bash
# Start an isolated Kith dev server for CardDAV live tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ENV_FILE=/tmp/kith-carddav-e2e.env
PID_FILE=/tmp/kith-carddav-e2e.pid
LOG_FILE=/tmp/kith-carddav-server.log
PORT=4517
DB_NAME="${DB_NAME:-kith_carddav_e2e}"

case "$DB_NAME" in
  kith_dev | kith_test*)
    echo "refusing to run against DB_NAME=$DB_NAME" >&2
    exit 1
    ;;
esac

listener="$(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$listener" ]; then
  ours="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$ours" ] && { [ "$listener" = "$ours" ] || pgrep -P "$ours" | grep -qx "$listener"; }; then
    echo "server already running (pid $ours)"
    exit 0
  fi
  echo "port $PORT is held by a process that is not ours: $listener" >&2
  exit 1
fi

# Reuse dirs from a previous env file so data stays consistent across restarts.
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
STORAGE_PATH="${STORAGE_PATH:-}"
PLAYWRIGHT_OUTPUT_DIR="${PLAYWRIGHT_OUTPUT_DIR:-}"
[ -d "$STORAGE_PATH" ] || STORAGE_PATH="$(mktemp -d)"
[ -d "$PLAYWRIGHT_OUTPUT_DIR" ] || PLAYWRIGHT_OUTPUT_DIR="$(mktemp -d)"

cat > "$ENV_FILE" <<EOF
export MIX_ENV=dev
export DB_NAME=$DB_NAME
export PORT=$PORT
export STORAGE_PATH=$STORAGE_PATH
export PLAYWRIGHT_OUTPUT_DIR=$PLAYWRIGHT_OUTPUT_DIR
export PLAYWRIGHT_BASE_URL=http://127.0.0.1:$PORT
export DAV_SERVER_PID_FILE=$PID_FILE
EOF
# shellcheck disable=SC1090
source "$ENV_FILE"

mix ecto.create
mix ecto.migrate
mix run test/playwright/carddav_seed.exs

nohup mix phx.server > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    echo "server up (pid $(cat "$PID_FILE")), env: $ENV_FILE"
    exit 0
  fi
  sleep 1
done
echo "server did not become healthy within 120s; see $LOG_FILE" >&2
exit 1
