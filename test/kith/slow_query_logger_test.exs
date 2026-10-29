defmodule Kith.SlowQueryLoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Kith.SlowQueryLogger

  defp measurements(total_ms) do
    %{
      total_time: System.convert_time_unit(total_ms, :millisecond, :native),
      query_time: System.convert_time_unit(400, :millisecond, :native),
      queue_time: System.convert_time_unit(100, :millisecond, :native)
    }
  end

  test "does not log below the 500ms threshold" do
    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event(
          [],
          measurements(499),
          %{query: "select 'qa-below-threshold'"},
          nil
        )
      end)

    refute log =~ "qa-below-threshold"
  end

  test "logs exactly at the threshold and separates database from queue time" do
    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event(
          [],
          measurements(500),
          %{query: "select 'slow'", source: "contacts"},
          nil
        )
      end)

    assert log =~ "[SlowQuery] 500ms (db 400ms, queue 100ms, decode 0ms)"
    assert log =~ "source=contacts select 'slow'"
  end

  test "truncates statements and never emits bound parameters" do
    padding = String.duplicate("x", 2_000)

    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event(
          [],
          measurements(501),
          %{query: "select $1::text, '#{padding}'", params: ["secret-param-value"]},
          nil
        )
      end)

    assert log =~ "[SlowQuery]"
    assert log =~ "…"
    refute log =~ "secret-param-value"
    refute log =~ padding
  end

  test "missing optional SQL and timings do not crash the handler" do
    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event(
          [],
          %{total_time: System.convert_time_unit(500, :millisecond, :native)},
          %{},
          nil
        )
      end)

    assert log =~ "500ms (db 0ms, queue 0ms, decode 0ms) source=-"
  end
end
