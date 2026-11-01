#!/usr/bin/env bash
# Verify a prebuilt production image locally. Does not build, publish or deploy.
# Usage: scripts/security/pr44_release_smoke.sh kith:review [report-directory]
set -euo pipefail

image="${1:?Pass the prebuilt production Docker image}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
report_dir="${2:-$repo_root/tmp/security/pr44-release}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
rm -f "$report_dir/release-smoke.json"
probe_dir="$repo_root/scripts/security/pr44_release"
scratch="$(mktemp -d)"
run_id="pr44-release-$(date +%s)-$$"
network="$run_id"
postgres="$run_id-db"
containers=()

cleanup() {
  for ((index=${#containers[@]}-1; index>=0; index--)); do
    container="${containers[$index]}"
    docker logs "$container" > "$report_dir/$container.log" 2>&1 || true
    docker rm -f "$container" > /dev/null 2>&1 || true
  done
  docker network rm "$network" > /dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

docker image inspect "$image" > "$report_dir/image.json"
python3 - "$scratch" <<'PY'
import base64, pathlib, secrets, sys
root=pathlib.Path(sys.argv[1])
password=secrets.token_hex(24)
env={
 'DATABASE_URL':f'ecto://postgres:{password}@db/kith_release_smoke',
 'SECRET_KEY_BASE':secrets.token_urlsafe(64),
 'CLOAK_KEY':base64.b64encode(secrets.token_bytes(32)).decode(),
 'AUTH_TOKEN_SALT':secrets.token_hex(24),
 'METRICS_TOKEN':secrets.token_hex(24),
 'SMTP_HOST':'localhost', 'SMTP_PORT':'1025',
 'KITH_HOSTNAME':'localhost', 'POOL_SIZE':'5',
}
(root/'release.env').write_text(''.join(f'{key}={value}\n' for key,value in env.items()))
(root/'postgres.env').write_text(f'POSTGRES_PASSWORD={password}\nPOSTGRES_DB=kith_release_smoke\n')
(root/'cluster.env').write_text(
 f'RELEASE_COOKIE={secrets.token_hex(32)}\nRELEASE_DISTRIBUTION=sname\n'
 'KITH_CLUSTER_HOSTS=kith@app,kith@worker\n')
PY
chmod 600 "$scratch"/*.env
docker network create --internal "$network" > /dev/null
containers+=("$postgres")
docker run -d --name "$postgres" --network "$network" --network-alias db \
  --env-file "$scratch/postgres.env" --tmpfs /var/lib/postgresql/data \
  postgres:15-alpine > /dev/null
ready=0
for _ in {1..60}; do
  if docker exec "$postgres" pg_isready -U postgres > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[[ "$ready" == 1 ]] || { echo "PostgreSQL did not become ready" >&2; exit 1; }

release_eval() {
  local report="$1"
  shift
  docker run --rm --network "$network" --env-file "$scratch/release.env" \
    -v "$probe_dir:/tmp/pr44-release:ro" "$@" "$image" eval \
    'Code.eval_file("/tmp/pr44-release/probe.exs")' > "$report_dir/$report.log" 2>&1
}

# Exercise actual packaged migrations in both directions before starting queues.
release_eval oban-roundtrip -e KITH_MODE=migrate -e PR44_RELEASE_PROBE=roundtrip
docker run --rm --network "$network" --env-file "$scratch/release.env" \
  -e KITH_MODE=migrate "$image" eval 'Kith.Release.migrate()' \
  > "$report_dir/migrate.log" 2>&1

for mode in migrate web worker; do
  if docker run --rm --network "$network" --env-file "$scratch/release.env" \
    -e "KITH_MODE=$mode" -e CLOAK_KEY=AA== "$image" eval \
    'Application.ensure_all_started(:kith)' > "$report_dir/invalid-key-$mode.log" 2>&1; then
    echo "Invalid CLOAK_KEY unexpectedly booted $mode" >&2
    exit 1
  fi
  rg -q 'CLOAK_KEY must' "$report_dir/invalid-key-$mode.log"
done

web="$run_id-web"
containers+=("$web")
docker run -d --name "$web" --hostname app --network "$network" --network-alias app \
  --env-file "$scratch/release.env" --env-file "$scratch/cluster.env" -e RELEASE_NODE=kith@app \
  -v "$probe_dir:/tmp/pr44-release:ro" -e KITH_MODE=web -e PHX_SERVER=true \
  -e SENTRY_DSN= -e PR44_RELEASE_PROBE=web "$image" > /dev/null
ready=0
for _ in {1..60}; do
  if docker exec "$web" curl --max-time 2 --fail --silent http://localhost:4000/health/ready \
    > "$report_dir/health.json" 2>/dev/null; then ready=1; break; fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$web")" == true ]] || break
  sleep 0.5
done
[[ "$ready" == 1 ]] || { echo "Web release did not become ready" >&2; exit 1; }
docker exec "$web" timeout 30 /app/bin/kith rpc 'Code.eval_file("/tmp/pr44-release/probe.exs")' \
  > "$report_dir/web-probe.log" 2>&1
docker exec "$web" sh -c 'test -s /app/lib/kith-*/priv/static/cache_manifest.json && test -n "$(find /app/lib/kith-*/priv/static/assets -type f -name "*.js" -print -quit)"' \
  > "$report_dir/assets.log" 2>&1
docker exec "$web" curl --max-time 10 --fail --silent http://localhost:4000/assets/js/app.js \
  > "$report_dir/browser-app.js"
test -s "$report_dir/browser-app.js"
metrics_status="$(docker exec "$web" curl --max-time 5 --silent -o /dev/null -w '%{http_code}' http://localhost:4000/metrics)"
[[ "$metrics_status" == 401 ]]
docker exec "$web" sh -c \
  'exec curl --max-time 10 --fail --silent -H "Authorization: Bearer $METRICS_TOKEN" http://localhost:4000/metrics' \
  > "$report_dir/metrics.prom"
test -s "$report_dir/metrics.prom"
# This peer is deliberately outside the ingress allowlist. Both forged header
# families must leave the HTTP logger's identity equal to the loopback socket.
docker exec "$web" curl --max-time 5 --fail --silent \
  -H 'x-request-id: pr44-client-ip-direct' -H 'x-forwarded-for: 198.51.100.77' \
  -H 'x-kith-client-ip: 203.0.113.9' http://127.0.0.1:4000/health/live \
  > "$report_dir/client-ip-health.json"

worker="$run_id-worker"
containers+=("$worker")
docker run -d --name "$worker" --hostname worker --network "$network" --network-alias worker \
  --env-file "$scratch/release.env" --env-file "$scratch/cluster.env" -e RELEASE_NODE=kith@worker \
  -v "$probe_dir:/tmp/pr44-release:ro" -e KITH_MODE=worker -e PR44_RELEASE_PROBE=worker \
  "$image" > /dev/null
ready=0
for _ in {1..60}; do
  if docker exec "$worker" timeout 3 /app/bin/kith rpc \
    'true = is_pid(Process.whereis(Kith.Repo)); true = is_pid(Oban.whereis(Oban))' \
    > /dev/null 2>&1; then ready=1; break; fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$worker")" == true ]] || break
  sleep 0.5
done
[[ "$ready" == 1 ]] || { echo "Worker release did not become ready" >&2; exit 1; }
docker exec "$worker" timeout 30 /app/bin/kith rpc 'Code.eval_file("/tmp/pr44-release/probe.exs")' \
  > "$report_dir/worker-probe.log" 2>&1
connected=0
for _ in {1..30}; do
  if docker exec "$web" timeout 3 /app/bin/kith rpc \
    'true = :"kith@worker" in Node.list()' > /dev/null 2>&1; then connected=1; break; fi
  sleep 0.5
done
[[ "$connected" == 1 ]] || { echo "App/worker cluster did not connect" >&2; exit 1; }
docker exec "$web" timeout 60 /app/bin/kith rpc 'PR44ReleaseSmoke.run("cache_cluster")' \
  > "$report_dir/cache-cluster-probe.log" 2>&1

# Each eval starts the actual dependency/application tree; unset, empty and
# whitespace-only DSNs must all disable reporting. Valid DSNs retain transport.
for value in unset empty whitespace enabled; do
  sentry_options=(-e KITH_MODE=web)
  case "$value" in
    empty) sentry_options+=(-e SENTRY_DSN=);;
    whitespace) sentry_options+=(-e 'SENTRY_DSN=   ');;
    enabled) sentry_options+=(-e SENTRY_DSN=http://public@127.0.0.1:9999/1);;
  esac
  probe=web
  [[ "$value" != enabled ]] || probe=enabled
  docker run --rm --network "$network" --env-file "$scratch/release.env" \
    -v "$probe_dir:/tmp/pr44-release:ro" -e KITH_MODE=web -e "PR44_RELEASE_PROBE=$probe" \
    "${sentry_options[@]}" "$image" eval \
    '{:ok, _} = Application.ensure_all_started(:kith); Code.eval_file("/tmp/pr44-release/probe.exs")' \
    > "$report_dir/sentry-$value.log" 2>&1
done

docker logs "$web" > "$report_dir/web.log" 2>&1
docker logs "$worker" > "$report_dir/worker.log" 2>&1
python3 - "$report_dir" <<'PY'
import datetime,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
health=json.loads((root/'health.json').read_text())
assert health == {'status':'ok','db':'connected','migrations':'current'},health
logs=['oban-roundtrip','migrate','web','worker']
logs += [f'sentry-{mode}' for mode in ['unset','empty','whitespace','enabled']]
for name in logs:
    lines=[line for line in (root/f'{name}.log').read_text().splitlines() if line.strip()]
    assert lines, f'No output from {name}'
    parsed=[json.loads(line) for line in lines]
    assert 'pr44-do-not-log-credential' not in '\n'.join(lines), f'Credential leaked in {name}'
    for item in parsed:
        if 'message' in item:
            assert any(field in item for field in ['time','timestamp']),item
            assert any(field in item for field in ['severity','level']),item
for name in ['web-probe','worker-probe','cache-cluster-probe']:
    # RPC can forward ordinary logs to its CLI formatter. Check secret safety
    # here; JSON formatting is asserted on the real node consoles above.
    assert 'pr44-do-not-log-credential' not in (root/f'{name}.log').read_text()
for name,mode in [('web-probe','web'),('worker-probe','worker')]:
    entries=[json.loads(line) for line in (root/f'{name}.log').read_text().splitlines() if line.startswith('{')]
    totp=next(item for item in entries if item.get('pr44_release_check') == 'totp')
    assert totp['mode']==mode and all(totp[key] is True for key in ['otp_reference','malformed_rejected','limits']),totp
for name in ['web','worker']:
    entries=[json.loads(line) for line in (root/f'{name}.log').read_text().splitlines() if line.strip()]
    marker=next(item for item in entries if item.get('message') == f'PR44_RELEASE_LOG {name}')
    assert marker['metadata']['account_id'] == 44, marker
    assert marker['metadata']['request_id'] == 'pr44-smoke', marker
web_entries=[json.loads(line) for line in (root/'web.log').read_text().splitlines() if line.strip()]
http_entries=[item for item in web_entries if item.get('metadata',{}).get('request_id') == 'pr44-client-ip-direct']
assert http_entries, 'Missing actual HTTP client identity log'
assert all(item['metadata']['client_ip'] == '127.0.0.1' for item in http_entries), http_entries
cluster_entries=[json.loads(line) for line in (root/'cache-cluster-probe.log').read_text().splitlines() if line.startswith('{')]
cluster=next(item for item in cluster_entries if item.get('pr44_release_check') == 'connected_cache')
assert cluster['status'] == 'passed' and cluster['nodes'] == ['kith@app','kith@worker'],cluster
image=json.loads((root/'image.json').read_text())[0]
checks={
 'status':'passed','scope':'local prebuilt production image',
 'generated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'image_id':image['Id'],'platform':image['Os']+'/'+image['Architecture'],
 'modes':['migrate','web','worker'], 'sentry':['unset','empty','whitespace','enabled'],
 'oban_versions':[12,14,12,14], 'credentials':['legacy-read-both-columns','new-writes-both-columns','document-job-empty-workload','pending-key-retention','cancellation-key-release'],
 'metrics':['unauthenticated-401','authenticated-scrape'],
 'cache':['app-worker-store-put-get-ttl','connected-node-symmetric-invalidation','worker-photo-document-write-invalidates-web-usage','worker-duplicate-dismissal-invalidates-web-count'],
 'client_ip':['actual-http-forged-headers-ignored','json-logger-uses-socket-identity'],
 'totp':['independent-OTP-crypto-reference','malformed-values-fail-closed','account-and-IP-budgets-in-web-and-worker'],
 'limits':['No external provider API calls','No nonempty document downloads','Cold build is a separate coordinator check','Connected-node invalidation only; disconnected entries rely on bounded TTL'],
}
(root/'release-smoke.json').write_text(json.dumps(checks,indent=2)+'\n')
print('Production release smoke checks passed; report: '+str(root/'release-smoke.json'))
PY
