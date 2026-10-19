defmodule Kith.SlowQueryLoggerTest do
  # Application env and the Logger level are global.
  use Kith.DataCase, async: false

  import ExUnit.CaptureLog

  alias Kith.SlowQueryLogger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    SlowQueryLogger.attach()
    on_exit(fn -> :telemetry.detach("kith-slow-query-logger") end)
    :ok
  end

  test "logs a query slower than the threshold with its timing and SQL" do
    Kith.TestEnv.put_env_restoring(:kith, :slow_query_threshold_ms, 20)

    log =
      capture_log(fn ->
        Repo.query!("select pg_sleep(0.06), 'marker-slow'")
      end)

    assert log =~ "[SlowQuery]"
    assert log =~ "marker-slow"
    assert log =~ ~r/\d+ms \(db \d+ms, queue \d+ms/
  end

  test "stays quiet for queries under the threshold" do
    Kith.TestEnv.put_env_restoring(:kith, :slow_query_threshold_ms, 5_000)

    log = capture_log(fn -> Repo.query!("select 1, 'marker-fast'") end)

    refute log =~ "[SlowQuery]"
  end

  test "truncates very long statements and never logs bound parameters" do
    Kith.TestEnv.put_env_restoring(:kith, :slow_query_threshold_ms, 0)
    padding = String.duplicate("x", 2_000)

    log =
      capture_log(fn ->
        Repo.query!("select $1::text, '#{padding}'", ["secret-param-value"])
      end)

    assert log =~ "[SlowQuery]"
    assert log =~ "…"
    refute log =~ "secret-param-value"
    refute log =~ padding
  end
end
