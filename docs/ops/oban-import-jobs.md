# Ops: Import jobs disappear from Oban Web (issue #6)

**Symptom:** on prod, import jobs stop showing in the Oban Web dashboard the
same day they run.

**What we know:** no application code deletes `oban_jobs` rows. The
`Oban.Plugins.Pruner` `max_age` is 7 days in every config path
(`config/config.exs`, `config/runtime.exs` worker branch via
`Kith.ConfigHelpers.oban_pruner_max_age_seconds/0`). The prod web container runs
`plugins: false`, so only the worker container prunes.

The defensive changes shipped so far:

- `oban_pruner_max_age_seconds/0` clamps any `OBAN_PRUNER_MAX_AGE_DAYS < 1` up
  to 1 day and logs a warning.
- `Kith.Application` logs `[Oban] pruner max_age = <s>s (<d>d)` at boot on nodes
  that run Oban plugins.

The runtime root cause is **not yet confirmed on prod**. Diagnose with the two
checks below.

## Cause 1 (most likely): Oban Web state filter hides completed jobs

Oban Web's Jobs view defaults to non-terminal states. `completed` import jobs
drop out of the default view within seconds but stay in `oban_jobs` for the full
7-day retention.

**Check** — on a prod DB:

```sql
SELECT state, count(*)
FROM oban_jobs
WHERE worker LIKE '%Import%'
GROUP BY 1;
```

If `completed` (and/or `cancelled`) rows are present and only recent, the data
is fine.

**Fix:** in Oban Web, select the `completed` / `cancelled` state filters (or
"all states") to see finished import jobs. No code change needed.

## Cause 2: a stray `OBAN_PRUNER_MAX_AGE_DAYS` on the queue-running container

If the query above shows rows genuinely gone within a day, the worker
container's pruner is running with a tiny `max_age`.

**Check** — on a prod worker node (`bin/kith remote`):

```elixir
Oban.config().plugins
|> Enum.find(&match?({Oban.Plugins.Pruner, _}, &1))
```

Confirm `max_age` is `604_800` (7 days). Also inspect the container env:
`env | grep OBAN_PRUNER_MAX_AGE_DAYS`. Cross-check the boot log line
`[Oban] pruner max_age = ...`.

**Fix:** unset (or correct) `OBAN_PRUNER_MAX_AGE_DAYS` on the worker container
and redeploy. Values below 1 day are now clamped to 1 day, but the intended
default is to leave the var unset (7 days).
