defmodule Kith.Workers.MonicaApiKeyReleaseWorker do
  @moduledoc """
  Wipes a Monica import's API key once no follow-up job needs it any more.

  The follow-up workers (`MonicaPhotoSyncWorker`, `MonicaMiscDataWorker`,
  `MonicaDocumentImportWorker`) read the key from `imports.api_key_encrypted`
  by `import_id`, so it can't be wiped when the crawl finishes. Instead
  `release/1` is called at the end of a successful crawl:

    * no follow-up jobs pending → the key is wiped immediately;
    * otherwise this worker is enqueued and snoozes until every follow-up
      job for the import has reached a terminal state (completed, discarded,
      or cancelled), then wipes the key.

  A single poller is used instead of having each follow-up job check its
  peers: Oban only records a job's final state after `perform/1` returns, so
  two follow-ups finishing together would each still see the other as
  `executing` and neither would wipe. Polling the recorded states avoids that
  race and also covers jobs that crash, time out, or are cancelled from Oban
  Web without running any code of ours.

  Snoozing doesn't consume attempts (Oban bumps `max_attempts` on snooze).
  If this job is itself lost, `ImportApiKeySweepWorker` wipes the key later.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Kith.Imports
  alias Kith.Imports.Import

  @poll_seconds 60

  @doc """
  Wipes the import's API key now if no follow-up job is pending, otherwise
  enqueues this worker to wipe it after the last one finishes.
  """
  def release(%Import{} = import) do
    if Imports.monica_followups_pending?(import.id) do
      %{"import_id" => import.id} |> new() |> Oban.insert()
    else
      Imports.wipe_api_key(import)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) do
    case Imports.get_import(import_id) do
      nil ->
        :ok

      %Import{api_key_encrypted: nil} ->
        :ok

      import ->
        wipe_when_followups_done(import)
    end
  end

  defp wipe_when_followups_done(import) do
    if Imports.monica_followups_pending?(import.id) do
      {:snooze, @poll_seconds}
    else
      with {:ok, _} <- Imports.wipe_api_key(import), do: :ok
    end
  end
end
