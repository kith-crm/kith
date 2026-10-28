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

  @doc "Queues vCard bytes using a JSON-safe representation shared by upload entry points."
  def enqueue_file(account_id, user_id, file_data) do
    %{account_id: account_id, user_id: user_id, file_data_base64: Base.encode64(file_data)}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "user_id" => user_id} = args}) do
    with {:ok, file_data} <- decode_file(args) do
      import_file(account_id, user_id, file_data)
    end
  end

  defp decode_file(%{"file_data_base64" => encoded}) do
    case Base.decode64(encoded) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, "Invalid encoded vCard file."}
    end
  end

  defp decode_file(%{"file_data" => data}), do: {:ok, data}

  defp import_file(account_id, user_id, file_data) do
    Logger.info("Starting vCard import for account #{account_id}, user #{user_id}")

    case Parser.parse(file_data, per_card: true) do
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
