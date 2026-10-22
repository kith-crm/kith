#!/usr/bin/env bash
# Real-client smoke: vdirsyncer <-> Kith CardDAV (account B, dav-other).
# Usage: source /tmp/kith-carddav-e2e.env && scripts/carddav-e2e/vdirsyncer-smoke.sh
# Needs network access for `pip install vdirsyncer`. Exits non-zero on any mismatch.
# Every HTTP call uses `curl -f`, so a 401, 5xx or connection failure aborts the run
# instead of yielding an empty (and "agreeing") state.
set -euo pipefail

BASE="${PLAYWRIGHT_BASE_URL:-http://127.0.0.1:4517}"
USER_EMAIL="dav-other@carddav.test"
PASSWORD="${DAV_PASSWORD:-ValidP@ssword123!}"
RUN="vds-$(date +%s)"
BOOK="$BASE/dav/addressbooks/default/"

umask 077
D="$(mktemp -d)"

# curl config keeps the password out of argv and logs
printf 'user = "%s:%s"\n' "$USER_EMAIL" "$PASSWORD" >"$D/curl.cfg"
dcurl() { curl -sS -f -K "$D/curl.cfg" "$@"; }

step() { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# hrefs of all cards in the book; fails on any non-2xx. Never call inside `$(...)`
# without `|| fail`: set -e does not apply there.
list_hrefs() { # outfile
  local xml
  xml="$(dcurl -X PROPFIND -H 'Depth: 1' -H 'Content-Type: application/xml' "$BOOK")" || return 1
  { grep -o '<d:href>[^<]*\.vcf</d:href>' <<<"$xml" || true; } |
    sed -e 's/<d:href>//' -e 's/<\/d:href>//' >"$1"
}

cleanup() {
  # DAV DELETE only moves a contact to Kith's 30-day trash (soft delete); the
  # run's cards stay in the trash until purged, but are gone from DAV.
  if list_hrefs "$D/cleanup-hrefs" 2>/dev/null; then
    while read -r h; do
      if dcurl "$BASE$h" 2>/dev/null | tr -d '\r' | grep -q "^FN:.*$RUN"; then
        dcurl -o /dev/null -X DELETE "$BASE$h" || true
      fi
    done <"$D/cleanup-hrefs"
  fi
  rm -r -f "$D"
}
trap cleanup EXIT

# print "UID|FN" for a vCard on stdin if its FN carries the run prefix
card_key() {
  tr -d '\r' | awk -v r="$RUN" '
    /^UID:/ {u=substr($0,5)} /^FN:/ {f=substr($0,4)}
    END { if (f ~ r) print u "|" f }'
}

server_state() { # outfile
  list_hrefs "$D/hrefs" || fail "server listing failed"
  [ -s "$D/hrefs" ] || fail "server listing is empty (the book always holds this run's cards)"
  : >"$1.unsorted"
  local h body
  while read -r h; do
    body="$(dcurl "$BASE$h")" || fail "GET $h failed"
    card_key <<<"$body" >>"$1.unsorted"
  done <"$D/hrefs"
  sort "$1.unsorted" >"$1"
}

local_state() { # outfile
  : >"$1.unsorted"
  local f
  for f in "$LOCAL"/*.vcf; do
    [ -e "$f" ] || continue
    card_key <"$f" >>"$1.unsorted"
  done
  sort "$1.unsorted" >"$1"
}

assert_agree() { # label expected_count
  local label="$1" expected="$2" n
  server_state "$D/server.txt"
  local_state "$D/local.txt"
  diff -u "$D/server.txt" "$D/local.txt" || fail "$label: server and local differ"
  n="$(wc -l <"$D/server.txt" | tr -d ' ')"
  [ "$n" = "$expected" ] || fail "$label: expected $expected run cards, found $n"
  echo "PASS: $label (server and local agree: $n run cards)"
}

expect_line() { # file line label
  grep -qxF -- "$2" "$1" || fail "$3: missing '$2' in $(basename "$1")"
}
expect_no_match() { # file pattern label
  if grep -q -- "$2" "$1"; then fail "$3: unexpected '$2' in $(basename "$1")"; fi
}

card() { # uid fn
  printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:%s\r\nFN:%s\r\nN:%s;;;;\r\nEND:VCARD\r\n' "$1" "$2" "$2"
}

put_status() { # href file -> http status (no -f: the status is inspected)
  curl -sS -K "$D/curl.cfg" -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: text/vcard' \
    --data-binary @"$2" "$BOOK$1"
}

step "install vdirsyncer"
python3 -I -m venv "$D/venv"
"$D/venv/bin/python" -I -m pip install -q vdirsyncer
VDS="$D/venv/bin/vdirsyncer"

step "seed server with 2 cards over DAV"
card "$RUN-a" "$RUN Alpha" >"$D/a.vcf"
card "$RUN-b" "$RUN Bravo" >"$D/b.vcf"
for n in a b; do
  s="$(put_status "$RUN-$n.vcf" "$D/$n.vcf")" || fail "seed PUT $n failed"
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
assert_agree "1 initial sync" 2
expect_line "$D/local.txt" "$RUN-a|$RUN Alpha" "1"
expect_line "$D/local.txt" "$RUN-b|$RUN Bravo" "1"

step "2. local edit, local add (UUID filename), local delete"
A="$(grep -l "^UID:$RUN-a" "$LOCAL"/*.vcf | head -1)"
B="$(grep -l "^UID:$RUN-b" "$LOCAL"/*.vcf | head -1)"
[ -n "$A" ] && [ -n "$B" ] || fail "seeded cards not synced down"
sed -i.bak "s/^FN:.*/FN:$RUN Alpha Edited/" "$A" && rm -f "$A.bak"
NEWUUID="$(python3 -I -c 'import uuid;print(uuid.uuid4())')"
card "$NEWUUID" "$RUN Charlie" >"$LOCAL/$NEWUUID.vcf"
rm -f "$B"
"$VDS" sync kith
assert_agree "2 local edit/add/delete" 2
# explicit expectations, so agreement cannot hold vacuously
for f in server local; do
  expect_no_match "$D/$f.txt" "^$RUN-b|" "2 delete ($f)"
  expect_line "$D/$f.txt" "$RUN-a|$RUN Alpha Edited" "2 edit ($f)"
  expect_line "$D/$f.txt" "$NEWUUID|$RUN Charlie" "2 add keeps its UID ($f)"
done
list_hrefs "$D/hrefs2" || fail "listing failed"
expect_line "$D/hrefs2" "/dav/addressbooks/default/$NEWUUID.vcf" "2 UUID-named add keeps its href"
echo "PASS: 2 expectations (b gone, Alpha edited, Charlie at its UUID href and UID)"

step "3. server-side change (curl PUT) then sync"
card "$RUN-a" "$RUN Alpha ServerEdit" >"$D/a2.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a2.vcf")" || fail "server PUT failed"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "server PUT -> $s"
"$VDS" sync kith
assert_agree "3 server edit" 2
A="$(grep -l "^UID:$RUN-a" "$LOCAL"/*.vcf | head -1)"
grep -q "^FN:$RUN Alpha ServerEdit" "$A" || fail "3: local file does not show the server-side edit"
echo "PASS: 3 expectation (local file shows ServerEdit)"

step "4. conflicting edit on both sides, a wins"
sed -i.bak "s/^FN:.*/FN:$RUN Alpha LocalWins/" "$A" && rm -f "$A.bak"
card "$RUN-a" "$RUN Alpha ServerLoses" >"$D/a3.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a3.vcf")" || fail "conflict server PUT failed"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "conflict server PUT -> $s"
"$VDS" sync kith
assert_agree "4 conflict" 2
expect_line "$D/server.txt" "$RUN-a|$RUN Alpha LocalWins" "4 local edit wins on the server"
expect_no_match "$D/server.txt" "ServerLoses" "4"

echo "ALL STEPS PASSED"
