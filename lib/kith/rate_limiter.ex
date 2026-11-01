defmodule Kith.RateLimiter do
  @moduledoc """
  Named rules and the shared fixed-window rate limiter.

  `hit/3` returns `{:allow, count}` or `{:deny, retry_after_ms}`. Both web
  requests and worker imports use the same supervised backend. Backend errors
  fail the caller rather than silently allowing traffic or switching counters.
  """

  alias Kith.RateLimiter.{ETS, Redis}

  @login_limit {10, 60_000}
  @signup_limit {5, 60_000}
  @totp_limit {10, 60_000}
  @api_limit {1000, 3_600_000}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(_opts) do
    case backend() do
      :ets ->
        ETS.start_link(clean_period: :timer.minutes(10))

      :redis ->
        start_redis()
    end
  end

  @doc "Records a hit; denial includes the remaining fixed-window time in milliseconds."
  def hit(key, scale_ms, limit)
      when is_binary(key) and is_integer(scale_ms) and scale_ms > 0 and is_integer(limit) and
             limit > 0 do
    case backend() do
      :ets ->
        ETS.hit(key, scale_ms, limit)

      :redis ->
        # Hammer.Redis uses second-granularity EXPIREAT. A fractional-second
        # window could expire early and admit requests beyond the budget.
        if rem(scale_ms, 1000) != 0 do
          raise ArgumentError, "Redis rate-limit windows must be whole seconds"
        end

        Redis.hit(key, scale_ms, limit)
    end
  end

  @doc "Rounds a retry duration up for the HTTP Retry-After header."
  def retry_after_seconds(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    max(1, div(milliseconds + 999, 1000))
  end

  def check_login(ip) do
    {limit, period} = @login_limit
    check("login:#{format_ip(ip)}", limit, period)
  end

  def check_signup(ip) do
    {limit, period} = @signup_limit
    check("signup:#{format_ip(ip)}", limit, period)
  end

  def check_totp(ip) do
    {limit, period} = @totp_limit
    check("totp_ip:#{format_ip(ip)}", limit, period)
  end

  def check_totp_user(user_id) do
    {limit, period} = @totp_limit
    check("totp_user:#{user_id}", limit, period)
  end

  def check_api(account_id) do
    {limit, period} = @api_limit
    check("api:#{account_id}", limit, period)
  end

  defp check(key, limit, period) do
    case hit(key, period, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  defp backend do
    case Keyword.get(configuration(), :backend, :ets) do
      backend when backend in [:ets, :redis] -> backend
      _ -> raise ArgumentError, "Rate-limit backend must be :ets or :redis"
    end
  end

  defp start_redis do
    url = Keyword.fetch!(configuration(), :redis_url)

    case Redix.start_link(url, name: Redis, sync_connect: true, timeout: 5000) do
      {:ok, pid} ->
        case Redis.validate_version(pid) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp configuration, do: Application.get_env(:kith, __MODULE__, [])

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
end
