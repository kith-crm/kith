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
           Accounts.get_user_by_email_and_verified_password(email, password) do
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
      nil -> check_credentials(conn, nil)
      key -> require_auth(conn, key)
    end
  end

  # The failure is counted *before* the password is verified, so N concurrent
  # bad guesses can't all read a stale count (check-then-act). Hammer's ETS
  # backend loses increments when two processes create a bucket at the same
  # time, so the increment is serialized per key on this node.
  defp require_auth(conn, key) do
    case count_attempt(key) do
      {:deny, _limit} -> RateLimiter.deny(conn, retry_after(key))
      {:allow, _count} -> check_credentials(conn, key)
      # Backend unavailable: fail open rather than 500.
      {:error, _reason} -> check_credentials(conn, nil)
    end
  end

  defp count_attempt(key) do
    :global.trans(
      {{__MODULE__, key}, self()},
      fn -> Hammer.check_rate(key, @failure_window_ms, @max_failures) end,
      [node()]
    )
  end

  defp retry_after(key) do
    case Hammer.inspect_bucket(key, @failure_window_ms, @max_failures) do
      {:ok, {_count, _remaining, ms_to_next, _created, _updated}} ->
        max(div(ms_to_next + 999, 1000), 1)

      {:error, _reason} ->
        div(@failure_window_ms, 1000)
    end
  end

  # A success never consumes budget: it clears the pair's count, including
  # the increment made for this request.
  defp check_credentials(conn, key) do
    case authenticate(conn) do
      {:ok, user} ->
        if key, do: Hammer.delete_buckets(key)
        assign(conn, :current_scope, Accounts.Scope.for_user(user))

      {:error, _} ->
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
