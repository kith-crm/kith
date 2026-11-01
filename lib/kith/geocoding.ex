defmodule Kith.Geocoding do
  @moduledoc """
  Geocoding via LocationIQ API with local caching and fuse circuit breaker.

  Only enabled when both `ENABLE_GEOLOCATION=true` and `LOCATION_IQ_API_KEY` are set.
  Results are cached locally with 24-hour TTL.
  """

  require Logger

  @cache_ttl :timer.hours(24)
  @fuse_name :locationiq_fuse
  @api_base "https://us1.locationiq.com/v1/search"

  @doc "Returns true if geocoding is enabled (env vars set)."
  def enabled? do
    System.get_env("ENABLE_GEOLOCATION") == "true" &&
      api_key() != nil
  end

  @doc """
  Geocodes an address string to lat/lng coordinates.

  Returns `{:ok, %{lat: float, lng: float}}` or `{:error, reason}`.
  """
  def geocode(address) when is_binary(address) do
    if enabled?() do
      normalized = normalize_address(address)
      cache_key = {:geocode, normalized}
      geocode_with_cache(cache_key, normalized)
    else
      {:error, :not_enabled}
    end
  end

  defp geocode_with_cache(cache_key, normalized) do
    Kith.Cache.fetch(cache_key, fn -> geocode_with_circuit(normalized) end, ttl: @cache_ttl)
  end

  defp geocode_with_circuit(normalized) do
    with :ok <- check_circuit() do
      result = do_geocode(normalized)
      handle_circuit_result(result)
      result
    end
  end

  @doc "Installs the fuse circuit breaker. Call from Application.start/2."
  def install_fuse do
    :fuse.install(@fuse_name, {{:standard, 5, 60_000}, {:reset, 60_000}})
  end

  # -- Private --

  defp do_geocode(address) do
    Req.get(@api_base,
      params: [key: api_key(), q: address, format: "json", limit: 1],
      receive_timeout: 10_000
    )
    |> handle_geocode_response()
  end

  defp handle_geocode_response({:ok, %{status: 200, body: [first | _]}}) do
    parse_coordinates(first)
  end

  defp handle_geocode_response({:ok, %{status: 200, body: []}}), do: {:error, :not_found}
  defp handle_geocode_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_geocode_response({:ok, %{status: 429}}), do: {:error, :rate_limited}

  defp handle_geocode_response({:ok, %{status: status}}),
    do: {:error, {:unexpected_status, status}}

  defp handle_geocode_response({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp handle_geocode_response({:error, _reason}), do: {:error, :network_error}

  defp parse_coordinates(first) do
    lat = parse_float(first["lat"])
    lng = parse_float(first["lon"])

    if lat && lng,
      do: {:ok, %{lat: lat, lng: lng}},
      else: {:error, :parse_error}
  end

  defp check_circuit do
    case :fuse.ask(@fuse_name, :sync) do
      :ok ->
        :ok

      :blown ->
        {:error, :circuit_open}

      {:error, :not_found} ->
        # Fuse not installed yet — allow the request
        :ok
    end
  end

  defp handle_circuit_result({:ok, _}), do: :fuse.reset(@fuse_name)

  defp handle_circuit_result({:error, reason})
       when reason in [:rate_limited, :timeout, :network_error] do
    :fuse.melt(@fuse_name)
    Logger.warning("LocationIQ geocoding failure: #{reason}")
  end

  defp handle_circuit_result(_), do: :ok

  defp normalize_address(address) do
    address
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp api_key, do: System.get_env("LOCATION_IQ_API_KEY")

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(val) when is_float(val), do: val
  defp parse_float(_), do: nil
end
