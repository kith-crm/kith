defmodule Kith.ObanJobLogger do
  @moduledoc """
  One log line when an Oban job starts, finishes, or fails, with its duration.

  A job whose process dies (restart, deploy, kill) never emits its `stop` event,
  so "started" without a matching "finished" is how a dead or hung job shows up
  in the logs. `Oban.Plugins.Lifeline` is what eventually re-queues it.

  This replaces `Oban.Telemetry.attach_default_logger/1` on purpose: that logger
  prints the full job `args`, and for `MonicaMiscDataWorker` the args hold the
  entire import plan. Only the worker, queue, attempt, state and timings are
  logged here.
  """

  require Logger

  @handler_id "kith-oban-job-logger"
  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]

  @doc "Attaches the handler. Safe to call more than once."
  def attach, do: :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)

  @doc false
  def handle_event([:oban, :job, :start], measurements, %{job: job}, _config) do
    Logger.info(
      "[Oban] #{label(job)} started (waited #{ms(measurements[:queue_time])}ms in queue)"
    )
  end

  def handle_event([:oban, :job, :stop], measurements, %{job: job, state: state}, _config) do
    Logger.info("[Oban] #{label(job)} finished (#{state}) in #{ms(measurements[:duration])}ms")
  end

  def handle_event([:oban, :job, :exception], measurements, metadata, _config) do
    %{job: job, state: state, kind: kind, reason: reason} = metadata

    Logger.warning(
      "[Oban] #{label(job)} failed (#{state}) after #{ms(measurements[:duration])}ms: " <>
        Exception.format_banner(kind, reason)
    )
  end

  defp label(job) do
    worker = job.worker |> String.split(".") |> List.last()
    "job #{job.id} #{worker} (queue #{job.queue}, attempt #{job.attempt}/#{job.max_attempts})"
  end

  defp ms(nil), do: 0
  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
