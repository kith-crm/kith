defmodule Kith.Immich.Client do
  @moduledoc """
  HTTP client for communicating with the Immich REST API.

  All calls use per-account credentials (base_url + api_key).
  Authentication is via `x-api-key` header (not Bearer token).
  Immich integration is strictly read-only — no PUT/POST/DELETE calls.
  """

  require Logger

  @timeout 30_000

  @doc """
  Lists all named people from the Immich instance.

  Returns `{:ok, [%{id: String.t(), name: String.t(), thumbnail_url: String.t()}]}`
  or `{:error, reason}`.
  """
  def list_people(base_url, api_key) do
    url = "#{String.trim_trailing(base_url, "/")}/api/people"

    result =
      get(url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: @timeout
      )

    case result do
      {:ok, %{status: 200, body: %{"people" => people}}} ->
        {:ok, parse_people(people, base_url)}

      {:ok, %{status: 200, body: people}} when is_list(people) ->
        {:ok, parse_people(people, base_url)}

      {:ok, %{status: status}} ->
        error_for_status(status)

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :network_error}
    end
  end

  defp parse_people(people, base_url) do
    base = String.trim_trailing(base_url, "/")

    people
    |> Enum.filter(&(is_binary(&1["name"]) && &1["name"] != ""))
    |> Enum.map(fn person ->
      %{
        id: person["id"],
        name: person["name"],
        thumbnail_url: "#{base}/api/people/#{person["id"]}/thumbnail"
      }
    end)
  end

  defp error_for_status(401), do: {:error, :unauthorized}
  defp error_for_status(404), do: {:error, :not_found}
  defp error_for_status(status), do: {:error, {:unexpected_status, status}}

  @doc """
  Downloads a photo/thumbnail from Immich by asset URL.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def download_asset(url, api_key) do
    case get(url, headers: [{"x-api-key", api_key}], receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, _} -> {:error, :network_error}
    end
  end

  defp get(url, options) do
    configured = Application.get_env(:kith, __MODULE__, []) |> Keyword.get(:req_options, [])
    Kith.BoundedHTTP.get(url, Keyword.merge(options, configured))
  end
end
