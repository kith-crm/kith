defmodule Kith.Imports do
  @moduledoc """
  The Imports context — manages import jobs, source resolution, and import record tracking.
  """

  import Ecto.Query, warn: false
  alias Kith.Accounts.Scope
  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Repo
  alias Kith.Workers.{ImportApiKeySweepWorker, MonicaApiCrawlWorker}

  @sources %{
    "monica_api" => Kith.Imports.Sources.MonicaApi,
    "vcard" => Kith.Imports.Sources.VCard
  }

  ## Import Jobs

  def schedule_monica_import(%Scope{} = scope, attrs) do
    attrs =
      attrs
      |> Map.take([:api_url, :api_key_encrypted, :api_options])
      |> Map.put(:source, "monica_api")

    Repo.transact(fn ->
      scheduled_at = DateTime.utc_now()

      with {:ok, import} <- create_import(scope.account.id, scope.user.id, attrs),
           {:ok, _crawl} <-
             Oban.insert(
               MonicaApiCrawlWorker.new(%{import_id: import.id}, scheduled_at: scheduled_at)
             ),
           {:ok, _sweep} <- ImportApiKeySweepWorker.schedule(import.id, scheduled_at) do
        {:ok, import}
      end
    end)
  end

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

  # Jobs that run after the crawl and read the key.
  @monica_followup_modules [
    Kith.Workers.MonicaPhotoSyncWorker,
    Kith.Workers.MonicaMiscDataWorker,
    Kith.Workers.MonicaDocumentImportWorker
  ]
  @monica_followup_workers Enum.map(@monica_followup_modules, &Oban.Worker.to_string/1)

  @terminal_job_states ~w[completed discarded cancelled]

  def monica_followup_workers, do: @monica_followup_workers

  def wipe_api_key(%Import{} = import) do
    import
    |> Ecto.Changeset.change(api_key_encrypted: nil, api_key_cleanup_eligible_at: nil)
    |> Repo.update()
  end

  @doc """
  Returns true while any Monica follow-up job (photo sync, misc data,
  documents) for the import can still run or be resumed. Completed,
  discarded, and cancelled jobs don't count.
  """
  def monica_followups_pending?(import_id) do
    import_jobs(import_id, @monica_followup_workers)
    |> where([j], j.state not in ^@terminal_job_states)
    |> Repo.exists?()
  end

  @doc """
  Loads the import for a credential consumer and clears any previous sweep
  eligibility. A manually retried job must acquire the key again.
  """
  def load_monica_import_for_job!(import_id) do
    {:ok, import} =
      with_locked_import(import_id, fn
        nil -> raise Ecto.NoResultsError, queryable: Import
        import -> reset_key_cleanup_eligibility(import)
      end)

    import
  end

  @doc """
  Inserts follow-up work while the import still has a key. Serializes
  insertion with key cleanup, including when the parent job was cancelled.
  """
  def enqueue_monica_followup(worker, %{"import_id" => import_id} = args)
      when worker in @monica_followup_modules do
    with_locked_import(import_id, fn
      %Import{api_key_encrypted: key} = import when not is_nil(key) ->
        with {:ok, _} <- reset_key_cleanup_eligibility(import), do: Oban.insert(worker.new(args))

      _ ->
        {:error, :api_key_unavailable}
    end)
  end

  @doc """
  Clears the key once all credential consumers are terminal. A positive
  grace period starts at the first observation of that state.
  """
  def release_monica_api_key(import_id, grace_seconds) do
    with_locked_import(import_id, fn
      nil -> {:ok, :done}
      %Import{api_key_encrypted: nil} -> {:ok, :done}
      import -> release_key_when_idle(import, grace_seconds)
    end)
  end

  defp release_key_when_idle(import, grace_seconds) do
    # Lock terminal rows too. Oban's manual retry updates the same rows, so
    # it either becomes visible here or the retried job loads the cleared key.
    jobs =
      import_jobs(import.id, [
        Oban.Worker.to_string(MonicaApiCrawlWorker) | @monica_followup_workers
      ])
      |> order_by([j], j.id)
      |> lock("FOR UPDATE")
      |> select([j], struct(j, [:state, :worker, :attempted_at, :cancelled_at]))
      |> Repo.all()

    now = DateTime.utc_now(:second)

    if Enum.any?(jobs, &credential_job_busy?(&1, now)) do
      with {:ok, _} <- reset_key_cleanup_eligibility(import), do: {:ok, :busy}
    else
      release_key_after_grace(import, grace_seconds)
    end
  end

  # Oban records cancellation before signalling the executing process.
  # Allow the full execution timeout for a cancelled job that was started.
  defp credential_job_busy?(
         %Oban.Job{state: "cancelled", attempted_at: %DateTime{}, cancelled_at: %DateTime{} = at} =
           job,
         now
       ) do
    {:ok, worker} = Oban.Worker.from_string(job.worker)
    DateTime.before?(now, DateTime.add(at, worker.timeout(job), :millisecond))
  end

  defp credential_job_busy?(job, _now), do: job.state not in @terminal_job_states

  defp release_key_after_grace(import, 0) do
    with {:ok, _} <- wipe_api_key(import), do: {:ok, :done}
  end

  defp release_key_after_grace(import, grace_seconds) do
    now = DateTime.utc_now(:second)
    eligible_at = import.api_key_cleanup_eligible_at

    cond do
      is_nil(eligible_at) ->
        import
        |> Ecto.Changeset.change(api_key_cleanup_eligible_at: DateTime.add(now, grace_seconds))
        |> Repo.update()
        |> case do
          {:ok, _} -> {:ok, {:wait, grace_seconds}}
          error -> error
        end

      DateTime.after?(eligible_at, now) ->
        {:ok, {:wait, DateTime.diff(eligible_at, now)}}

      true ->
        release_key_after_grace(import, 0)
    end
  end

  defp reset_key_cleanup_eligibility(%Import{api_key_cleanup_eligible_at: nil} = import),
    do: {:ok, import}

  defp reset_key_cleanup_eligibility(import) do
    import
    |> Ecto.Changeset.change(api_key_cleanup_eligible_at: nil)
    |> Repo.update()
  end

  defp with_locked_import(import_id, fun) do
    Repo.transact(fn ->
      import = Repo.one(from(i in Import, where: i.id == ^import_id, lock: "FOR UPDATE"))
      fun.(import)
    end)
  end

  defp import_jobs(import_id, workers) do
    id = to_string(import_id)

    from(j in Oban.Job,
      where: j.worker in ^workers and fragment("?->>'import_id' = ?", j.args, ^id)
    )
  end
end
