defmodule Kith.Workers.ImportSourceWorker do
  @moduledoc """
  Generic Oban worker that orchestrates any file-based import source.
  Loads the import job, resolves the source module, loads the file from
  Storage, and delegates to `source.import/4`.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  alias Kith.Imports
  alias Kith.Storage
  alias Kith.Workers.DuplicateDetectionWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) do
    import = Imports.get_import!(import_id)

    with {:ok, source_mod} <- Imports.resolve_source(import.source),
         {:ok, _} <-
           Imports.update_import_status(import, "processing", %{started_at: DateTime.utc_now()}),
         {:ok, data} <- load_file(import.file_storage_key),
         {:ok, summary} <-
           source_mod.import(import.account_id, import.user_id, data, %{import: import}) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      summary_map = ensure_map(summary)

      Imports.update_import_status(import, "completed", %{
        summary: summary_map,
        completed_at: now
      })

      topic = "import:#{import.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_complete, summary_map})

      # Trigger duplicate detection for newly imported contacts
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: import.account_id}))

      Logger.info("Import #{import_id} completed: #{inspect(summary_map)}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Import #{import_id} failed: #{inspect(reason)}")

        Imports.update_import_status(import, "failed", %{
          summary: %{error: inspect(reason)},
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

        {:error, reason}
    end
  end

  defp load_file(nil), do: {:error, "No file storage key"}

  defp load_file(key) do
    case Storage.read(key) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Failed to load file: #{inspect(reason)}"}
    end
  end

  defp ensure_map(%{__struct__: _} = s), do: Map.from_struct(s)
  defp ensure_map(m) when is_map(m), do: m
end
