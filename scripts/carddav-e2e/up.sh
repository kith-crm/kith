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

# Reuse only the temp dirs from a previous env file (never DB_NAME/PORT),
# so the guard above always applies to the values actually used.
STORAGE_PATH=""
PLAYWRIGHT_OUTPUT_DIR=""
if [ -f "$ENV_FILE" ]; then
  STORAGE_PATH="$(sed -n 's/^export STORAGE_PATH=//p' "$ENV_FILE")"
  PLAYWRIGHT_OUTPUT_DIR="$(sed -n 's/^export PLAYWRIGHT_OUTPUT_DIR=//p' "$ENV_FILE")"
fi
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
if [ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" ]; then
  printf 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE=%q\n' "$PLAYWRIGHT_CHROMIUM_EXECUTABLE" >> "$ENV_FILE"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

mix ecto.create
mix ecto.migrate
mix run test/playwright/carddav_seed.exs

# The browser specs need the compiled CSS; the DAV-only specs do not, so a
# failed asset build only warns. On recent macOS the downloaded tailwind binary
# can carry a signature the kernel rejects (SIGKILL, exit 137); an ad-hoc
# signature makes it runnable without changing the pinned version.
# `assets/vendor/heroicons.js` is gitignored; `mix assets.vendor` (part of
# `mix setup`) generates it from deps/heroicons without network access.
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
if ! build_assets; then
  echo "WARN: asset build failed; /assets/css/app.css will 404 and browser specs may fail." >&2
  if [ ! -f assets/vendor/heroicons.js ]; then
    echo "WARN: assets/vendor/heroicons.js is missing; generate it with 'mix assets.vendor' (needs deps/heroicons from 'mix deps.get'), then 'mix assets.build'." >&2
  fi
fi

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
