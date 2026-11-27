defmodule KithWeb.Plugs.ApiRateLimiter do
  @moduledoc """
  Per-account rate limiting for API requests.

  1000 requests per hour per account. Adds rate limit headers to all responses.
  Must be placed AFTER `FetchApiUser` in the pipeline.
  """

  import Plug.Conn

  @default_limit 1000
  @default_period 3_600_000

  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      period: Keyword.get(opts, :period, @default_period)
    }
  end

  def call(conn, %{limit: limit, period: period}) do
    case conn.assigns[:current_scope] do
      %{user: %{account_id: account_id}} when not is_nil(account_id) ->
        key = "api_rate:account:#{account_id}"
        started_at = System.system_time(:millisecond)

        case Kith.RateLimiter.hit(key, period, limit) do
          {:allow, count} ->
            remaining = max(limit - count, 0)
            reset_at = (div(started_at, period) + 1) * period

            conn
            |> put_resp_header("x-ratelimit-limit", to_string(limit))
            |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
            |> put_reset_header(reset_at)

          {:deny, retry_after_ms} ->
            retry_after = Kith.RateLimiter.retry_after_seconds(retry_after_ms)

            # The backend samples time during the hit. Round the estimate from
            # our earlier sample up to the fixed-window boundary.
            reset_at = div(started_at + retry_after_ms + period - 1, period) * period

            conn
            |> put_resp_content_type("application/problem+json")
            |> put_resp_header("retry-after", to_string(retry_after))
            |> put_resp_header("x-ratelimit-limit", to_string(limit))
            |> put_resp_header("x-ratelimit-remaining", "0")
            |> put_reset_header(reset_at)
            |> put_status(429)
            |> Phoenix.Controller.json(%{
              type: "about:blank",
              title: "Too Many Requests",
              status: 429,
              detail: "Account API rate limit exceeded. Try again in #{retry_after} seconds."
            })
            |> halt()
        end

      _ ->
        # No account context (shouldn't happen if FetchApiUser ran), pass through
        conn
    end
  end

  defp put_reset_header(conn, reset_at) do
    put_resp_header(conn, "x-ratelimit-reset", to_string(div(reset_at + 999, 1000)))
  end
end
