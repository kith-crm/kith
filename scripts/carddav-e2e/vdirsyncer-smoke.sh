#!/usr/bin/env bash
# Real-client smoke: vdirsyncer <-> Kith CardDAV (account B, dav-other).
# Usage: source .carddav-task10/env && scripts/carddav-e2e/vdirsyncer-smoke.sh
# Needs network access for `pip install vdirsyncer`. Exits non-zero on any mismatch.
# Every HTTP call uses `curl -f`, so a 401, 5xx or connection failure aborts the run
# instead of yielding an empty (and "agreeing") state.
set -euo pipefail

BASE="${PLAYWRIGHT_BASE_URL:-http://127.0.0.1:4527}"
USER_EMAIL="dav-other@carddav.test"
PASSWORD="${DAV_PASSWORD:-ValidP@ssword123!}"
RUN="vds-$(date +%s)"
A_UID="$(python3 -I -c 'import uuid;print(uuid.uuid4())')"
B_UID="$(python3 -I -c 'import uuid;print(uuid.uuid4())')"
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
    /^UID:/ {u=substr($0,5); sub(/^urn:uuid:/,"",u)} /^FN:/ {f=substr($0,4)}
    END { if (f ~ r) print u "|" f }'
}

server_state() { # outfile
  list_hrefs "$D/hrefs" || fail "server listing failed"

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
  printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:%s\r\nFN:%s\r\nN:;%s;;;\r\nEND:VCARD\r\n' "$1" "$2" "$2"
}

put_status() { # href file -> http status (no -f: the status is inspected)
  curl -sS -K "$D/curl.cfg" -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: text/vcard' \
    --data-binary @"$2" "$BOOK$1"
}

step "install vdirsyncer"
python3 -I -m venv "$D/venv"
"$D/venv/bin/python" -I -m pip install -q vdirsyncer
VDS="$D/venv/bin/vdirsyncer"
"$VDS" --version

step "seed server with 2 cards over DAV"
card "$A_UID" "$RUN Alpha" >"$D/a.vcf"
card "$B_UID" "$RUN Bravo" >"$D/b.vcf"
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
expect_line "$D/local.txt" "$A_UID|$RUN Alpha" "1"
expect_line "$D/local.txt" "$B_UID|$RUN Bravo" "1"

step "2. local edit, local add (UUID filename), local delete"
A="$(grep -El "^UID:(urn:uuid:)?$A_UID" "$LOCAL"/*.vcf | head -1)"
B="$(grep -El "^UID:(urn:uuid:)?$B_UID" "$LOCAL"/*.vcf | head -1)"
[ -n "$A" ] && [ -n "$B" ] || fail "seeded cards not synced down"
sed -i.bak -e "s/^FN:.*/FN:$RUN Alpha Edited/" -e "s/^N:.*/N:;$RUN Alpha Edited;;;/" "$A" && rm -f "$A.bak"
NEWUUID="$(python3 -I -c 'import uuid;print(uuid.uuid4())')"
card "$NEWUUID" "$RUN Charlie" | sed '/END:VCARD/i\
TEL:+15550123456\
NOTE:CLI client note\
X-CLI-EXTRA:retained' >"$LOCAL/$NEWUUID.vcf"
rm -f "$B"
"$VDS" sync kith
assert_agree "2 local edit/add/delete" 2
# explicit expectations, so agreement cannot hold vacuously
for f in server local; do
  expect_no_match "$D/$f.txt" "^$B_UID|" "2 delete ($f)"
  expect_line "$D/$f.txt" "$A_UID|$RUN Alpha Edited" "2 edit ($f)"
  expect_line "$D/$f.txt" "$NEWUUID|$RUN Charlie" "2 add keeps its UID ($f)"
done
list_hrefs "$D/hrefs2" || fail "listing failed"
expect_line "$D/hrefs2" "/dav/addressbooks/default/$NEWUUID.vcf" "2 UUID-named add keeps its href"
echo "PASS: 2 expectations (b gone, Alpha edited, Charlie at its UUID href and UID)"

step "3. server-side change (curl PUT) then sync"
card "$A_UID" "$RUN Alpha ServerEdit" >"$D/a2.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a2.vcf")" || fail "server PUT failed"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "server PUT -> $s"
"$VDS" sync kith
assert_agree "3 server edit" 2
A="$(grep -El "^UID:(urn:uuid:)?$A_UID" "$LOCAL"/*.vcf | head -1)"
grep -q "^FN:$RUN Alpha ServerEdit" "$A" || fail "3: local file does not show the server-side edit"
echo "PASS: 3 expectation (local file shows ServerEdit)"

step "4. conflicting edit on both sides, a wins"
sed -i.bak -e "s/^FN:.*/FN:$RUN Alpha LocalWins/" -e "s/^N:.*/N:;$RUN Alpha LocalWins;;;/" "$A" && rm -f "$A.bak"
card "$A_UID" "$RUN Alpha ServerLoses" >"$D/a3.vcf"
s="$(put_status "$RUN-a.vcf" "$D/a3.vcf")" || fail "conflict server PUT failed"
[[ "$s" =~ ^(200|201|204)$ ]] || fail "conflict server PUT -> $s"
"$VDS" sync kith
assert_agree "4 conflict" 2
expect_line "$D/server.txt" "$A_UID|$RUN Alpha LocalWins" "4 local edit wins on the server"
expect_no_match "$D/server.txt" "ServerLoses" "4"

step "5. unchanged repeat sync is idempotent"
cp "$D/server.txt" "$D/before-repeat.txt"
"$VDS" sync kith
assert_agree "5 repeat sync" 2
diff -u "$D/before-repeat.txt" "$D/server.txt" || fail "5 repeat changed state"
step "S4 local phone/note edit preserves client extras"
C="$(grep -El "^UID:(urn:uuid:)?$NEWUUID" "$LOCAL"/*.vcf | head -1)"
sed -i.bak -e 's/^TEL:.*/TEL:+15550654321/' -e 's/^NOTE:.*/NOTE:CLI client edited note/' "$C"
rm -f "$C.bak"
"$VDS" sync kith
step "S3/S4/S6 application state and extra preservation"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
app_action() {
  (cd "$ROOT"; source .carddav-task10/env; mix run scripts/carddav-e2e/app-action.exs "$1" "$USER_EMAIL" ${2:+"$2"}) >"$D/app-action.log" 2>&1 || { cat "$D/app-action.log"; fail "application action $1"; }
}
app_action assert-trash "$B_UID"
dcurl "$BOOK$NEWUUID.vcf" >"$D/charlie-server.vcf"
for line in '+15550654321' 'NOTE:CLI client edited note' 'X-CLI-EXTRA:retained'; do
  grep -q "$line" "$D/charlie-server.vcf" || fail "S3/S4 missing $line"
done
step "private Kith edits preserve DAV document bytes and revision"
app_action assert-boundary "$NEWUUID"
"$VDS" sync kith
step "S5 application phone and tag rename"
app_action edit "$NEWUUID"
"$VDS" sync kith
C="$(grep -El "^UID:(urn:uuid:)?$NEWUUID" "$LOCAL"/*.vcf | head -1)"
grep -q '+15550999999' "$C" || fail "S5 phone not synchronized"
grep -q "Renamed CLI tag $NEWUUID" "$C" || fail "S5 tag rename not synchronized"
step "S7 application trash and archive"
app_action trash "$A_UID"
app_action archive "$NEWUUID"
"$VDS" sync --force-delete kith
assert_agree "S7 hidden contacts disappear" 0
step "S11 application restore"
app_action restore "$A_UID"
"$VDS" sync kith
assert_agree "S11 restored contact reappears" 1
step "S10 application empty trash and resync"
app_action empty-trash
"$VDS" sync kith
assert_agree "S10 no duplicates or deleted resurrection" 1
"$VDS" sync kith
assert_agree "S10 repeat remains stable" 1
echo "ALL STEPS PASSED (including S3-S7, S10, S11)"
