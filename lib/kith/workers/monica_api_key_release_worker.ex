defmodule Kith.Workers.MonicaApiKeyReleaseWorker do
  @moduledoc """
  Wipes a Monica import's key as soon as its crawl and follow-ups are terminal.
  Oban records their final states after they return, so this worker snoozes
  while work is active. The scoped sweep is a fallback if release is interrupted.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:import_id], states: :incomplete]

  alias Kith.Imports
  alias Kith.Imports.Import

  @poll_seconds 60

  def release(%Import{id: import_id}) do
    case Imports.release_monica_api_key(import_id, 0) do
      {:ok, :done} = done -> done
      {:ok, :busy} -> %{import_id: import_id} |> new() |> Oban.insert()
      {:error, _} = error -> error
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => import_id}}) do
    case Imports.release_monica_api_key(import_id, 0) do
      {:ok, :done} -> :ok
      {:ok, :busy} -> {:snooze, @poll_seconds}
      {:error, _} = error -> error
    end
  end
end
