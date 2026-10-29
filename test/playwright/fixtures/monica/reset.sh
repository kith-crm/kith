#!/bin/sh
# Wipe Monica (the DB is on tmpfs), recreate the stack, create review@example.com + token.txt.
set -e
cd "$(dirname "$0")"
docker compose down -v
docker compose up -d
tries=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8089/login)" = 200 ]; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "Monica did not answer on :8089/login after 60 tries (3 s apart)" >&2
    exit 1
  fi
  sleep 3
done
C=kith-monica-e2e-monica-1
docker cp bootstrap.php $C:/tmp/bootstrap.php
docker cp state.php $C:/tmp/state.php
docker exec -u www-data $C php /tmp/bootstrap.php
docker cp $C:/tmp/token.txt token.txt
echo "reset done"
