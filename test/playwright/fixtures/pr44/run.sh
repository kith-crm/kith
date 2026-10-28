#!/usr/bin/env bash
# Run the same isolated local fixtures in CI and on a developer machine.
set -euo pipefail
cd "$(dirname "$0")/../../../.."

export MIX_ENV=test PR44_E2E=1 REVIEW_S3=1
export MIX_TEST_PARTITION="${MIX_TEST_PARTITION:-pr44_browser_$(date +%s)_$$}"
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"
export PORT="${PORT:-4000}"
export PR44_S3_PORT="${PR44_S3_PORT:-9000}"
export PLAYWRIGHT_BASE_URL="http://127.0.0.1:$PORT"
export PR44_MONICA_URL="http://127.0.0.1:${PR44_MONICA_PORT:-8094}"
export MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:8025}"
export PR44_FIXTURE_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"

mkdir -p tmp/pr44-browser
log_dir="$PWD/tmp/pr44-browser"
s3_data="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$s3_data"
}
trap cleanup EXIT

# A preflight bind catches occupied ports. Readiness also verifies owned
# processes and a per-run HTTP identity, since the bind alone has a race.
python3 - "$PORT" "$PR44_S3_PORT" "${PR44_MONICA_PORT:-8094}" <<'PY'
import socket, sys
for port in sys.argv[1:]:
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", int(port)))
PY
curl --fail --silent "$MAILPIT_URL/api/v1/info" > /dev/null

python3 test/playwright/fixtures/pr44/monica.py --port "${PR44_MONICA_PORT:-8094}" > "$log_dir/monica.log" 2>&1 &
pids+=("$!")
python3 test/playwright/fixtures/s3/fake_s3.py "$log_dir/s3-requests.log" "$s3_data" "$PR44_S3_PORT" > "$log_dir/s3.log" 2>&1 &
pids+=("$!")

mix ecto.create
mix ecto.migrate
mix run --no-start -e 'Code.require_file("test/playwright/fixtures/pr44/boot.exs"); Code.require_file("priv/repo/seeds.exs")' > "$log_dir/seeds.log" 2>&1
mix run --no-start test/playwright/fixtures/pr44/server.exs > "$log_dir/phoenix.log" 2>&1 &
pids+=("$!")

ready=0
for _ in {1..150}; do
  for pid in "${pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then cat "$log_dir/phoenix.log" "$log_dir/monica.log" "$log_dir/s3.log"; exit 1; fi
  done
  if curl --fail --silent "$PLAYWRIGHT_BASE_URL/health" > /dev/null && \
     python3 - <<'PY'
import json, os, urllib.request
try:
    for url in [os.environ['PR44_MONICA_URL'], 'http://127.0.0.1:' + os.environ['PR44_S3_PORT']]:
        req = urllib.request.Request(url + '/__pr44_fixture__', headers={'Authorization': 'Bearer pr44-fixture-token'})
        with urllib.request.urlopen(req, timeout=1) as response:
            assert json.load(response)['run'] == os.environ['PR44_FIXTURE_TOKEN']
except Exception:
    raise SystemExit(1)
PY
  then ready=1; break; fi
  sleep 0.2
done
if [[ "$ready" != 1 ]]; then cat "$log_dir/phoenix.log" "$log_dir/monica.log" "$log_dir/s3.log"; echo "Browser fixtures did not become ready" >&2; exit 1; fi

# The fixtures below are mandatory here, so their specs cannot silently skip.
mix run --no-start -e 'Code.require_file("test/playwright/fixtures/pr44/boot.exs"); Code.require_file("test/playwright/fixtures/s3/seed.exs")' > "$log_dir/image-seed.log" 2>&1
export IMG_SEED_JSON="$(tail -n 1 "$log_dir/image-seed.log")"
node -e 'const s=JSON.parse(process.env.IMG_SEED_JSON); if (!s.photo_contact || !s.email) throw Error("Invalid image fixture")'

# Whole-queue drains require a single worker. Do not parallelize before isolating queues.
npx playwright test --project=e2e --workers=1 \
  test/playwright/pr44-regressions.spec.ts test/playwright/image-fallback.spec.ts
