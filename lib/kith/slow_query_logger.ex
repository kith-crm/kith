defmodule Kith.SlowQueryLogger do
  @moduledoc """
  Logs Ecto queries that take longer than a threshold.

  Ecto's own query logging is a debug-level firehose, so production (info level)
  shows no query timings at all. This handler listens to the repo's telemetry
  event and emits one warning per slow query, with the split that matters when
  diagnosing it:

    * `db` — time Postgres spent executing the statement;
    * `queue` — time spent waiting for a pool connection. A high `queue` with a
      low `db` means the pool is exhausted (many Oban jobs share the pool), not
      that the query is slow.

  The statement is truncated and bound parameters are never logged, since they
  can carry contact data.

  The threshold is `config :kith, :slow_query_threshold_ms` (default 500).
  """

  require Logger

  @handler_id "kith-slow-query-logger"
  @default_threshold_ms 500
  @max_query_chars 300

  @doc "Attaches the handler. Safe to call more than once."
  def attach do
    :telemetry.attach(@handler_id, [:kith, :repo, :query], &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(_event, measurements, metadata, _config) do
    total = to_ms(measurements[:total_time])

    if total >= threshold_ms() do
      Logger.warning(
        "[SlowQuery] #{total}ms (db #{to_ms(measurements[:query_time])}ms, " <>
          "queue #{to_ms(measurements[:queue_time])}ms, decode #{to_ms(measurements[:decode_time])}ms) " <>
          "source=#{metadata[:source] || "-"} #{truncate(metadata[:query])}"
      )
    end
  end

  defp threshold_ms,
    do: Application.get_env(:kith, :slow_query_threshold_ms, @default_threshold_ms)

  defp to_ms(nil), do: 0
  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp truncate(nil), do: ""

  defp truncate(query) do
    query = query |> to_string() |> String.replace(~r/\s+/, " ")

    if String.length(query) > @max_query_chars,
      do: String.slice(query, 0, @max_query_chars) <> "…",
      else: query
  end
end
