defmodule Kith.CacheProviderIntegrationTest do
  use ExUnit.Case, async: false

  alias Kith.Cache

  setup do
    previous_req = Req.default_options()
    previous_weather = Application.get_env(:kith, :weather_api_key)
    previous_geolocation = System.get_env("ENABLE_GEOLOCATION")
    previous_location_key = System.get_env("LOCATION_IQ_API_KEY")
    weather_key = {:weather, 12.34, 56.78}
    address = "cache-test-#{System.unique_integer([:positive])} main street"
    geocode_key = {:geocode, address}
    Cache.delete(weather_key)
    Cache.delete(geocode_key)

    on_exit(fn ->
      Req.default_options(previous_req)
      Application.put_env(:kith, :weather_api_key, previous_weather)
      restore_env("ENABLE_GEOLOCATION", previous_geolocation)
      restore_env("LOCATION_IQ_API_KEY", previous_location_key)
      Cache.delete(weather_key)
      Cache.delete(geocode_key)
    end)

    %{weather_key: weather_key, address: address, geocode_key: geocode_key}
  end

  test "weather caches successful provider data for the intended one hour", context do
    parent = self()
    Application.put_env(:kith, :weather_api_key, "synthetic-key")

    Req.default_options(
      plug: fn conn ->
        send(parent, :weather_request)
        assert conn.host == "api.openweathermap.org"
        Req.Test.json(conn, %{"main" => %{"temp" => 20}, "name" => "Fixture City"})
      end
    )

    assert {:ok, %{temperature: 20, city_name: "Fixture City"}} =
             Kith.Weather.fetch_current(12.34, 56.78)

    assert_receive :weather_request
    assert {:ok, %{temperature: 20}} = Kith.Weather.fetch_current(12.34, 56.78)
    refute_receive :weather_request, 20
    assert {:ok, ttl} = Cache.ttl(context.weather_key)
    assert ttl > :timer.minutes(59) and ttl <= :timer.hours(1)
  end

  test "provider errors are returned without caching", context do
    parent = self()
    Application.put_env(:kith, :weather_api_key, "synthetic-key")

    Req.default_options(
      plug: fn conn ->
        send(parent, :weather_request)
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end
    )

    for _ <- 1..2 do
      assert {:error, :unauthorized} = Kith.Weather.fetch_current(12.34, 56.78)
      assert_receive :weather_request
      assert :miss = Cache.get(context.weather_key)
    end
  end

  test "normalized geocoding shares the intended 24-hour successful result", context do
    parent = self()
    System.put_env("ENABLE_GEOLOCATION", "true")
    System.put_env("LOCATION_IQ_API_KEY", "synthetic-key")

    Req.default_options(
      plug: fn conn ->
        send(parent, :geocode_request)
        assert conn.host == "us1.locationiq.com"
        Req.Test.json(conn, [%{"lat" => "32.1", "lon" => "35.2"}])
      end
    )

    assert {:ok, %{lat: 32.1, lng: 35.2}} =
             Kith.Geocoding.geocode("  " <> String.upcase(context.address) <> "  ")

    assert_receive :geocode_request
    assert {:ok, %{lat: 32.1, lng: 35.2}} = Kith.Geocoding.geocode(context.address)
    refute_receive :geocode_request, 20
    assert {:ok, ttl} = Cache.ttl(context.geocode_key)
    assert ttl > :timer.hours(23) and ttl <= :timer.hours(24)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
