defmodule Kith.SentryEventHandler do
  @moduledoc """
  Telemetry handler for capturing Oban job failures in Sentry,
  plus context enrichment via `before_send`.

  Only reports to Sentry on the final attempt (max_attempts reached)
  to avoid spamming Sentry on each retry.
  """

  require Logger

  @scrub_keys ~w(password password_confirmation token api_key secret current_password new_password credential_api_key)

  @doc "Attaches telemetry handlers for Oban + Sentry integration."
  def attach do
    :telemetry.attach(
      "kith-oban-sentry",
      [:oban, :job, :exception],
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  @doc false
  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    %{job: job, reason: reason, stacktrace: stacktrace} = metadata

    # Only report on final attempt
    if job.attempt >= job.max_attempts do
      Sentry.capture_exception(reason,
        stacktrace: stacktrace,
        extra: %{
          worker: job.worker,
          queue: job.queue,
          attempt: job.attempt,
          max_attempts: job.max_attempts,
          args: scrub_params(job.args)
        }
      )
    end
  rescue
    _ -> :ok
  end

  @doc """
  Enriches Sentry events with user context and scrubs sensitive data.
  Used as a `before_send` callback.
  """
  def before_send(event) do
    event
    |> enrich_with_logger_metadata()
    |> scrub_event_data()
  rescue
    _ -> event
  end

  defp enrich_with_logger_metadata(event) do
    metadata = Logger.metadata()

    user_context =
      %{}
      |> maybe_put(:id, metadata[:user_id])
      |> maybe_put(:account_id, metadata[:account_id])

    if user_context == %{} do
      event
    else
      %{event | user: Map.merge(event.user || %{}, user_context)}
    end
  end

  defp scrub_event_data(event) do
    update_in(event.request.data, fn data ->
      scrub_params(data)
    end)
  rescue
    _ -> event
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Recursively scrubs sensitive keys from a map."
  def scrub_params(params) when is_map(params) do
    Map.new(params, fn
      {key, _value} when is_binary(key) and key in @scrub_keys ->
        {key, "[FILTERED]"}

      {key, value} when is_atom(key) ->
        if Atom.to_string(key) in @scrub_keys do
          {key, "[FILTERED]"}
        else
          {key, scrub_params(value)}
        end

      {key, value} when is_map(value) ->
        {key, scrub_params(value)}

      {key, value} ->
        {key, value}
    end)
  end

  def scrub_params(other), do: other
end
