#!/usr/bin/env bash
# Uses an already-built production image and the repository's actual Caddyfile.
# All services are disposable local verification containers; nothing is published.
# Usage: scripts/security/pr44_proxy_smoke.sh kith:review [report-directory]
set -euo pipefail

image="${1:?Pass the prebuilt production Docker image}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
report_dir="${2:-$repo_root/tmp/security/pr44-proxy}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
rm -f "$report_dir/proxy-smoke.json" "$report_dir/browser-signup.json"
probe_dir="$repo_root/scripts/security/pr44_proxy"
scratch="$(mktemp -d)"
run_id="pr44-proxy-$(date +%s)-$$"
ingress="$run_id-ingress"
backend="$run_id-backend"
external="$run_id-external"
app="$run_id-app"
caddy="$run_id-caddy"
client="$run_id-client"
postgres="$run_id-db"
containers=()
networks=()

cleanup() {
  docker cp "$app:/tmp/pr44-signup-observations.jsonl" "$report_dir/signup-observations.jsonl" > /dev/null 2>&1 || true
  for ((index=${#containers[@]}-1; index>=0; index--)); do
    container="${containers[$index]}"
    docker logs "$container" > "$report_dir/$container.log" 2>&1 || true
    docker rm -f "$container" > /dev/null 2>&1 || true
  done
  for network in "${networks[@]}"; do docker network rm "$network" > /dev/null 2>&1 || true; done
  rm -rf "$scratch"
}
trap cleanup EXIT

docker image inspect "$image" > "$report_dir/image.json"
python3 - "$scratch" <<'PY'
import base64, pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
password = secrets.token_hex(24)
env = {
    'DATABASE_URL': f'ecto://postgres:{password}@db/kith_proxy_smoke',
    'SECRET_KEY_BASE': secrets.token_urlsafe(64),
    'CLOAK_KEY': base64.b64encode(secrets.token_bytes(32)).decode(),
    'AUTH_TOKEN_SALT': secrets.token_hex(24),
    'METRICS_TOKEN': secrets.token_hex(24),
    'SMTP_HOST': 'localhost', 'SMTP_PORT': '1025',
    'KITH_HOSTNAME': 'localhost', 'POOL_SIZE': '5',
    'KITH_MODE': 'web', 'STORAGE_PATH': '/tmp/uploads',
    'TRUSTED_PROXIES': '172.30.44.2/32',
}
(root / 'app.env').write_text(''.join(f'{key}={value}\n' for key, value in env.items()))
(root / 'postgres.env').write_text(f'POSTGRES_PASSWORD={password}\nPOSTGRES_DB=kith_proxy_smoke\n')
PY
chmod 600 "$scratch"/*.env

# Only app and Caddy join ingress. The extra dual-stack client network is a
# fixture for real IPv4/IPv6 connections to Caddy, not a production network change.
networks+=("$ingress")
docker network create --subnet 172.30.44.0/29 "$ingress" > /dev/null
networks+=("$backend")
docker network create --internal --subnet 172.30.45.0/29 "$backend" > /dev/null
networks+=("$external")
docker network create --ipv6 --subnet 172.30.46.0/29 --subnet fd44:44:44::/64 "$external" > /dev/null

containers+=("$postgres")
docker run -d --name "$postgres" --network "$backend" --ip 172.30.45.2 --network-alias db \
  --env-file "$scratch/postgres.env" --tmpfs /var/lib/postgresql/data postgres:15-alpine > /dev/null
ready=0
for _ in {1..60}; do
  if docker exec "$postgres" pg_isready -U postgres > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[[ "$ready" == 1 ]] || { echo "PostgreSQL did not become ready" >&2; exit 1; }

docker run --rm --network "$backend" --env-file "$scratch/app.env" "$image" eval \
  'Kith.Release.migrate()' > "$report_dir/migrate.log" 2>&1
containers+=("$app")
docker run -d --name "$app" --network "$backend" --ip 172.30.45.3 \
  --env-file "$scratch/app.env" -v "$probe_dir:/tmp/pr44-proxy:ro" "$image" eval \
  'Code.eval_file("/tmp/pr44-proxy/server.ex")' > /dev/null
docker network connect --ip 172.30.44.3 --alias app "$ingress" "$app"

containers+=("$caddy")
docker run -d --name "$caddy" --network "$ingress" --ip 172.30.44.2 \
  -p 127.0.0.1::8080 \
  -e KITH_HOSTNAME=http://:8080 -v "$repo_root/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine > /dev/null
docker network connect --ip 172.30.46.2 --ip6 fd44:44:44::2 "$external" "$caddy"
docker exec "$caddy" caddy version > "$report_dir/caddy-version.log"

containers+=("$client")
docker run -d --name "$client" --network "$external" --ip 172.30.46.3 --ip6 fd44:44:44::3 \
  --entrypoint /bin/sh "$image" -c 'sleep infinity' > /dev/null
docker network connect --ip 172.30.45.4 "$backend" "$client"
ready=0
for _ in {1..60}; do
  if docker exec "$client" curl --noproxy '*' --fail --silent --max-time 1 \
    -H 'Host: localhost' http://172.30.46.2:8080/health/live > /dev/null; then ready=1; break; fi
  sleep 0.5
done
[[ "$ready" == 1 ]] || { echo "Caddy/Kith fixture did not become ready" >&2; exit 1; }

docker network inspect "$ingress" > "$report_dir/ingress.json"
python3 - "$report_dir/ingress.json" "$app" "$caddy" <<'PY'
import json, sys
network = json.load(open(sys.argv[1]))[0]
assert sorted(node['Name'] for node in network['Containers'].values()) == sorted(sys.argv[2:])
PY

request() {
  local id="$1" address="$2" path="$3"
  shift 3
  docker exec "$client" curl --noproxy '*' --silent --show-error --max-time 10 --include \
    -H 'Host: localhost' -H "X-Pr44-Probe-ID: $id" "$@" "$address$path" > "$report_dir/$id.http"
}
assert_response() {
  python3 "$probe_dir/assert_response.py" "$report_dir/$1.http" "$2" "$3" "$4"
}

request caddy-ipv4 http://172.30.46.2:8080 /health/live \
  -H 'X-Forwarded-For: 198.51.100.77, 203.0.113.77' -H 'X-Kith-Client-IP: 192.0.2.77'
assert_response caddy-ipv4 172.30.46.3 172.30.44.2 200
request caddy-ipv6 'http://[fd44:44:44::2]:8080' /health/live \
  -H 'X-Forwarded-For: 198.51.100.77' -H 'X-Kith-Client-IP: 192.0.2.77'
assert_response caddy-ipv6 fd44:44:44::3 172.30.44.2 200
request direct-untrusted http://172.30.45.3:4000 /health/live \
  -H 'X-Forwarded-For: 198.51.100.77' -H 'X-Kith-Client-IP: 192.0.2.77'
assert_response direct-untrusted 172.30.45.4 172.30.45.4 200
request log-redaction http://172.30.46.2:8080 \
  '/health/live?token=pr44-proxy-query-secret&_csrf_token=pr44-proxy-csrf-secret&anything=pr44-proxy-extra-query-secret' \
  -H 'X-Kith-Client-IP: pr44-proxy-forwarded-secret' \
  -H 'Forwarded: for=pr44-proxy-forwarded-chain-secret' \
  -H 'Referer: https://example.test/?token=pr44-proxy-referrer-secret'
assert_response log-redaction 172.30.46.3 172.30.44.2 200

# A malformed value emitted by the trusted peer must also fail closed.
docker exec "$caddy" wget -S -O /dev/null --header='Host: localhost' \
  --header='X-Pr44-Probe-ID: trusted-malformed' \
  --header='X-Kith-Client-IP: 203.0.113.8,198.51.100.8' \
  http://app:4000/health/live > "$report_dir/trusted-malformed.http" 2>&1
assert_response trusted-malformed 172.30.44.2 172.30.44.2 200

# Avoid crossing a legitimate fixed-window boundary during the forgery test.
python3 - <<'PY'
import time
remaining = 60 - time.time() % 60
if remaining < 10:
    time.sleep(remaining + 0.1)
PY
for index in {1..21}; do
  request "api-throttle-$index" http://172.30.46.2:8080 /api/auth/token \
    -H 'Content-Type: application/json' -H "X-Forwarded-For: 198.51.100.$index" \
    -H "X-Kith-Client-IP: 192.0.2.$index" --data '{}'
  expected=400
  if [[ "$index" == 21 ]]; then expected=429; fi
  assert_response "api-throttle-$index" 172.30.46.3 172.30.44.2 "$expected"
done

# The browser uses only a loopback-published ephemeral Caddy port. Its Origin
# host matches the production endpoint's configured localhost host; checks stay on.
browser_port="$(docker port "$caddy" 8080/tcp | sed -n 's/^127\.0\.0\.1://p')"
[[ -n "$browser_port" ]] || { echo "Caddy has no loopback-only browser port" >&2; exit 1; }
PR44_PROXY_BROWSER_URL="http://localhost:$browser_port" \
PR44_PROXY_REPORT_DIRECTORY="$report_dir" \
  node "$probe_dir/browser.mjs" > "$report_dir/browser.log" 2>&1
docker cp "$app:/tmp/pr44-signup-observations.jsonl" "$report_dir/signup-observations.jsonl" > /dev/null
docker exec "$postgres" psql -U postgres -d kith_proxy_smoke -Atc 'SELECT count(*) FROM users' \
  > "$report_dir/user-count.log"

# Proxy failures use Caddy's runtime error logger as well as its access logger.
# Both must redact the synthetic query/header secrets when the upstream is down.
docker stop --time 2 "$app" > /dev/null
request log-redaction-outage http://172.30.46.2:8080 \
  '/health/live?token=pr44-proxy-outage-query-secret' \
  -H 'X-Kith-Client-IP: pr44-proxy-outage-forwarded-secret' \
  -H 'Referer: https://example.test/?token=pr44-proxy-outage-referrer-secret'
python3 - "$report_dir/log-redaction-outage.http" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert int(next(line for line in lines if line.startswith('HTTP/')).split()[1]) == 502
PY

docker logs "$app" > "$report_dir/app.log" 2>&1
docker logs "$caddy" > "$report_dir/caddy-access.log" 2>&1
python3 - "$report_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
observations = {}
for line in (root / 'app.log').read_text().splitlines():
    try:
        event = json.loads(line)
    except (ValueError, TypeError):
        continue
    message = event.get('message', '')
    if isinstance(message, str) and message.startswith('pr44_proxy_identity:'):
        observations[message.split(':', 1)[1]] = event.get('metadata', {}).get('client_ip')
probes = []
probe_ids = ['caddy-ipv4', 'caddy-ipv6', 'direct-untrusted', 'trusted-malformed', 'log-redaction']
probe_ids += [f'api-throttle-{index}' for index in range(1, 22)]
for probe_id in probe_ids:
    path = root / f'{probe_id}.http'
    result = json.loads(path.with_suffix('.json').read_text())
    assert observations.get(result['probe']) == result['client'], (result, observations)
    probes.append(result)

browser = json.loads((root / 'browser-signup.json').read_text())
socket_observations = [json.loads(line) for line in (root / 'signup-observations.jsonl').read_text().splitlines()]
mounts = [event for event in socket_observations if event['kind'] == 'websocket_signup_mount']
saves = [event for event in socket_observations if event['kind'] == 'websocket_signup_save' and event['email'] == browser['email']]
assert mounts, 'No actual connected signup mount was observed'
for mount in mounts:
    assert mount['connected'] is True
    assert mount['socket_peer'] == '172.30.44.2', mount
    assert mount['canonical_header_values'] == [browser['verified_client']], mount
    assert mount['signup_peer'] == browser['verified_client'], mount
assert len(saves) == 6, saves
assert [event['counter'] for event in saves] == list(range(1, 7)), saves
assert all(event['connected'] and event['signup_peer'] == browser['verified_client'] and not event['user_exists'] for event in saves)
assert (root / 'user-count.log').read_text().strip() == '0', 'An invalid signup created a user'
login_posts = [event for event in socket_observations if event['kind'] == 'http_login_post']
assert [event['status'] for event in login_posts] == [302] * 10 + [429], login_posts
assert [event['counter'] for event in login_posts] == list(range(1, 12)), login_posts
assert all(event['client'] == browser['verified_client'] and event['socket_peer'] == '172.30.44.2' for event in login_posts)
for attempt in range(1, 12):
    assert observations.get(f'browser-login-{attempt}') == browser['verified_client']

caddy_access = []
caddy_requests = []
caddy_output = (root / 'caddy-access.log').read_text()
for line in caddy_output.splitlines():
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if 'request' not in event:
        continue
    request = event['request']
    assert '?' not in request['uri'], event
    assert 'headers' not in request and 'resp_headers' not in event, event
    assert request.get('remote_ip') and request.get('client_ip'), event
    caddy_requests.append(event)
    if str(event.get('logger', '')).startswith('http.log.access'):
        assert event.get('status'), event
        caddy_access.append(event)
assert any(event['request']['uri'] == '/live/websocket' and event['status'] == 101 for event in caddy_access)
assert any(event['request']['uri'] == '/users/log-in' and event['status'] == 429 for event in caddy_access)
assert any(event['request']['uri'] == '/health/live' and event.get('status') == 502 for event in caddy_access)
assert any(str(event.get('logger', '')).startswith('http.log.error') and event.get('status') == 502 for event in caddy_requests)
for marker in ['pr44-proxy-query-secret', 'pr44-proxy-csrf-secret', 'pr44-proxy-extra-query-secret',
               'pr44-proxy-forwarded-secret', 'pr44-proxy-forwarded-chain-secret', 'pr44-proxy-referrer-secret',
               'pr44-proxy-outage-query-secret', 'pr44-proxy-outage-forwarded-secret', 'pr44-proxy-outage-referrer-secret']:
    assert marker not in caddy_output, marker
(root / 'proxy-smoke.json').write_text(json.dumps({
    'status': 'passed',
    'checks': 'actual Caddy overwrite, IPv4/IPv6 peers, direct untrusted peer, malformed trusted header, API/login budgets, actual browser WebSocket signup budget and transported identity, request log identity',
    'observations': probes,
    'browser': browser,
    'socket_observations': socket_observations,
    'users_created': 0,
    'caddy_access_logs_redacted': True,
    'caddy_upstream_failure_logs_redacted': True,
    'caddy_access_log_observations': len(caddy_access),
}, indent=2) + '\n')
print(f'PASS: {len(probes)} HTTP proxy observations; real WebSocket signup and HTTP login/API forgery budgets enforced')
PY
