#!/usr/bin/env bash
# Own provider config only. Never restarts Kith, proxy or browser/device sessions.
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
mode=${1:-apply}
[[ "$mode" =~ ^(snapshot|apply|restore)$ ]]
if [[ "$mode" == snapshot && -f .oidc-local/freshness-original-provider.json ]]; then
 echo 'Original provider snapshot already retained; refusing overwrite'; exit 1
fi
scripts/oidc-local/compose.sh exec -T --user root -e "KITH_FRESHNESS_ACTION=$mode" server ak shell < scripts/oidc-local/freshness-flow.py > ".oidc-local/freshness-$mode-private.log" 2>&1
if [[ "$mode" == snapshot ]]; then
 python3 - <<'PY'
import json,pathlib
state=pathlib.Path('.oidc-local')
for line in (state/'freshness-snapshot-private.log').read_text().splitlines():
 if line.startswith('SAFE_ORIGINAL_PROVIDER='):
  (state/'freshness-original-provider.json').write_text(json.dumps(json.loads(line.split('=',1)[1])))
  break
else: raise SystemExit('Provider snapshot absent')
PY
else
 rg '^PASS ' ".oidc-local/freshness-$mode-private.log"
fi
if [[ "$mode" == apply ]]; then
 printf 'configured\n' > .oidc-local/freshness-profile-ready
fi
