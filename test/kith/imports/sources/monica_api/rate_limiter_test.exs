defmodule Kith.Imports.Sources.MonicaApi.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Kith.Imports.Sources.MonicaApi.RateLimiter

  # Tests run with the real Hammer backend; we use a unique host per test
  # so buckets do not collide between tests. We override the scale window
  # and retry sleep to keep the suite fast — the production values live
  # in config/config.exs.

  setup do
    prev_limit = Application.get_env(:kith, :monica_rate_limit)
    prev_scale = Application.get_env(:kith, :monica_rate_limit_scale_ms)
    prev_retry = Application.get_env(:kith, :monica_rate_limit_retry_sleep_ms)

    Application.put_env(:kith, :monica_rate_limit, 1)
    Application.put_env(:kith, :monica_rate_limit_scale_ms, 300)
    Application.put_env(:kith, :monica_rate_limit_retry_sleep_ms, 50)

    on_exit(fn ->
      Application.put_env(:kith, :monica_rate_limit, prev_limit)
      Application.put_env(:kith, :monica_rate_limit_scale_ms, prev_scale)
      Application.put_env(:kith, :monica_rate_limit_retry_sleep_ms, prev_retry)
    end)

    :ok
  end

  defp unique_host, do: "test-#{System.unique_integer([:positive])}.example"

  describe "wait!/1" do
    test "returns :ok immediately while under the per-window budget" do
      host = unique_host()

      {us, _} =
        :timer.tc(fn -> assert :ok = RateLimiter.wait!("https://#{host}") end)

      assert us < 30_000, "expected sub-30ms for one call under the budget, got #{us}us"
    end

    test "sleeps once the budget is exhausted" do
      host = unique_host()
      :ok = RateLimiter.wait!("https://#{host}")

      {us, _} = :timer.tc(fn -> RateLimiter.wait!("https://#{host}") end)

      assert us >= 30_000, "expected ≥30ms wait when over budget, got #{us}us"
      assert us < 1_000_000, "did not expect ≥1s wait; window should have rolled by now"
    end

    test "per-host buckets do not share quota" do
      host_a = unique_host()
      host_b = unique_host()

      :ok = RateLimiter.wait!("https://#{host_a}")

      {us, _} = :timer.tc(fn -> RateLimiter.wait!("https://#{host_b}") end)
      assert us < 30_000, "host_b should be in its own bucket"
    end

    test "extracts the host portion of a URL for the bucket key" do
      host = unique_host()
      url1 = "https://#{host}/api/contacts"
      url2 = "https://#{host}/api/me"

      :ok = RateLimiter.wait!(url1)

      {us, _} = :timer.tc(fn -> RateLimiter.wait!(url2) end)
      assert us >= 30_000, "same host → same bucket → second call should wait"
    end
  end
end
