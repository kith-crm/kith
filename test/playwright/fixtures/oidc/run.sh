#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
export MIX_ENV=test KITH_OIDC_E2E=1 PLAYWRIGHT_NO_COPY_PROMPT=1
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"
export PORT="${OIDC_PORT:-4149}" ISSUER_PORT="${OIDC_ISSUER_PORT:-4150}"
export PLAYWRIGHT_BASE_URL="https://kith.test:$PORT"
export KITH_TEST_FIXTURE_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export KITH_OIDC_TLS="$(mktemp -d)"
export TMPDIR="$KITH_OIDC_TLS"
export PLAYWRIGHT_OUTPUT_DIR="${PLAYWRIGHT_OUTPUT_DIR:-tmp/oidc-browser/results}"
mkdir -p tmp/oidc-browser
server_pid=""
database_created=0
stop_server() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=""; fi
}
cleanup() {
  stop_server
  if [[ "$database_created" == 1 ]]; then mix ecto.drop > "tmp/oidc-browser/$KITH_OIDC_MODE-drop.log" 2>&1 || true; fi
  rm -rf "$KITH_OIDC_TLS"
}
trap cleanup EXIT
python3 - "$PORT" "$ISSUER_PORT" <<'PY'
import socket, sys
for port in sys.argv[1:]:
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('127.0.0.1', int(port)))
PY
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KITH_OIDC_TLS/ca-key.pem" -out "$KITH_OIDC_TLS/ca.pem" -days 1 -subj '/CN=Kith isolated browser CA' -addext 'basicConstraints=critical,CA:TRUE' > /dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$KITH_OIDC_TLS/key.pem" -out "$KITH_OIDC_TLS/leaf.csr" -subj '/CN=kith.test' > /dev/null 2>&1
cat > "$KITH_OIDC_TLS/leaf.ext" <<'CERT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:kith.test,DNS:issuer.test
CERT
openssl x509 -req -in "$KITH_OIDC_TLS/leaf.csr" -CA "$KITH_OIDC_TLS/ca.pem" -CAkey "$KITH_OIDC_TLS/ca-key.pem" -CAcreateserial -out "$KITH_OIDC_TLS/cert.pem" -days 1 -extfile "$KITH_OIDC_TLS/leaf.ext" > /dev/null 2>&1
export KITH_OIDC_SPKI="$(openssl x509 -in "$KITH_OIDC_TLS/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)"
mix assets.build > tmp/oidc-browser/assets.log 2>&1
mix phx.digest >> tmp/oidc-browser/assets.log 2>&1
for mode in ${OIDC_MODES:-open closed passwordless closed-passwordless}; do
  export KITH_OIDC_MODE="$mode"
  export KITH_OIDC_PASSWORD=true KITH_OIDC_REGISTRATION=true
  if [[ "$mode" == *closed* ]]; then export KITH_OIDC_REGISTRATION=false; fi
  if [[ "$mode" == *passwordless* ]]; then export KITH_OIDC_PASSWORD=false; fi
  export MIX_TEST_PARTITION="oidc_${mode}_$(date +%s)_$$"
  database_created=1
  mix ecto.create > "tmp/oidc-browser/$mode-database.log" 2>&1
  mix ecto.migrate >> "tmp/oidc-browser/$mode-database.log" 2>&1
  mix run --no-start test/playwright/fixtures/oidc/server.exs > "tmp/oidc-browser/$mode-server.log" 2>&1 &
  server_pid=$!
  ready=0
  for _ in {1..150}; do
    kill -0 "$server_pid" 2>/dev/null || { echo 'Owned OIDC fixture exited before readiness' >&2; exit 1; }
    if node <<'JS'
const https = require('node:https'), fs = require('node:fs');
Promise.all([process.env.PORT, process.env.ISSUER_PORT].map(port => new Promise((resolve, reject) => {
 const req = https.get({hostname:'kith.test', port, path:'/__fixture__', ca:fs.readFileSync(process.env.KITH_OIDC_TLS+'/ca.pem'), lookup:(_host,opts,cb)=>opts.all ? cb(null,[{address:'127.0.0.1',family:4}]) : cb(null,'127.0.0.1',4), headers:{Authorization:'Bearer '+process.env.KITH_TEST_FIXTURE_TOKEN}}, res=>{let body='';res.on('data',v=>body+=v);res.on('end',()=>{try {if(res.statusCode!==200||JSON.parse(body).run!==process.env.KITH_TEST_FIXTURE_TOKEN) throw Error();resolve();}catch{reject();}});}); req.on('error',reject);req.setTimeout(1000,()=>req.destroy());
}))).catch(()=>process.exitCode=1);
JS
    then ready=1; break; fi
    sleep 0.2
  done
  [[ "$ready" == 1 ]] || { echo 'Owned distinct-site HTTPS fixtures did not become ready' >&2; exit 1; }
  npx playwright test --project=oidc --workers=1 "$@"
  stop_server
  # Drop only this run's dedicated database, after the owned app is stopped.
  mix ecto.drop > "tmp/oidc-browser/$mode-drop.log" 2>&1
  database_created=0
 done
