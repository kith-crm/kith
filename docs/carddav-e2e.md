# CardDAV end-to-end regression

## How to run

```bash
scripts/carddav-e2e/up.sh                 # isolated dev server on :4517, DB kith_carddav_e2e
source /tmp/kith-carddav-e2e.env
npx playwright test --project=e2e test/playwright/carddav/<file> --workers=1
scripts/carddav-e2e/down.sh               # stop the server
MIX_TEST_PARTITION=_carddav mix test      # ExUnit, DB kith_test_carddav
```

`PERF=1 scripts/carddav-e2e/up.sh` additionally seeds account E (2000 contacts).
Seeded users (password `ValidP@ssword123!`) are listed in `test/playwright/helpers/dav.ts`.

## Results matrix

| Spec | Cases | Passed | Failed | Notes |
|---|---|---|---|---|
| 00-harness | H1-H3 | 3 | 0 | |

## Bug log

| ID | Severity | Summary | Request / response | Status |
|---|---|---|---|---|

## Rulings I made

## Real-client smoke
