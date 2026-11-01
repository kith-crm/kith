# Run against a real Redis >= 7 instance:
# KITH_TEST_REDIS_URL=redis://127.0.0.1:6384 MIX_ENV=test mix run --no-start test/fixtures/rate_limiter_redis/probe.ex
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:hammer_backend_redis)

defmodule Kith.RedisRateLimiterProbe do
  use ExUnit.Case, async: false

  alias Kith.RateLimiter

  setup do
    previous = Application.get_env(:kith, RateLimiter)
    url = System.fetch_env!("KITH_TEST_REDIS_URL")
    Application.put_env(:kith, RateLimiter, backend: :redis, redis_url: url)
    {:ok, pid} = RateLimiter.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if previous,
        do: Application.put_env(:kith, RateLimiter, previous),
        else: Application.delete_env(:kith, RateLimiter)
    end)

    %{backend: pid}
  end

  test "real Redis verifies its version and enforces concurrent fixed-window budgets", %{
    backend: backend
  } do
    assert :ok = Kith.RateLimiter.Redis.validate_version(backend)
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
    assert {:allow, 1} = RateLimiter.hit(unique_key(), scale, 10)
  end

  test "a denied counter recovers after its retry duration and expires in Redis" do
    scale = 1000
    remaining = scale - rem(System.system_time(:millisecond), scale)
    if remaining < 200, do: Process.sleep(remaining + 1)
    key = unique_key()
    assert {:allow, 1} = RateLimiter.hit(key, scale, 1)
    assert {:deny, milliseconds} = RateLimiter.hit(key, scale, 1)
    assert milliseconds in 1..1000
    assert RateLimiter.retry_after_seconds(milliseconds) == 1
    Process.sleep(milliseconds + 20)
    assert {:allow, 1} = RateLimiter.hit(key, scale, 1)
  end

  test "Monica workers share a host budget and do not consume another host's quota" do
    previous =
      for key <- [
            :monica_rate_limit,
            :monica_rate_limit_scale_ms,
            :monica_rate_limit_retry_sleep_ms
          ],
          into: %{},
          do: {key, Application.get_env(:kith, key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:kith, key)
        {key, value} -> Application.put_env(:kith, key, value)
      end)
    end)

    Application.put_env(:kith, :monica_rate_limit, 1)
    Application.put_env(:kith, :monica_rate_limit_scale_ms, 1000)
    Application.put_env(:kith, :monica_rate_limit_retry_sleep_ms, 10)
    host = "#{unique_key()}.example"
    other_host = "#{unique_key()}.example"
    remaining = 1000 - rem(System.system_time(:millisecond), 1000)
    if remaining < 200, do: Process.sleep(remaining + 1)

    assert :ok = Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://#{host}/contacts")

    assert :ok =
             Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://#{other_host}/contacts")

    task =
      Task.async(fn ->
        Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://#{host}/notes")
      end)

    assert Task.yield(task, 30) == nil
    assert Task.await(task, 2000) == :ok
  end

  test "Redis connection failure is bounded and cannot fall back to ETS", %{backend: backend} do
    # A failed linked OTP child is allowed to signal EXIT to its starter. The
    # isolated test process traps it just as the production supervisor does.
    Process.flag(:trap_exit, true)
    GenServer.stop(backend)

    Application.put_env(:kith, RateLimiter,
      backend: :redis,
      redis_url: "redis://127.0.0.1:1"
    )

    {elapsed, result} = :timer.tc(fn -> RateLimiter.start_link([]) end)
    assert {:error, _} = result
    assert elapsed < 6_000_000
    assert Process.whereis(Kith.RateLimiter.Redis) == nil
  end

  test "second-factor rules share the user budget and keep password/IP budgets independent" do
    remaining = 60_000 - rem(System.system_time(:millisecond), 60_000)
    if remaining < 1000, do: Process.sleep(remaining + 1)
    user = unique_key()
    ip = unique_key()

    results =
      1..40
      |> Task.async_stream(fn _ -> RateLimiter.check_totp_user(user) end,
        max_concurrency: 40,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &match?({:error, :rate_limited, _}, &1)) == 30
    assert :ok = RateLimiter.check_totp_user(unique_key())
    for _ <- 1..10, do: assert(:ok = RateLimiter.check_totp(ip))
    assert {:error, :rate_limited, milliseconds} = RateLimiter.check_totp(ip)
    assert milliseconds in 1..60_000
    assert :ok = RateLimiter.check_login(ip)
  end

  defp unique_key,
    do: "redis-probe-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
end
