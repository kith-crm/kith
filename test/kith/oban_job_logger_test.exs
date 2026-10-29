defmodule Kith.ObanJobLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kith.ObanJobLogger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  defp job(extra \\ %{}) do
    struct!(
      Oban.Job,
      Map.merge(
        %{
          id: 7,
          worker: "Kith.Workers.MonicaMiscDataWorker",
          queue: "imports",
          attempt: 2,
          max_attempts: 3,
          args: %{"plan" => List.duplicate(%{"endpoints" => ["notes"]}, 500), "import_id" => 9}
        },
        extra
      )
    )
  end

  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  test "start line names the job, queue, attempt and how long it waited" do
    log =
      capture_log(fn ->
        ObanJobLogger.handle_event(
          [:oban, :job, :start],
          %{queue_time: ms(1_500)},
          %{job: job()},
          nil
        )
      end)

    assert log =~ "[Oban] job 7 MonicaMiscDataWorker (queue imports, attempt 2/3) started"
    assert log =~ "waited 1500ms"
  end

  test "stop line reports the outcome and duration" do
    log =
      capture_log(fn ->
        ObanJobLogger.handle_event(
          [:oban, :job, :stop],
          %{duration: ms(76_000)},
          %{job: job(), state: :success},
          nil
        )
      end)

    assert log =~ "job 7 MonicaMiscDataWorker"
    assert log =~ "finished (success) in 76000ms"
  end

  test "exception line warns with the failure reason, e.g. a timeout" do
    log =
      capture_log(fn ->
        ObanJobLogger.handle_event(
          [:oban, :job, :exception],
          %{duration: ms(1_800_000)},
          %{
            job: job(),
            state: :failure,
            kind: :error,
            reason: Oban.TimeoutError.exception({Kith.Workers.MonicaMiscDataWorker, 1_800_000}),
            stacktrace: []
          },
          nil
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "failed (failure) after 1800000ms"
    assert log =~ "Oban.TimeoutError"
  end

  test "never logs job args, which hold the whole misc-data plan" do
    log =
      capture_log(fn ->
        ObanJobLogger.handle_event([:oban, :job, :start], %{queue_time: 0}, %{job: job()}, nil)
      end)

    refute log =~ "endpoints"
    refute log =~ "plan"
  end
end
