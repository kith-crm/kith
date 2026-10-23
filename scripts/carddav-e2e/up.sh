#!/usr/bin/env bash
# Start an isolated Kith dev server for CardDAV live tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

STATE="$ROOT/.carddav-task10"
mkdir -p "$STATE"
ENV_FILE="$STATE/env"
PID_FILE="$STATE/server.pid"
LOG_FILE="$STATE/server.log"
PORT=4527
DB_NAME=kith_carddav_task10_e2e

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

# Each invocation creates fresh isolated storage and database state.
STORAGE_PATH="$(mktemp -d "$STATE/storage.XXXXXX")"
PLAYWRIGHT_OUTPUT_DIR="$STATE/results"
mkdir -p "$PLAYWRIGHT_OUTPUT_DIR"
trap '"$ROOT/scripts/carddav-e2e/down.sh"' ERR

{
  printf 'export MIX_ENV=dev\n'
  printf 'export DB_NAME=%q\n' "$DB_NAME"
  printf 'export PORT=%q\n' "$PORT"
  printf 'export STORAGE_PATH=%q\n' "$STORAGE_PATH"
  printf 'export PLAYWRIGHT_OUTPUT_DIR=%q\n' "$PLAYWRIGHT_OUTPUT_DIR"
  printf 'export PLAYWRIGHT_BASE_URL=%q\n' "http://127.0.0.1:$PORT"
  printf 'export DAV_SERVER_PID_FILE=%q\n' "$PID_FILE"
} > "$ENV_FILE"
if [ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" ]; then
  printf 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE=%q\n' "$PLAYWRIGHT_CHROMIUM_EXECUTABLE" >> "$ENV_FILE"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

mix ecto.drop --quiet
mix ecto.create
mix ecto.migrate
PERF=1 mix run test/playwright/carddav_seed.exs

# Build browser assets; ad-hoc sign the downloaded Tailwind binary on macOS.
build_assets() {
  mix assets.vendor || return 1
  mix tailwind.install --if-missing || return 1
  for bin in _build/tailwind-*; do
    if [ "$(uname)" = Darwin ] && ! codesign -v "$bin" > /dev/null 2>&1; then
      codesign --force --sign - "$bin" || return 1
    fi
  done
  mix assets.build
}
build_assets

nohup mix phx.server > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
sleep 1
ps -o command= -p "$(cat "$PID_FILE")" > "$STATE/server.command"

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then
    echo "server up (pid $(cat "$PID_FILE")), env: $ENV_FILE"
    exit 0
  fi
  sleep 1
done
echo "server did not become healthy within 120s; see $LOG_FILE" >&2
"$ROOT/scripts/carddav-e2e/down.sh"
exit 1
