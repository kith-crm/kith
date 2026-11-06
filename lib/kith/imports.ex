defmodule Kith.Imports do
  @moduledoc """
  The Imports context — manages import jobs, source resolution, and import record tracking.
  """

  import Ecto.Query, warn: false
  alias Kith.Accounts.Scope
  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Repo

  @sources %{
    "monica_api" => Kith.Imports.Sources.MonicaApi,
    "vcard" => Kith.Imports.Sources.VCard
  }

  ## Import Jobs

  def create_import(account_id, user_id, attrs) do
    if has_active_import?(account_id) do
      {:error, :import_in_progress}
    else
      %Import{account_id: account_id, user_id: user_id}
      |> Import.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, import} ->
          {:ok, import}

        {:error,
         %{
           errors: [
             {:account_id,
              {_, [constraint: :unique, constraint_name: "imports_one_active_per_account_idx"]}}
             | _
           ]
         }} ->
          {:error, :import_in_progress}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def get_import!(id), do: Repo.get!(Import, id)
  def get_import(id), do: Repo.get(Import, id)

  def update_import_status(%Import{} = import, status, attrs \\ %{}) do
    import
    |> Import.status_changeset(status, attrs)
    |> Repo.update()
  end

  def cancel_import(%Import{} = import) do
    update_import_status(import, "cancelled")
  end

  def get_active_import(account_id) do
    Import
    |> where([i], i.account_id == ^account_id)
    |> where([i], i.status in ["pending", "processing"])
    |> Repo.one()
  end

  defp has_active_import?(account_id) do
    Import
    |> where([i], i.account_id == ^account_id)
    |> where([i], i.status in ["pending", "processing"])
    |> Repo.exists?()
  end

  def list_imports(%Scope{} = scope) do
    Import
    |> where([i], i.account_id == ^scope.account.id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  def get_import(%Scope{} = scope, id) do
    Import
    |> where([i], i.id == ^id and i.account_id == ^scope.account.id)
    |> Repo.one()
  end

  def update_sync_summary(%Import{} = import, sync_summary) when is_map(sync_summary) do
    import
    |> Ecto.Changeset.change(sync_summary: sync_summary)
    |> Repo.update()
  end

  ## Source Resolution

  def resolve_source(source) when is_binary(source) do
    case Map.get(@sources, source) do
      nil -> {:error, :unknown_source}
      mod -> {:ok, mod}
    end
  end

  ## Import Records

  def find_import_record(account_id, source, source_entity_type, source_entity_id) do
    ImportRecord
    |> where([r], r.account_id == ^account_id)
    |> where([r], r.source == ^source)
    |> where([r], r.source_entity_type == ^source_entity_type)
    |> where([r], r.source_entity_id == ^source_entity_id)
    |> Repo.one()
  end

  def record_imported_entity(
        %Import{} = import,
        source_entity_type,
        source_entity_id,
        local_entity_type,
        local_entity_id
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ImportRecord{}
    |> ImportRecord.changeset(%{
      account_id: import.account_id,
      import_id: import.id,
      source: import.source,
      source_entity_type: source_entity_type,
      source_entity_id: source_entity_id,
      local_entity_type: local_entity_type,
      local_entity_id: local_entity_id
    })
    |> Repo.insert(
      on_conflict: [
        set: [import_id: import.id, local_entity_id: local_entity_id, updated_at: now]
      ],
      conflict_target:
        {:unsafe_fragment, ~s|("account_id", "source", "source_entity_type", "source_entity_id")|},
      returning: true
    )
  end

  def list_import_records(import_id) do
    ImportRecord
    |> where([r], r.import_id == ^import_id)
    |> Repo.all()
  end

  def count_import_records_by_type(import_id, entity_type) do
    ImportRecord
    |> where([r], r.import_id == ^import_id)
    |> where([r], r.source_entity_type == ^entity_type)
    |> Repo.aggregate(:count)
  end

  ## API key lifecycle
  #
  # The Monica API key lives only in `imports.api_key_encrypted` (Cloak-
  # encrypted) — never in Oban job args. Follow-up workers read it from the
  # Import row by `import_id`, so it must stay until the last follow-up job
  # has finished. `Kith.Workers.MonicaApiKeyReleaseWorker` wipes it then;
  # `Kith.Workers.ImportApiKeySweepWorker` is the time-based safety net.

  # Oban worker names of the jobs that run after the crawl and read the key.
  @monica_followup_workers ~w[
    Kith.Workers.MonicaPhotoSyncWorker
    Kith.Workers.MonicaMiscDataWorker
    Kith.Workers.MonicaDocumentImportWorker
  ]

  @pending_job_states ~w[available scheduled executing retryable]

  def monica_followup_workers, do: @monica_followup_workers

  def wipe_api_key(%Import{} = import) do
    import
    |> Ecto.Changeset.change(api_key_encrypted: nil)
    |> Repo.update()
  end

  @doc """
  Returns true while any Monica follow-up job (photo sync, misc data,
  documents) for the import can still run — i.e. is available, scheduled,
  executing, or waiting to retry. Completed, discarded, and cancelled jobs
  don't count.
  """
  def monica_followups_pending?(import_id) do
    Oban.Job
    |> where([j], j.worker in ^@monica_followup_workers)
    |> where([j], j.state in ^@pending_job_states)
    |> where([j], fragment("(?->>'import_id')::bigint", j.args) == ^import_id)
    |> Repo.exists?()
  end

  @doc """
  Safety net: wipes the API key of every import that finished (or, if it
  never finished, was last updated) more than `max_age_seconds` ago.
  System-wide by design — it runs from cron, not on behalf of an account.
  Returns the number of imports wiped.
  """
  def wipe_stale_api_keys(max_age_seconds) do
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_seconds, :second)

    {count, _} =
      Import
      |> where([i], not is_nil(i.api_key_encrypted))
      |> where([i], coalesce(i.completed_at, i.updated_at) < ^cutoff)
      |> Repo.update_all(set: [api_key_encrypted: nil])

    count
  end
end
