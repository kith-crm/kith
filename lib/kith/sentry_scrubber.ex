defmodule Kith.SentryScrubber do
  @moduledoc "Sentry 14 before_send boundary for authentication credentials in event payloads."
  alias Kith.SentryEventHandler

  @sensitive ~w(password secret token code state binding nonce verifier authorization cookie payload)
  @query_credentials ~r/\b(code|state|nonce|code_verifier|access_token|refresh_token|id_token|client_secret|password|auth_challenge_binding)(=|%3D)[^&\s"<>]*/i

  def before_send(%Sentry.Event{} = event) do
    event |> SentryEventHandler.before_send() |> scrub()
  rescue
    _ -> nil
  end

  def before_send(_), do: nil

  defp scrub(map) when is_map(map), do: map |> Map.to_list() |> Map.new(&scrub_pair/1)
  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub({key, value}), do: scrub_pair({key, value})

  defp scrub(value) when is_binary(value),
    do: Regex.replace(@query_credentials, value, "\\1=[FILTERED]")

  defp scrub(value), do: value

  defp scrub_pair({key, value}) when is_atom(key) or is_binary(key) do
    if Enum.any?(@sensitive, &String.contains?(String.downcase(to_string(key)), &1)),
      do: {key, "[FILTERED]"},
      else: {key, scrub(value)}
  end

  defp scrub_pair({key, value}), do: {key, scrub(value)}
end
