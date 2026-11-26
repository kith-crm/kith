defmodule Kith.Workers.ImportApiKeySweepWorker do
  @moduledoc """
  Delayed fallback for one Monica import. Normal cleanup releases the key
  sooner. The fallback keeps the key until no credential consumer can run
  and a grace period has elapsed.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:import_id], states: :incomplete]

  alias Kith.Imports

  @grace_seconds 24 * 60 * 60
  @poll_seconds 15 * 60

  def schedule(import_id, crawl_scheduled_at) do
    %{import_id: import_id}
    |> new(scheduled_at: DateTime.add(crawl_scheduled_at, @grace_seconds))
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) when is_integer(import_id) do
    case Imports.release_monica_api_key(import_id, @grace_seconds) do
      {:ok, :done} -> :ok
      {:ok, :busy} -> {:snooze, @poll_seconds}
      {:ok, {:wait, seconds}} -> {:snooze, seconds}
      {:error, _} = error -> error
    end
  end

  # Jobs queued by the old cron schedule had no import_id.
  def perform(%Oban.Job{}), do: :ok
end
