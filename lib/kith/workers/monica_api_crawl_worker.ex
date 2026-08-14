defmodule Kith.Workers.MonicaApiCrawlWorker do
  @moduledoc """
  Oban worker that crawls a Monica CRM API instance and imports all contacts.

  Paginates through the contacts API, imports contacts with all embedded data,
  and resolves cross-references. When the user opts into photos via
  `api_options["photos"]`, this worker enqueues `MonicaPhotoSyncWorker` after
  the main crawl completes — photo import runs as a separate job so the main
  import status reflects only contact work.

  Connection is validated in the import wizard before this job is enqueued.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi
  alias Kith.Workers.DuplicateDetectionWorker
  alias Kith.Workers.MonicaMiscDataWorker
  alias Kith.Workers.MonicaPhotoSyncWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) do
    import_job = Imports.get_import!(import_id)

    with {:ok, _} <-
           Imports.update_import_status(import_job, "processing", %{
             started_at: DateTime.utc_now()
           }),
         credential <- build_credential(import_job),
         opts <- build_opts(import_job),
         {:ok, summary} <-
           MonicaApi.crawl(
             import_job.account_id,
             import_job.user_id,
             credential,
             import_job,
             opts
           ) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      summary_map = ensure_map(summary)
      {misc_plan, persisted_summary} = pop_misc_plan(summary_map)

      Imports.update_import_status(import_job, "completed", %{
        summary: persisted_summary,
        completed_at: now
      })

      # Enqueue misc worker BEFORE wiping the API key — it needs the
      # still-encrypted key in its job args (same pattern as photo sync).
      maybe_enqueue_misc_data_worker(import_job, misc_plan)
      Imports.wipe_api_key(import_job)

      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_complete, persisted_summary})

      # Trigger duplicate detection for newly imported contacts
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: import_job.account_id}))

      # Enqueue photo sync (separate job) if the user opted in
      maybe_enqueue_photo_sync(import_job)

      Logger.info("MonicaApi import #{import_id} completed: #{inspect(persisted_summary)}")
      :ok
    else
      {:error, reason} ->
        Logger.error("MonicaApi import #{import_id} failed: #{inspect(reason)}")

        Imports.update_import_status(import_job, "failed", %{
          summary: %{error: inspect(reason)},
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

        Imports.wipe_api_key(import_job)

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  defp build_credential(import_job) do
    %{
      url: import_job.api_url,
      api_key: import_job.api_key_encrypted,
      req_options: Application.get_env(:kith, :monica_req_options, [])
    }
  end

  @doc false
  # Public for testing — the wizard → source-module flag handoff is the
  # contract that Bug C silently violated, so we want a regression test that
  # binds against this directly.
  def build_opts(import_job) do
    options = import_job.api_options || %{}

    # Forward every wizard-saved option so the source module is the single
    # source of truth for which keys it reads. Normalize only the legacy
    # extra_notes default-on semantic.
    options
    |> Map.put_new("extra_notes", true)
    |> Map.update!("extra_notes", &(&1 != false))
  end

  defp maybe_enqueue_photo_sync(import_job) do
    if get_in(import_job.api_options || %{}, ["photos"]) do
      # api_key is wiped from the DB immediately after this worker completes,
      # so the photo sync worker receives its own copy via job args
      # (same pattern as MonicaDocumentImportWorker).
      %{
        "import_id" => import_job.id,
        "credential_url" => import_job.api_url,
        "credential_api_key" => import_job.api_key_encrypted
      }
      |> MonicaPhotoSyncWorker.new()
      |> Oban.insert()
    end
  end

  defp maybe_enqueue_misc_data_worker(_import_job, []), do: :ok

  defp maybe_enqueue_misc_data_worker(import_job, plan) do
    %{
      "import_id" => import_job.id,
      "credential_url" => import_job.api_url,
      "credential_api_key" => import_job.api_key_encrypted,
      "plan" => plan
    }
    |> MonicaMiscDataWorker.new()
    |> Oban.insert()
  end

  # The misc-data plan is built by MonicaApi.crawl/5 and returned in the
  # summary under either an atom or string key (the map round-trips through
  # ensure_map/1). Pop it out before persisting so the plan is not stored
  # in the DB summary.
  defp pop_misc_plan(summary) do
    {plan_atom, rest_atom} = Map.pop(summary, :misc_data_plan, [])
    {plan_str, rest} = Map.pop(rest_atom, "misc_data_plan", [])
    plan = if plan_atom == [], do: plan_str, else: plan_atom
    {plan, rest}
  end

  defp ensure_map(m) when is_map(m), do: m
end
