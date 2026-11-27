defmodule Kith.Repo.Migrations.ScopeImportApiKeySweeps do
  use Ecto.Migration

  def up do
    alter table(:imports) do
      add :api_key_cleanup_eligible_at, :utc_datetime
    end

    # Freeze the job shape here so this migration can run independently of
    # future changes to the worker. Give existing imports a fresh buffer.
    execute """
    INSERT INTO oban_jobs (worker, args, queue, state, max_attempts, scheduled_at)
    SELECT 'Kith.Workers.ImportApiKeySweepWorker', jsonb_build_object('import_id', i.id),
           'default', 'scheduled', 3,
           greatest(timezone('UTC', now()), (
             SELECT max(crawl.scheduled_at) FROM oban_jobs AS crawl
             WHERE crawl.worker = 'Kith.Workers.MonicaApiCrawlWorker'
               AND crawl.args->>'import_id' = i.id::text
               AND crawl.state NOT IN ('completed', 'discarded', 'cancelled')
           )) + interval '24 hours'
    FROM imports AS i
    WHERE i.source = 'monica_api'
      AND i.api_key_encrypted IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM oban_jobs AS j
        WHERE j.worker = 'Kith.Workers.ImportApiKeySweepWorker'
          AND j.args @> jsonb_build_object('import_id', i.id)
          AND j.state NOT IN ('completed', 'discarded', 'cancelled')
      )
    """

    execute """
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = timezone('UTC', now())
    WHERE worker = 'Kith.Workers.ImportApiKeySweepWorker'
      AND NOT (args ? 'import_id')
      AND state IN ('available', 'scheduled', 'retryable')
    """
  end

  def down do
    execute """
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = timezone('UTC', now())
    WHERE worker = 'Kith.Workers.ImportApiKeySweepWorker'
      AND args ? 'import_id'
      AND state IN ('available', 'scheduled', 'retryable', 'suspended')
    """

    alter table(:imports) do
      remove :api_key_cleanup_eligible_at
    end
  end
end
