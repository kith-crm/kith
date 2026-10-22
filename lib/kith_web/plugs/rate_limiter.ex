defmodule KithWeb.Plugs.RateLimiter do
  @moduledoc """
  Configurable per-IP rate limiting plug using Hammer.

  ## Usage in router

      plug KithWeb.Plugs.RateLimiter, limit: 10, period: 60_000, lockout: 900_000

  Options:
    - `:limit` — max requests in the period (required)
    - `:period` — time window in milliseconds (default: 60_000 = 1 minute)
    - `:lockout` — lockout duration in ms after exceeding limit (default: same as period)
    - `:key_prefix` — prefix for the rate limit key (default: request path)
    - `:key_fun` — function `(conn) -> String.t()` for custom key (overrides IP-based key)
  """

  import Plug.Conn

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.get(opts, :period, 60_000),
      lockout: Keyword.get(opts, :lockout),
      key_prefix: Keyword.get(opts, :key_prefix),
      key_fun: Keyword.get(opts, :key_fun)
    }
  end

  def call(conn, %{limit: limit, period: period} = opts) do
    key = build_key(conn, opts)
    scale_ms = opts[:lockout] || period

    case Hammer.check_rate(key, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        deny(conn, div(scale_ms, 1000))
    end
  end

  @doc "Sends a rate limit response with a retry delay in seconds."
  def deny(conn, retry_after) do
    conn
    |> put_resp_content_type(content_type(conn))
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_resp(429, error_body(conn, retry_after))
    |> halt()
  end

  defp build_key(conn, %{key_fun: fun}) when is_function(fun, 1) do
    fun.(conn)
  end

  defp build_key(conn, %{key_prefix: prefix}) do
    ip = client_ip(conn)
    prefix = prefix || conn.request_path
    "rate_limit:#{prefix}:#{ip}"
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp content_type(conn) do
    if api_request?(conn), do: "application/problem+json", else: "text/html"
  end

  defp error_body(conn, retry_after) do
    if api_request?(conn) do
      Jason.encode!(%{
        type: "about:blank",
        title: "Too Many Requests",
        status: 429,
        detail: "Rate limit exceeded. Try again in #{retry_after} seconds."
      })
    else
      "Too many requests. Please try again later."
    end
  end

  defp api_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept] -> String.contains?(accept, "json")
      _ -> String.starts_with?(conn.request_path, "/api")
    end
  end
end
