#!/bin/sh
# Full cycle: reset -> seed -> state
set -e
cd "$(dirname "$0")"
./reset.sh
export MONICA_API_KEY="$(cat token.txt)"
python3 seed.py
docker exec -u www-data kith-monica-e2e-monica-1 php /tmp/state.php
