#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/oidc-local/ownership.py check >/dev/null
project=$(python3 scripts/oidc-local/ownership.py project)
exec docker compose --env-file .oidc-local/runtime.env -p "$project" -f scripts/oidc-local/compose.yml "$@"
