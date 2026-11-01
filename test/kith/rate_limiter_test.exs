defmodule Kith.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Kith.RateLimiter

  setup do
    previous = Application.get_env(:kith, RateLimiter)
    Application.put_env(:kith, RateLimiter, backend: :ets)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kith, RateLimiter, previous),
        else: Application.delete_env(:kith, RateLimiter)
    end)

    :ok
  end

  test "the application supervises the ETS counter used by all callers" do
    assert {RateLimiter, pid, :worker, _} =
             List.keyfind(Supervisor.which_children(Kith.Supervisor), RateLimiter, 0)

    assert Process.alive?(pid)
    assert :ets.info(Kith.RateLimiter.ETS, :owner) == pid
  end

  test "concurrent hits admit exactly the configured budget in one window" do
    scale = 60_000
    remaining = scale - rem(System.system_time(:millisecond), scale)
    if remaining < 1000, do: Process.sleep(remaining + 1)
    key = unique_key()

    results =
      1..100
      |> Task.async_stream(fn _ -> RateLimiter.hit(key, scale, 10) end,
        max_concurrency: 100,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:allow, _}, &1)) == 10
    assert Enum.count(results, &match?({:deny, _}, &1)) == 90

    for {:deny, milliseconds} <- results, do: assert(milliseconds in 1..scale)
  end

  test "denied keys recover after their actual expiry without sharing another key's quota" do
    scale = 100
    remaining = scale - rem(System.system_time(:millisecond), scale)
    if remaining < 50, do: Process.sleep(remaining + 1)
    key = unique_key()

    assert {:allow, 1} = RateLimiter.hit(key, scale, 1)
    assert {:deny, milliseconds} = RateLimiter.hit(key, scale, 1)
    assert {:allow, 1} = RateLimiter.hit(unique_key(), scale, 1)
    Process.sleep(milliseconds + 10)
    assert {:allow, 1} = RateLimiter.hit(key, scale, 1)
  end

  test "HTTP durations round up while backend durations remain milliseconds" do
    for {milliseconds, seconds} <- [{0, 1}, {1, 1}, {999, 1}, {1000, 1}, {1001, 2}, {60_000, 60}] do
      assert RateLimiter.retry_after_seconds(milliseconds) == seconds
    end
  end

  test "the Redis backend rejects fractional-second windows before accessing a connection" do
    Application.put_env(:kith, RateLimiter, backend: :redis)

    assert_raise ArgumentError, "Redis rate-limit windows must be whole seconds", fn ->
      RateLimiter.hit(unique_key(), 1500, 1)
    end
  end

  defp unique_key, do: "limiter-test:#{System.unique_integer([:positive])}"
end
