#!/usr/bin/env bash
# Real-client smoke: vdirsyncer <-> Kith CardDAV (account B, dav-other).
# Usage: source /tmp/kith-carddav-e2e.env && scripts/carddav-e2e/vdirsyncer-smoke.sh
# Needs network access for `pip install vdirsyncer`. Exits non-zero on any mismatch.
set -euo pipefail

BASE="${PLAYWRIGHT_BASE_URL:-http://127.0.0.1:4517}"
USER_EMAIL="dav-other@carddav.test"
PASSWORD="${DAV_PASSWORD:-ValidP@ssword123!}"
RUN="vds-$(date +%s)"

umask 077
D="$(mktemp -d)"

# curl config keeps the password out of argv and logs
printf 'user = "%s:%s"\n' "$USER_EMAIL" "$PASSWORD" >"$D/curl.cfg"
dcurl() { curl -sS -K "$D/curl.cfg" "$@"; }

server_hrefs() {
  dcurl -X PROPFIND -H 'Depth: 1' -H 'Content-Type: application/xml' \
    "$BASE/dav/addressbooks/default/" |
    grep -o '<d:href>[^<]*\.vcf</d:href>' | sed -e 's/<d:href>//' -e 's/<\/d:href>//'
}

cleanup() {
  # remove everything this run left on the server (by FN prefix)
  for h in $(server_hrefs 2>/dev/null || true); do
    if dcurl "$BASE$h" 2>/dev/null | tr -d '\r' | grep -q "^FN:.*$RUN"; then
      dcurl -o /dev/null -X DELETE "$BASE$h" || true
    fi
  done
  rm -r -f "$D"
}
trap cleanup EXIT

step() { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# "UID|FN" lines for cards of this run, from the server
server_state() {
  for h in $(server_hrefs); do
    dcurl "$BASE$h" | tr -d '\r' | awk -v r="$RUN" '
      /^UID:/ {u=substr($0,5)} /^FN:/ {f=substr($0,4)}
      END { if (f ~ r) print u "|" f }'
  done | sort
}

local_state() {
  for f in "$LOCAL"/*.vcf; do
    [ -e "$f" ] || continue
    tr -d '\r' <"$f" | awk -v r="$RUN" '
      /^UID:/ {u=substr($0,5)} /^FN:/ {f=substr($0,4)}
      END { if (f ~ r) print u "|" f }'
  done | sort
}

assert_agree() {
  local label="$1"
  server_state >"$D/server.txt"
  local_state >"$D/local.txt"
  if diff -u "$D/server.txt" "$D/local.txt"; then
    echo "PASS: $label (server and local agree: $(wc -l <"$D/server.txt" | tr -d ' ') run cards)"
  else
    fail "$label"
  fi
}

card() { # uid fn
  printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:%s\r\nFN:%s\r\nN:%s;;;;\r\nEND:VCARD\r\n' "$1" "$2" "$2"
}

put_status() { # href file -> http status
  dcurl -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: text/vcard' \
    --data-binary @"$2" "$BASE/dav/addressbooks/default/$1"
}

step "install vdirsyncer"
python3 -m venv "$D/venv"
"$D/venv/bin/python" -I -m pip install -q vdirsyncer
VDS="$D/venv/bin/vdirsyncer"

step "seed server with 2 cards over DAV"
card "$RUN-a" "$RUN Alpha" >"$D/a.vcf"
card "$RUN-b" "$RUN Bravo" >"$D/b.vcf"
for n in a b; do
  s="$(put_status "$RUN-$n.vcf" "$D/$n.vcf")"
  [[ "$s" =~ ^(201|204)$ ]] || fail "seed PUT $n -> $s"
done

mkdir -p "$D/status" "$D/local"
cat >"$D/config" <<CFG
[general]
status_path = "$D/status"

[pair kith]
a = "local"
b = "remote"
collections = ["from b"]
conflict_resolution = "a wins"

[storage local]
type = "filesystem"
path = "$D/local"
fileext = ".vcf"

[storage remote]
type = "carddav"
url = "$BASE/dav/"
username = "$USER_EMAIL"
password.fetch = ["command", "printenv", "VDS_PW"]
CFG
export VDS_PW="$PASSWORD"
export VDIRSYNCER_CONFIG="$D/config"

step "1. discover + sync"
"$VDS" discover kith <<<"y"
"$VDS" sync kith
LOCAL="$(find "$D/local" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$LOCAL" ] || fail "no local collection directory"
assert_agree "1 initial sync"

step "2. local edit, local add (UUID filename), local delete"
A="$(grep -l "^UID:$RUN-a" "$LOCAL"/*.vcf | head -1)"
B="$(grep -l "^UID:$RUN-b" "$LOCAL"/*.vcf | head -1)"
[ -n "$A" ] && [ -n "$B" ] || fail "seeded cards not synced down"
sed -i.bak "s/^FN:.*/FN:$RUN Alpha Edited/" "$A" && rm -f "$A.bak"
NEWUUID="$(python3 -c 'import uuid;print(uuid.uuid4())')"
card "$NEWUUID" "$RUN Charlie" >"$LOCAL/$NEWUUID.vcf"
rm -f "$B"
"$VDS" sync kith
assert_agree "2 local edit/add/delete"

step "3. server-side change (curl PUT) then sync"
card "$RUN-a" "$RUN Alpha ServerEdit" >"$D/a2.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a2.vcf")"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "server PUT -> $s"
"$VDS" sync kith
assert_agree "3 server edit"

step "4. conflicting edit on both sides, a wins"
A="$(grep -l "^UID:$RUN-a" "$LOCAL"/*.vcf | head -1)"
sed -i.bak "s/^FN:.*/FN:$RUN Alpha LocalWins/" "$A" && rm -f "$A.bak"
card "$RUN-a" "$RUN Alpha ServerLoses" >"$D/a3.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a3.vcf")"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "conflict server PUT -> $s"
"$VDS" sync kith
assert_agree "4 conflict"
grep -q "^$RUN-a|$RUN Alpha LocalWins\$" "$D/server.txt" || fail "4 conflict: local edit did not win"

echo "ALL STEPS PASSED"
