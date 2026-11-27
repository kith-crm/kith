defmodule Kith.SentryEventHandler do
  @moduledoc """
  Telemetry handler for capturing Oban job failures in Sentry,
  plus context enrichment via `before_send`.

  Only reports to Sentry on the final attempt (max_attempts reached)
  to avoid spamming Sentry on each retry.
  """

  require Logger

  @scrub_keys ~w(password password_confirmation token api_key secret current_password new_password
                 credential_api_key access_token refresh_token id_token client_secret authorization
                 proxy_authorization cookie set_cookie x_api_key cloak_key totp_secret
                 immich_api_key api_key_encrypted hashed_password secret_key_base userinfo
                 aws_secret_access_key smtp_password recovery_codes access_token_secret
                 hashed_code token_hash hashed_token x_kith_client_ip code totp_code totp_token state
                 auth_challenge_binding)

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
        event_source: :oban,
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
  def before_send(%Sentry.Event{} = event) do
    event
    |> enrich_with_logger_metadata()
    |> scrub_params()
  rescue
    _ -> nil
  end

  def before_send(_event), do: nil

  @doc "Drops metrics so upgrading the SDK does not expand error-only collection."
  def before_send_metric(_metric), do: nil

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Recursively scrubs credential keys in maps, structs, lists and header/keyword pairs."
  def scrub_params(params) when is_map(params) do
    params |> Map.to_list() |> Map.new(&scrub_pair/1)
  end

  def scrub_params(params) when is_list(params), do: Enum.map(params, &scrub_params/1)
  def scrub_params({key, value}) when is_atom(key) or is_binary(key), do: scrub_pair({key, value})
  def scrub_params(other), do: other

  defp scrub_pair({key, value}) do
    if sensitive_key?(key), do: {key, "[FILTERED]"}, else: {key, scrub_value(key, value)}
  end

  defp scrub_value(key, value) when key in [:url, "url"] and is_binary(value) do
    uri = URI.parse(value)
    userinfo = if uri.userinfo, do: "[FILTERED]", else: nil

    %{
      uri
      | userinfo: userinfo,
        query: scrub_query(uri.query),
        fragment: scrub_fragment(uri.fragment)
    }
    |> URI.to_string()
  end

  defp scrub_value(key, value) when key in [:query_string, "query_string"] and is_binary(value),
    do: scrub_query(value)

  defp scrub_value(_key, value), do: scrub_params(value)

  defp scrub_query(nil), do: nil

  defp scrub_query(query) do
    query |> URI.query_decoder() |> Enum.map(&scrub_pair/1) |> URI.encode_query()
  end

  defp scrub_fragment(fragment) when is_binary(fragment) do
    if String.contains?(fragment, "="), do: scrub_query(fragment), else: fragment
  end

  defp scrub_fragment(nil), do: nil

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.split(["[", "]"], trim: true)
    |> Enum.any?(&(&1 in @scrub_keys))
  end

  defp sensitive_key?(_key), do: false
end
