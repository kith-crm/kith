defmodule Kith.IpGeolocationUpgradeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Kith.IpGeolocation

  @fixture Path.expand("../fixtures/geoip/GeoIP2-City-Test.mmdb", __DIR__)
  @addresses ["81.2.69.160", "2001:218::", "203.0.113.1", "invalid-ip"]

  setup do
    previous_path = System.get_env("GEOIP_DB_PATH")
    previous_database = Geolix.Database.Loader.get_database(:city)
    Geolix.unload_database(:city)
    clear_cache()

    on_exit(fn ->
      clear_cache()
      Geolix.unload_database(:city)
      if previous_database, do: Geolix.load_database(previous_database)

      if previous_path,
        do: System.put_env("GEOIP_DB_PATH", previous_path),
        else: System.delete_env("GEOIP_DB_PATH")
    end)

    :ok
  end

  test "actual local IPv4 and IPv6 records normalize structs and missing city data" do
    System.put_env("GEOIP_DB_PATH", @fixture)

    assert :ok =
             Geolix.load_database(%{
               id: :city,
               adapter: Geolix.Adapter.MMDB2,
               source: @fixture
             })

    assert IpGeolocation.configured?()

    assert {:ok, %{city: "London", country: "GB", region: "England"}} =
             IpGeolocation.lookup("81.2.69.160")

    assert {:ok, %{city: nil, country: "JP", region: nil}} =
             IpGeolocation.lookup("2001:218::")

    assert {:error, :not_found} = IpGeolocation.lookup("203.0.113.1")
    assert {:error, :invalid_ip} = IpGeolocation.lookup("invalid-ip")

    # Verify the existing one-hour cache contract without sleeping for an hour.
    assert {:ok, ttl} = Kith.Cache.ttl({:geoip, "81.2.69.160"})
    assert ttl > :timer.minutes(59) and ttl <= :timer.hours(1)
  end

  test "unset and blank database configuration retain the no-database fallback" do
    for value <- [nil, "", "   "] do
      if value,
        do: System.put_env("GEOIP_DB_PATH", value),
        else: System.delete_env("GEOIP_DB_PATH")

      refute IpGeolocation.configured?()
      assert {:error, :geoip_not_configured} = IpGeolocation.lookup("81.2.69.160")
    end
  end

  test "configured missing and corrupt local databases return not_found without crashing" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "regression-geoip-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    missing = Path.join(directory, "missing.mmdb")
    corrupt = Path.join(directory, "corrupt.mmdb")
    File.write!(corrupt, "This is synthetic invalid MaxMind data")

    for {path, reason} <- [{missing, :enoent}, {corrupt, :no_metadata}] do
      Geolix.unload_database(:city)
      System.put_env("GEOIP_DB_PATH", path)

      capture_log(fn ->
        assert {:error, ^reason} =
                 Geolix.load_database(%{id: :city, adapter: Geolix.Adapter.MMDB2, source: path})
      end)

      assert IpGeolocation.configured?()
      assert {:error, :not_found} = IpGeolocation.lookup("81.2.69.160")
      assert {:error, :not_found} = IpGeolocation.lookup("2001:218::")
    end
  end

  test "licensed official fixture matches its recorded hash" do
    attribution =
      @fixture
      |> Path.dirname()
      |> Path.join("attribution.json")
      |> File.read!()
      |> Jason.decode!()

    assert attribution["license"] == "Apache-2.0"
    entry = Enum.find(attribution["files"], &(&1["file"] == Path.basename(@fixture)))

    assert Base.encode16(:crypto.hash(:sha256, File.read!(@fixture)), case: :lower) ==
             entry["sha256"]
  end

  defp clear_cache do
    for address <- @addresses, do: Kith.Cache.delete({:geoip, address})
  end
end
