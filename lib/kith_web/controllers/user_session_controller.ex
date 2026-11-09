defmodule KithWeb.UserSessionController do
  use KithWeb, :controller

  alias Kith.Accounts
  alias Kith.Auth.{Challenges, Policy}
  alias KithWeb.{Authentication, UserAuth}

  plug :require_password_login when action in [:create, :update_password]

  defp require_password_login(conn, _opts) do
    if Policy.password_login_enabled?() do
      conn
    else
      conn
      |> put_flash(:error, "Password login is disabled.")
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  def reauth(conn, params) do
    destination =
      case params["return_to"] do
        "totp" -> "/users/totp-setup"
        "profile" -> "/users/settings"
        _ -> "/settings/security"
      end

    conn
    |> put_session(:user_return_to, destination)
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/users/log-in")
  end

  def contact_sync_reauth(conn, params) do
    destination =
      if params["return_to"] == "new",
        do: ~p"/settings/contact-sync/new",
        else: ~p"/settings/contact-sync"

    conn
    |> put_session(:user_return_to, destination)
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/users/log-in")
  end

  def create(conn, %{"_action" => "confirmed"} = params) do
    throttled_create(conn, params, "User confirmed successfully.")
  end

  def create(conn, %{"_action" => "registered"} = params) do
    throttled_create(conn, params, "Account created successfully!")
  end

  def create(conn, params) do
    throttled_create(conn, params, "Welcome back!")
  end

  defp throttled_create(conn, params, info) do
    case Kith.RateLimiter.check_login(conn.remote_ip) do
      :ok ->
        create(conn, params, info)

      {:error, :rate_limited, retry_after_ms} ->
        conn
        |> put_resp_header(
          "retry-after",
          to_string(Kith.RateLimiter.retry_after_seconds(retry_after_ms))
        )
        |> put_resp_content_type("text/plain")
        |> send_resp(:too_many_requests, "Too many login attempts. Please try again later.")
        |> halt()
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      current = conn.assigns[:current_scope] && conn.assigns.current_scope.user

      if current && current.id != user.id do
        conn
        |> put_flash(:error, "Authenticate with your current account.")
        |> redirect(to: ~p"/users/log-in")
      else
        conn
        |> put_flash(:info, info)
        |> Authentication.begin(user, %{
          method: :password,
          intent: if(current, do: :reauth, else: :login),
          session_token: get_session(conn, :user_token),
          remember_me: user_params["remember_me"] == "true",
          return_to:
            get_session(conn, :user_return_to) ||
              if(current, do: "/users/settings", else: "/dashboard")
        })
      end
    else
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Verifies TOTP code or recovery code after password authentication.
  """
  def totp_verify(conn, params) do
    case Kith.RateLimiter.check_totp(conn.remote_ip) do
      :ok -> verify_totp_challenge(conn, params)
      {:error, :rate_limited, retry_after_ms} -> totp_rate_limited(conn, retry_after_ms)
    end
  end

  defp verify_totp_challenge(conn, %{"totp_token" => handle, "totp" => %{"code" => code}}) do
    case Challenges.complete(handle, get_session(conn, :auth_challenge_binding), code) do
      {:ok, completion} ->
        Authentication.finish(conn, completion)

      {:error, :rate_limited} ->
        totp_rate_limited(conn, 60_000)

      {:error, :invalid} ->
        if get_session(conn, :totp_token) == handle,
          do:
            conn
            |> put_flash(:error, "Invalid authentication code.")
            |> redirect(to: ~p"/users/two-factor"),
          else: expired_totp_challenge(conn)

      {:error, :expired} ->
        expired_totp_challenge(conn)
    end
  end

  defp verify_totp_challenge(conn, _params), do: expired_totp_challenge(conn)

  defp expired_totp_challenge(conn) do
    conn
    |> delete_session(:totp_token)
    |> put_flash(:error, "Your session has expired. Please log in again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp totp_rate_limited(conn, retry_after_ms) do
    conn
    |> put_resp_header(
      "retry-after",
      to_string(Kith.RateLimiter.retry_after_seconds(retry_after_ms))
    )
    |> put_resp_content_type("text/plain")
    |> send_resp(
      :too_many_requests,
      "Too many authentication code attempts. Please try again later."
    )
    |> halt()
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    with :ok <- Authentication.require_recent(user),
         {:ok, {updated, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      UserAuth.disconnect_sessions(expired_tokens)

      Authentication.finish(conn, %{
        user: updated,
        intent: :login,
        authenticated_at: user.authenticated_at,
        mfa_authenticated_at: user.mfa_authenticated_at,
        return_to: "/settings/security"
      })
    else
      _ ->
        conn
        |> put_flash(:error, "Please authenticate again before changing your password.")
        |> redirect(to: ~p"/users/reauth?return_to=security")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
