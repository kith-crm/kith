#!/bin/sh
# Wipe Monica (the DB is on tmpfs), recreate the stack, create review@example.com + token.txt.
set -e
cd "$(dirname "$0")"
docker compose down -v
docker compose up -d
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8089/login)" = 200 ]; do sleep 3; done
C=kith-monica-e2e-monica-1
docker cp bootstrap.php $C:/tmp/bootstrap.php
docker cp state.php $C:/tmp/state.php
docker exec -u www-data $C php /tmp/bootstrap.php
docker cp $C:/tmp/token.txt token.txt
echo "reset done"
