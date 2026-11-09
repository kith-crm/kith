defmodule KithWeb.UserSessionController do
  use KithWeb, :controller

  alias Kith.Accounts
  alias Kith.Auth.Policy
  alias KithWeb.UserAuth

  plug :require_password_login when action in [:create, :totp_verify, :update_password]

  @totp_token_max_age 300

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
      if user.totp_enabled do
        # TOTP required — create a signed intermediate token instead of a session
        totp_token =
          Phoenix.Token.sign(conn, "totp_challenge", user.id)

        conn
        |> put_session(:totp_token, totp_token)
        |> put_session(:remember_me, user_params["remember_me"] == "true")
        |> redirect(to: ~p"/users/two-factor")
      else
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)
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

  defp verify_totp_challenge(
         conn,
         %{"totp_token" => totp_token, "totp" => %{"code" => code}} = params
       )
       when is_binary(totp_token) do
    remember_me = params["remember_me"] == "true"

    case Phoenix.Token.verify(conn, "totp_challenge", totp_token, max_age: @totp_token_max_age) do
      {:ok, user_id} ->
        case Kith.RateLimiter.check_totp_user(user_id) do
          :ok -> authenticate_totp(conn, user_id, code, totp_token, remember_me)
          {:error, :rate_limited, retry_after_ms} -> totp_rate_limited(conn, retry_after_ms)
        end

      {:error, _reason} ->
        expired_totp_challenge(conn)
    end
  end

  defp verify_totp_challenge(conn, _params), do: expired_totp_challenge(conn)

  defp authenticate_totp(conn, user_id, code, totp_token, remember_me) do
    user = Accounts.get_user!(user_id)

    cond do
      Accounts.valid_totp_code?(user.totp_secret, code) ->
        conn
        |> delete_session(:totp_token)
        |> put_flash(:info, "Welcome back!")
        |> UserAuth.log_in_user(user, %{"remember_me" => to_string(remember_me)})

      Accounts.use_recovery_code(user, code) ->
        conn
        |> delete_session(:totp_token)
        |> put_flash(
          :info,
          "Welcome back! You used a recovery code. #{Accounts.recovery_code_count(user)} codes remaining."
        )
        |> UserAuth.log_in_user(user, %{"remember_me" => to_string(remember_me)})

      true ->
        conn
        |> put_flash(:error, "Invalid authentication code.")
        |> put_session(:totp_token, totp_token)
        |> put_session(:remember_me, remember_me)
        |> redirect(to: ~p"/users/two-factor")
    end
  end

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

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/settings/security")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
