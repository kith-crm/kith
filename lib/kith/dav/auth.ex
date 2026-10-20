defmodule Kith.DAV.Auth do
  @moduledoc """
  HTTP Basic Auth for DAV clients.

  Validates credentials against Kith user accounts. DAV clients (Apple Contacts,
  DAVx5, Thunderbird) send HTTP Basic Auth on every request over TLS.

  Failed attempts are rate-limited per client IP + email (R7): after
  10 failures within 5 minutes that pair gets `429` with `Retry-After`
  until the window ends. Successful requests are never counted, and a
  success clears the failure count.
  """

  import Plug.Conn
  alias Kith.Accounts
  alias KithWeb.Plugs.RateLimiter

  @max_failures 10
  @failure_window_ms 5 * 60_000

  @doc """
  Authenticates the connection using HTTP Basic Auth.

  Returns `{:ok, user}` on success or `{:error, :unauthorized}` on failure.
  """
  def authenticate(conn) do
    with {:ok, email, password} <- credentials(conn),
         %Kith.Accounts.User{confirmed_at: confirmed_at} = user
         when not is_nil(confirmed_at) <-
           Accounts.get_user_by_email_and_password(email, password) do
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Plug-compatible function that requires Basic Auth on the connection.

  On success, assigns `:current_scope` with the authenticated user and account.
  On failure, sends a 401 response with a WWW-Authenticate challenge and halts.
  A client IP + email with too many recent failures gets a 429 instead, without
  its credentials being checked.
  """
  def require_auth(conn) do
    case failure_key(conn) do
      nil -> check_credentials(conn, nil, 0)
      key -> require_auth(conn, key)
    end
  end

  defp require_auth(conn, key) do
    case Hammer.inspect_bucket(key, @failure_window_ms, @max_failures) do
      {:ok, {failures, _remaining, ms_to_next, _created, _updated}}
      when failures >= @max_failures ->
        RateLimiter.deny(conn, max(div(ms_to_next + 999, 1000), 1))

      {:ok, {failures, _remaining, _ms_to_next, _created, _updated}} ->
        check_credentials(conn, key, failures)

      # Backend unavailable (e.g. Redis down): fail open rather than 500.
      {:error, _reason} ->
        check_credentials(conn, key, 0)
    end
  end

  defp check_credentials(conn, key, failures) do
    case authenticate(conn) do
      {:ok, user} ->
        if failures > 0, do: Hammer.delete_buckets(key)
        assign(conn, :current_scope, Accounts.Scope.for_user(user))

      {:error, _} ->
        if key, do: Hammer.check_rate(key, @failure_window_ms, @max_failures)

        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="Kith CardDAV"))
        |> send_resp(401, "Unauthorized")
        |> halt()
    end
  end

  defp credentials(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [email, password] <- String.split(decoded, ":", parts: 2) do
      {:ok, email, password}
    else
      _ -> :error
    end
  end

  # Emails are citext, so case variants of one address share a counter.
  # Requests without credentials (a client's first, challenge-seeking
  # request) can't guess a password and are never counted.
  defp failure_key(conn) do
    case credentials(conn) do
      {:ok, email, _password} ->
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        "dav_auth_failures:#{ip}:#{String.downcase(email)}"

      :error ->
        nil
    end
  end
end
