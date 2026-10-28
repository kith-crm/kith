defmodule Kith.SlowQueryLoggerIntegrationTest do
  # Handler registration and threshold configuration are global.
  use Kith.DataCase, async: false
  import ExUnit.CaptureLog

  test "real repository telemetry reaches the handler without logging parameters" do
    Kith.TestEnv.put_env_restoring(:kith, :slow_query_threshold_ms, 0)

    case Kith.SlowQueryLogger.attach() do
      :ok -> on_exit(fn -> :telemetry.detach("kith-slow-query-logger") end)
      {:error, :already_exists} -> :ok
    end

    log =
      capture_log(fn ->
        Repo.query!("select $1::text /* slow-query-wiring */", ["private-value"])
      end)

    assert log =~ "[SlowQuery]"
    assert log =~ "slow-query-wiring"
    refute log =~ "private-value"
  end
end
