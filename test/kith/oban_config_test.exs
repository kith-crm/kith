defmodule Kith.ObanConfigTest do
  use ExUnit.Case, async: true

  # Without Lifeline, a job orphaned by a restart or deploy (its process is gone
  # but the row says `executing`) stays executing forever: nothing logs, nothing
  # retries, and MonicaApiKeyReleaseWorker snoozes indefinitely waiting for it.
  describe "Oban plugins" do
    test "Lifeline rescues orphaned executing jobs, but only after the longest job timeout" do
      plugins = Application.fetch_env!(:kith, Oban) |> Keyword.fetch!(:plugins)

      assert {Oban.Plugins.Lifeline, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Lifeline, _}, &1)),
             "Oban.Plugins.Lifeline is not configured"

      rescue_after = Keyword.fetch!(opts, :rescue_after)

      longest_timeout =
        [
          Kith.Workers.MonicaApiCrawlWorker,
          Kith.Workers.MonicaPhotoSyncWorker,
          Kith.Workers.MonicaMiscDataWorker
        ]
        |> Enum.map(& &1.timeout(%Oban.Job{}))
        |> Enum.max()

      # Rescuing sooner would re-run a job that is still legitimately executing.
      assert rescue_after > longest_timeout
    end
  end
end
