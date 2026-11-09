#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
[[ -f .oidc-local/run.json ]] || { echo 'No owned run state'; exit 0; }
python3 scripts/oidc-local/ownership.py check
python3 scripts/oidc-local/ownership.py evidence
# Exact command and start-time identity required for the matching process kind.
for kind in kith proxy; do
  [[ -f ".oidc-local/$kind.process.json" ]] || continue
  python3 scripts/oidc-local/ownership.py stop "$kind"
done
# Recheck immediately before removal, including resources appearing since inventory.
scripts/oidc-local/compose.sh down --volumes > .oidc-local/down.log 2>&1
echo 'Owned project removed; inventory and sanitized diagnostics retained privately'
