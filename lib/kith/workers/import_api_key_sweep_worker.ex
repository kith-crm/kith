defmodule Kith.Workers.ImportApiKeySweepWorker do
  @moduledoc """
  Hourly safety net that wipes import API keys left behind for more than
  24 hours after the import finished.

  Normally `MonicaApiKeyReleaseWorker` (or the crawl itself) wipes the key as
  soon as the last follow-up job is done. This sweep guarantees a key is
  never kept indefinitely when that doesn't happen — e.g. the release job was
  cancelled, a node died mid-job, or the crawl crashed on its final attempt.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Kith.Imports

  # Comfortably longer than any follow-up job can legitimately run
  # (30-minute timeout × 3 attempts plus backoff).
  @max_age_seconds 24 * 60 * 60

  def max_age_seconds, do: @max_age_seconds

  @impl Oban.Worker
  def perform(_job) do
    count = Imports.wipe_stale_api_keys(@max_age_seconds)

    if count > 0 do
      Logger.info("[ImportApiKeySweep] wiped #{count} stale import API key(s)")
    end

    :ok
  end
end
