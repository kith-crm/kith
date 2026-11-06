defmodule Kith.Weather do
  @moduledoc """
  Fetches current weather data for a given latitude/longitude from OpenWeatherMap.
  Uses local caching (1-hour TTL) and :fuse for circuit breaking.
  """

  require Logger

  @cache_ttl :timer.hours(1)
  @fuse_name :weather_fuse

  @doc "Returns true if weather is configured and available."
  def enabled? do
    api_key = Application.get_env(:kith, :weather_api_key)
    is_binary(api_key) and api_key != ""
  end

  @doc """
  Fetches current weather for the given latitude/longitude.

  Returns `{:ok, weather_map}` or `{:error, reason}`.
  """
  def fetch_current(lat, lng) when is_number(lat) and is_number(lng) do
    cache_key = {:weather, Float.round(lat * 1.0, 2), Float.round(lng * 1.0, 2)}

    Kith.Cache.fetch(cache_key, fn -> fetch_with_circuit(lat, lng) end, ttl: @cache_ttl)
  end

  def fetch_current(_, _), do: {:error, :invalid_coordinates}

  @doc "Installs the fuse circuit breaker. Call from Application.start/2."
  def install_fuse do
    :fuse.install(@fuse_name, {{:standard, 3, :timer.minutes(5)}, {:reset, :timer.minutes(5)}})
  end

  # -- Private --

  defp fetch_with_circuit(lat, lng) do
    case check_circuit() do
      :ok ->
        result = do_fetch(lat, lng)
        handle_circuit_result(result)

        result

      {:error, :circuit_open} ->
        {:error, :circuit_open}
    end
  end

  defp do_fetch(lat, lng) do
    api_key = Application.get_env(:kith, :weather_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :not_configured}
    else
      url = "https://api.openweathermap.org/data/2.5/weather"

      case Req.get(url,
             params: [lat: lat, lon: lng, appid: api_key, units: "metric"],
             receive_timeout: 5_000
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, parse_response(body)}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:api_error, status}}

        {:error, %{reason: :timeout}} ->
          {:error, :timeout}

        {:error, _reason} ->
          {:error, :network_error}
      end
    end
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
    Logger.warning("Weather fetch failed: #{reason}")
  end

  defp handle_circuit_result(_), do: :ok

  defp parse_response(body) do
    %{
      temperature: get_in(body, ["main", "temp"]),
      feels_like: get_in(body, ["main", "feels_like"]),
      humidity: get_in(body, ["main", "humidity"]),
      description:
        body |> Map.get("weather", []) |> List.first(%{}) |> Map.get("description", ""),
      icon: body |> Map.get("weather", []) |> List.first(%{}) |> Map.get("icon", ""),
      wind_speed: get_in(body, ["wind", "speed"]),
      city_name: Map.get(body, "name", "")
    }
  end
end
