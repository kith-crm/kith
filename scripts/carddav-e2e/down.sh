#!/usr/bin/env bash
# Stop only the server belonging to this checkout's isolated harness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/.carddav-task10"
[ -f "$STATE/server.pid" ] || { echo "no harness pid file"; exit 0; }
pid="$(cat "$STATE/server.pid")"
expected="$(cat "$STATE/server.command")"
actual="$(ps -o command= -p "$pid" 2>/dev/null || true)"
if [ "$actual" != "$expected" ] || [ -z "$actual" ]; then
  echo "harness pid gone or reused; leaving process untouched"
else
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  [ "$cwd" = "$ROOT" ] || { echo "refusing teardown: pid cwd is $cwd" >&2; exit 1; }
  pkill -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  echo "stopped harness $pid"
fi
rm -f "$STATE/server.pid" "$STATE/server.command"
