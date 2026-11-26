# Import API key sweep investigation and fix plan

## Findings

The hourly execution is intentional in the current implementation, but conflicts
with the requested lifecycle. Both `config/config.exs:75` and the production
worker configuration in `config/runtime.exs:276` register
`{"15 * * * *", Kith.Workers.ImportApiKeySweepWorker}`. This runs at minute 15
every hour independently of import creation. The existing worker test explicitly
requires cron registration. Git history attributes the worker to commit
`0900815` (keep Monica API keys out of Oban arguments).

Hypotheses checked: unconditional cron registration is confirmed; worker
self-rescheduling and import-triggered recurring insertion are ruled out by the
worker body and call-site search. The worker simply invokes the global
`Imports.wipe_stale_api_keys/1` query.

The sweep's 24-hour cutoff is not a completion guarantee. The query only checks
that a key exists and `coalesce(completed_at, updated_at)` predates the cutoff.
It does not check import status, crawl jobs, or follow-up jobs. A pending import
untouched for 25 hours qualifies, as does a completed crawl whose document,
photo, or misc jobs remain scheduled, retryable, or executing. The existing
imports tests even require wiping old unfinished imports. These are code-level
findings; a database reproduction has not been run in this checkout.

Normal cleanup uses `MonicaApiKeyReleaseWorker`, which polls follow-up states
every 60 seconds. Crawl completion precedes follow-up completion. Import status
also becomes `failed` on intermediate crawl failures while Oban may retry, so
status alone cannot authorize deletion. On a final crawl error,
`MonicaApiCrawlWorker.fail_attempt/3` wipes immediately even though document
jobs may already have been inserted during the crawl. That path needs the same
safety rule as the sweep.

## Reproduction

Run from the repository root (no project dependencies or database required):

```sh
elixir -e 'Mix.start(); config = Config.Reader.read!("config/config.exs", env: :test, target: :host); plugins = config[:kith][Oban][:plugins]; {_, opts} = Enum.find(plugins, fn {mod, _} -> mod == Oban.Plugins.Cron end); entry = Enum.find(opts[:crontab], fn {_, worker} -> worker == Kith.Workers.ImportApiKeySweepWorker end); IO.inspect(entry, label: "Sweep schedule with zero imports"); if entry, do: raise("FAIL: sweep registered independently of import scheduling")'
```

Observed exit status 1:

```text
Sweep schedule with zero imports: {"15 * * * *", Kith.Workers.ImportApiKeySweepWorker}
** (RuntimeError) FAIL: sweep registered independently of import scheduling
```

This evaluates the real application configuration and reproduces unconditional
registration, rather than executing Oban's cron engine. Production registration
was verified by source inspection. `mix test
test/kith/workers/import_api_key_sweep_worker_test.exs` was attempted and stops
with missing dependencies, including Oban and Ecto. No production access or
claims of observed production key deletion are involved.

## Proposed implementation

1. Add a context operation to schedule a Monica API import. In one database
   transaction, persist the import, insert its crawl job, and insert one delayed
   sweep with only `import_id` in its arguments. Update the wizard's current
   separate create/insert calls to use it. File imports without credentials must
   not schedule a key sweep. Use Oban uniqueness per import to deduplicate active
   sweep jobs; transaction rollback must leave neither keys nor orphan jobs.
2. Make the sweep import-scoped. Schedule its first check 24 hours after the
   crawl's scheduled start (a conservative initial buffer, not a deletion
   deadline). If any credential consumer is available, scheduled, executing, or
   retryable, snooze and keep the key regardless of elapsed time. Include the
   crawl and all three follow-up worker types; exclude cleanup workers so they
   cannot block each other. Missing imports and already-cleared keys are no-ops.
3. Persist a cleanup eligibility timestamp on the import. Start the fallback's
   24-hour grace period only after all credential consumers are terminal; reset
   eligibility if work resumes. A stale import timestamp is never evidence of
   completion. An orphaned pending import can become eligible only after a
   synchronized check proves there is no consumer capable of running.
4. Centralize safe release for the normal release worker, fallback sweep, and
   final crawl failure. Preserve prompt normal cleanup after successful work;
   the 24-hour grace applies to fallback cleanup. Final failure must wait for
   document work or explicitly cancel it and confirm termination before wiping.
   Run readiness checks and wiping under the same import row lock/transaction;
   enqueue paths and any supported manual retry path must honor that lock and
   reject new credential work after key deletion. A query followed by an
   unlocked update is insufficient. Guard completion while the crawl is still
   executing and may enqueue children.
5. Remove the sweep from both crontabs and replace the test that requires cron.
   Deploy with a one-time idempotent backfill for imports retaining keys, using
   the new scoped scheduling API. Handle already-enqueued legacy empty-argument
   sweeps as no-ops, and cancel their available/scheduled/retryable instances.
   Ensure old worker processes have drained before enabling the new lifecycle.
   Keep the scoped fallback outside bulk cancellation that would strand keys;
   account deletion should make it safely no-op. Alert on discarded cleanup
   jobs or abnormally old retained keys rather than forcibly deleting live keys.

## Acceptance tests

- No sweep cron entry in base or production worker configuration; no imports
  means no new sweep jobs.
- Successful scheduling inserts exactly one scoped delayed sweep; rollback,
  duplicate scheduling, and file imports behave correctly.
- Freeze time beyond 24 hours and retain keys for the crawl and each follow-up
  in every runnable state, including future schedules and retries after a failed
  attempt. Another import's jobs cannot block or trigger deletion.
- Fallback snoozes through long queues, starts grace only at quiescence, then
  wipes exactly the intended import after grace expires.
- Exercise concurrent child enqueue and cleanup, crawl completion before child
  enqueue, final crawl failure with pending documents, and manual retry.
- Missing/deleted imports, nil keys, repeated execution, legacy empty args,
  cancellation, restart, and backfill are idempotent and safe.

## Rollout

Stop the old web and worker services before running the migration and starting
the upgraded services. This keeps the old web service from inserting imports
after the backfill snapshot, and drains the old worker that could still run
global sweeps. The migration schedules a scoped sweep for each retained Monica
key and cancels queued legacy sweeps. The new worker treats any legacy job it
still encounters as a no-op.

If rolling back to the old worker, drain the upgraded services and run the down
migration before restarting the old services. The down migration cancels queued
scoped sweeps because the old worker ignores their arguments.

Oban records cancellation before signalling a running job. Both cleanup
paths keep the key for the worker's full timeout after cancellation when the
job had already started. Document imports now have the same 30-minute timeout
as the other credential consumers.

Use the existing Oban job exception reporting for cleanup errors. Check
discarded sweep jobs in Oban Web, and check retained keys by age without
selecting their encrypted values. If cleanup is delayed, inspect the import's
crawl and follow-up jobs before re-enqueueing its scoped sweep. An Oban Web
retry can still enqueue a job after cleanup, but the job cancels on startup
when it finds the key is gone. Start a new import to supply a fresh key.
