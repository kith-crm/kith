defmodule KithWeb.API.AuthController do
  @moduledoc """
  API authentication endpoints for bearer token management.

  POST /api/auth/token   — generate a new API token (email + password + optional TOTP)
  DELETE /api/auth/token  — revoke the current token
  DELETE /api/auth/token/:id — revoke a specific token by DB id
  """

  use KithWeb, :controller

  alias Kith.Accounts
  alias Kith.Auth.Policy

  plug :require_password_login when action == :create

  defp require_password_login(conn, _opts) do
    if Policy.password_login_enabled?() do
      conn
    else
      conn
      |> put_status(403)
      |> put_resp_content_type("application/problem+json")
      |> json(%{
        type: "about:blank",
        title: "Forbidden",
        status: 403,
        detail: "Password login is disabled."
      })
      |> halt()
    end
  end

  def create(conn, %{"email" => email, "password" => password} = params) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        unauthorized_response(conn, "Invalid email or password.")

      user ->
        authenticate_with_optional_totp(conn, user, params["totp_code"])
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> put_resp_content_type("application/problem+json")
    |> json(%{
      type: "about:blank",
      title: "Bad Request",
      status: 400,
      detail: "Missing email and password."
    })
  end

  defp authenticate_with_optional_totp(conn, %{totp_enabled: false} = user, _totp_code) do
    issue_token(conn, user)
  end

  defp authenticate_with_optional_totp(conn, _user, totp_code)
       when is_nil(totp_code) or totp_code == "" do
    unauthorized_response(conn, "TOTP code required.")
  end

  defp authenticate_with_optional_totp(conn, user, totp_code) do
    case Kith.RateLimiter.check_totp_user(user.id) do
      :ok -> authenticate_second_factor(conn, user, totp_code)
      {:error, :rate_limited, retry_after_ms} -> second_factor_rate_limited(conn, retry_after_ms)
    end
  end

  defp second_factor_rate_limited(conn, retry_after_ms) do
    conn
    |> put_resp_header(
      "retry-after",
      to_string(Kith.RateLimiter.retry_after_seconds(retry_after_ms))
    )
    |> put_status(429)
    |> put_resp_content_type("application/problem+json")
    |> json(%{
      type: "about:blank",
      title: "Too Many Requests",
      status: 429,
      detail: "Too many authentication code attempts. Please try again later."
    })
  end

  defp authenticate_second_factor(conn, user, totp_code) do
    cond do
      Accounts.valid_totp_code?(user.totp_secret, totp_code) ->
        issue_token(conn, user)

      Accounts.use_recovery_code(user, totp_code) ->
        issue_token(conn, user)

      true ->
        unauthorized_response(conn, "Invalid TOTP code.")
    end
  end

  defp unauthorized_response(conn, detail) do
    conn
    |> put_status(401)
    |> put_resp_content_type("application/problem+json")
    |> json(%{type: "about:blank", title: "Unauthorized", status: 401, detail: detail})
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_api_user

    case Accounts.revoke_api_token(user, id) do
      {:ok, _} ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{
          type: "about:blank",
          title: "Not Found",
          status: 404,
          detail: "Token not found."
        })
    end
  end

  def delete_current(conn, _params) do
    raw_token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> String.trim(token)
        _ -> nil
      end

    if raw_token do
      Accounts.revoke_api_token_by_value(raw_token)
    end

    send_resp(conn, 204, "")
  end

  defp issue_token(conn, user) do
    {raw_token, _token_record} = Accounts.generate_api_token(user)

    conn
    |> put_status(201)
    |> json(%{token: raw_token, expires_at: nil})
  end
end
