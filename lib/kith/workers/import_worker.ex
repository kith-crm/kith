defmodule Kith.Workers.ImportWorker do
  @moduledoc """
  Oban worker for processing large vCard imports (100+ contacts) asynchronously.

  Broadcasts progress via PubSub for LiveView updates.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  alias Kith.Contacts
  alias Kith.VCard.Parser
  alias Kith.Workers.DuplicateDetectionWorker

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"account_id" => account_id, "user_id" => user_id, "file_data" => file_data}
      }) do
    Logger.info("Starting vCard import for account #{account_id}, user #{user_id}")

    case Parser.parse(file_data) do
      {:ok, parsed_contacts} ->
        total = length(parsed_contacts)
        topic = "import:#{account_id}"

        results =
          parsed_contacts
          |> Enum.with_index(1)
          |> Enum.reduce(
            %{imported: 0, skipped: 0, skipped_duplicates: 0, errors: []},
            fn {parsed, idx}, acc ->
              result = import_single_entry(account_id, parsed, idx, acc)
              maybe_broadcast_progress(topic, idx, total, result)
              result
            end
          )

        # Broadcast completion
        Phoenix.PubSub.broadcast(
          Kith.PubSub,
          topic,
          {:import_complete, results}
        )

        # Trigger duplicate detection for newly imported contacts
        Oban.insert(DuplicateDetectionWorker.new(%{account_id: account_id}))

        Logger.info(
          "vCard import complete for account #{account_id}: " <>
            "#{results.imported} imported, #{results.skipped} skipped"
        )

        :ok

      {:error, reason} ->
        Logger.error("vCard import failed for account #{account_id}: #{reason}")
        {:error, reason}
    end
  end

  defp maybe_broadcast_progress(topic, idx, total, result) do
    if rem(idx, 10) == 0 || idx == total do
      Phoenix.PubSub.broadcast(
        Kith.PubSub,
        topic,
        {:import_progress, %{current: idx, total: total, results: result}}
      )
    end
  end

  defp import_single_entry(account_id, parsed, idx, acc) do
    if Contacts.contact_exists?(account_id, parsed) do
      %{acc | skipped: acc.skipped + 1, skipped_duplicates: acc.skipped_duplicates + 1}
    else
      do_import_entry(account_id, parsed, idx, acc)
    end
  rescue
    e ->
      error_msg = "Entry #{idx}: #{Exception.message(e)}"
      %{acc | skipped: acc.skipped + 1, errors: acc.errors ++ [error_msg]}
  end

  defp do_import_entry(account_id, parsed, idx, acc) do
    case Contacts.import_contact(account_id, parsed) do
      {:ok, _contact} ->
        %{acc | imported: acc.imported + 1}

      {:error, reason} ->
        error_msg = "Entry #{idx}: #{inspect(reason)}"
        %{acc | skipped: acc.skipped + 1, errors: acc.errors ++ [error_msg]}
    end
  end
end
