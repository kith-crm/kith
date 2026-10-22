#!/usr/bin/env bash
# Stop the CardDAV live-test server started by up.sh (only the pid we recorded).
PID_FILE=/tmp/kith-carddav-e2e.pid
[ -f "$PID_FILE" ] || { echo "no pid file"; exit 0; }
pid="$(cat "$PID_FILE")"
# Guard against a stale pid that was reused by an unrelated process.
cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
case "$cmd" in
  *beam* | *mix* | *phx.server*) ;;
  *)
    echo "pid $pid is not a beam/mix process (${cmd:-gone}); not killing" >&2
    rm -f "$PID_FILE"
    exit 0
    ;;
esac
# Kill children (the BEAM) first, then the wrapper.
pkill -P "$pid" 2>/dev/null || true
kill "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "stopped $pid"
