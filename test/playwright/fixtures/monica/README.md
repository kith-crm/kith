# Monica 4.1.2 harness for the reminder-import E2E

Monica 4.1.2 (`monica:4.1.2-apache`) + MySQL 8 on tmpfs (every `down -v` is a full reset), compose project
`kith-monica-e2e`, published on `127.0.0.1:8089`. Used by `test/playwright/monica-reminders.spec.ts`.

## Start, seed
```bash
./run-all.sh      # reset.sh + seed + state, in one go
```
or step by step:
```bash
./reset.sh        # down -v, up, create review@example.com / review-password-1 (verified) + token.txt
                  # (bootstrap.php does the registration and creates the Settings -> API personal token;
                  #  doing it by hand in the UI works too)
export MONICA_API_KEY="$(cat token.txt)"      # MONICA_URL defaults to http://localhost:8089
python3 seed.py   # contacts + reminders via the API (calls state.php phases first_met / life_event_type)
docker exec -u www-data kith-monica-e2e-monica-1 php /tmp/state.php   # DB-only state: Gina stay-in-touch, "sent" reminder
```
PHP must run as `-u www-data`; as root it creates root-owned log files and breaks Monica.

The one-time reminders are date-relative (today, today - 2 days, today + 120 days), so the spec's expectations hold
on any day. Yara's year-unknown birthday takes the container's current year. Exact next dates are pinned by ExUnit.

## Run the spec
Kith must listen on 127.0.0.1:4000 and be able to reach Monica, and Mailpit must be up (the spec confirms the new
user via `MAILPIT_URL`, default http://localhost:8025; `docker compose -f docker-compose.dev.yml up -d mailpit`).
```bash
MONICA_URL=http://localhost:8089 MONICA_URL_FROM_KITH=http://localhost:8089 \
MONICA_API_KEY="$(cat token.txt)" \
  npx playwright test --project=e2e test/playwright/monica-reminders.spec.ts
```
Use `MONICA_URL_FROM_KITH=http://host.docker.internal:8089` when Kith itself runs in Docker.
Without `MONICA_URL`/`MONICA_URL_FROM_KITH` and `MONICA_API_KEY` the spec is skipped.
