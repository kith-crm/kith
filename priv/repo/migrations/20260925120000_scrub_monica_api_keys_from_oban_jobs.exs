defmodule Kith.Repo.Migrations.ScrubMonicaApiKeysFromObanJobs do
  @moduledoc """
  Older Monica follow-up jobs carried the Monica API key in plaintext in
  `args.credential_api_key`. Jobs now read the key from the Import row, so
  strip it from every existing row of those workers, in every state (the
  pruner keeps completed/discarded rows for days, and they show up in Oban
  Web and DB backups).

  Irreversible by design: `down/0` is a no-op.
  """

  use Ecto.Migration

  @scrub_sql """
  UPDATE oban_jobs
  SET args = args - 'credential_api_key'
  WHERE worker IN (
    'Kith.Workers.MonicaPhotoSyncWorker',
    'Kith.Workers.MonicaMiscDataWorker',
    'Kith.Workers.MonicaDocumentImportWorker'
  )
  AND args ? 'credential_api_key'
  """

  # Exposed so the test can run the exact statement inside the Ecto sandbox,
  # where Ecto.Migrator itself can't run.
  def scrub_sql, do: @scrub_sql

  def up, do: execute(@scrub_sql)

  def down, do: :ok
end
