defmodule Kith.Imports.JobCancellation do
  @moduledoc """
  Cancels all pending/scheduled/retryable/executing Oban jobs that belong to a
  single account's imports.

  Scoping rule: only jobs whose args reference this account (directly via
  `account_id` or transitively via `import_id` belonging to one of this
  account's imports) are touched. No other account's jobs are affected.

  Uses `Oban.cancel_all_jobs/2` which both updates the DB state and signals
  any currently-`executing` jobs to terminate via Oban's Notifier (`:pkill`).
  """

  alias Kith.Imports.Import
  alias Kith.Repo

  import Ecto.Query
  require Logger

  # Workers whose args carry `import_id` — cancelled by import_id ∈ account's imports
  @import_id_workers ~w[
    Kith.Workers.MonicaApiCrawlWorker
    Kith.Workers.MonicaPhotoSyncWorker
    Kith.Workers.MonicaDocumentImportWorker
    Kith.Workers.ImportSourceWorker
  ]

  # Workers whose args carry `account_id` directly — cancelled by account_id match
  @account_id_workers ~w[
    Kith.Workers.ImportWorker
    Kith.Workers.DuplicateDetectionWorker
  ]

  @cancellable_states ~w[available scheduled retryable executing]

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    import_ids = account_import_ids(account_id)
    import_cancelled = cancel_jobs_by_import_id(import_ids)
    account_cancelled = cancel_jobs_by_account_id(account_id)

    Logger.info(
      "[Imports.JobCancellation] cancelled #{import_cancelled} import-id-scoped job(s) + " <>
        "#{account_cancelled} account-id-scoped job(s) for account #{account_id}"
    )

    :ok
  end

  defp account_import_ids(account_id) do
    Repo.all(from(i in Import, where: i.account_id == ^account_id, select: i.id))
  end

  defp cancel_jobs_by_import_id([]), do: 0

  defp cancel_jobs_by_import_id(import_ids) do
    {:ok, count} =
      from(j in Oban.Job,
        where: j.worker in ^@import_id_workers,
        where: j.state in ^@cancellable_states,
        where: fragment("(?->>'import_id')::bigint", j.args) in ^import_ids
      )
      |> Oban.cancel_all_jobs()

    count
  end

  defp cancel_jobs_by_account_id(account_id) do
    {:ok, count} =
      from(j in Oban.Job,
        where: j.worker in ^@account_id_workers,
        where: j.state in ^@cancellable_states,
        where: fragment("(?->>'account_id')::bigint", j.args) == ^account_id
      )
      |> Oban.cancel_all_jobs()

    count
  end
end
