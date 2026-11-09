defmodule KithWeb.AuthPolicyTest do
  use KithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures
  alias Kith.Accounts

  setup do
    old = Application.get_env(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, old) end)
    :ok
  end

  defp disable_password do
    Application.put_env(:kith, :auth, %{
      password_login_enabled: false,
      registration_enabled: true,
      oidc_enabled: false,
      oidc: nil
    })
  end

  test "direct password and registration auto-login POSTs are blocked", %{conn: conn} do
    user = user_fixture()
    disable_password()

    for path <- [
          "/users/log-in",
          "/users/log-in?_action=registered",
          "/users/log-in?_action=confirmed"
        ] do
      response =
        post(conn, path, %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(response, :user_token)
      assert redirected_to(response) == "/users/log-in"
      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "disabled"
    end
  end

  test "API password token issuance is disabled even with valid credentials", %{conn: conn} do
    user = user_fixture()
    disable_password()

    response =
      post(conn, "/api/auth/token", %{"email" => user.email, "password" => valid_user_password()})

    assert %{"status" => 403, "detail" => detail} = json_response(response, 403)
    assert detail =~ "disabled"
  end

  test "password UI and public password signup and recovery routes close", %{conn: conn} do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    disable_password()
    {:ok, view, html} = live(conn, "/users/log-in")
    refute html =~ "Forgot password?"
    refute has_element?(view, "#login_form")
    refute html =~ "Sign up"

    for path <- ["/users/register", "/users/reset-password", "/users/reset-password/#{token}"] do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, path)
    end

    assert Accounts.get_user_by_reset_password_token(token)
  end

  test "connected registration events cannot bypass a changed policy", %{conn: conn} do
    {:ok, view, _} = live(conn, "/users/register")
    disable_password()
    email = unique_user_email()

    render_submit(view, "save", %{
      "user" => %{"email" => email, "password" => valid_user_password()}
    })

    refute Accounts.get_user_by_email(email)
  end

  test "connected recovery request and old reset token cannot bypass disabling", %{conn: conn} do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    {:ok, forgot, _} = live(conn, "/users/reset-password")
    {:ok, reset, _} = live(conn, "/users/reset-password/#{token}")
    assert_received {:email, _}
    disable_password()
    render_submit(forgot, "send_email", %{"user" => %{"email" => user.email}})
    refute_received {:email, _}

    render_submit(reset, "reset", %{
      "user" => %{"password" => "new password123", "password_confirmation" => "new password123"}
    })

    assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    assert Accounts.get_user_by_reset_password_token(token)
  end

  test "registration permission is rechecked on connected save", %{conn: conn} do
    {:ok, view, _} = live(conn, "/users/register")

    Application.put_env(:kith, :auth, %{
      password_login_enabled: true,
      registration_enabled: false,
      oidc_enabled: false
    })

    email = unique_user_email()

    render_submit(view, "save", %{
      "user" => %{"email" => email, "password" => valid_user_password()}
    })

    refute Accounts.get_user_by_email(email)
  end

  test "password challenge issued before disabling cannot finish login", %{conn: conn} do
    user = user_fixture()
    secret = Accounts.generate_totp_secret()
    code = :pot.totp(secret)

    {:ok, _} =
      Accounts.enable_totp(%{user | authenticated_at: DateTime.utc_now(:second)}, secret, code)

    pending =
      post(conn, "/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(pending) == "/users/two-factor"
    token = get_session(pending, :totp_token)
    disable_password()

    response =
      post(conn, "/users/totp-verify", %{"totp_token" => token, "totp" => %{"code" => code}})

    refute get_session(response, :user_token)
    assert redirected_to(response) == "/users/log-in"
  end

  test "existing sessions and bearer credentials remain valid", %{conn: conn} do
    user = user_fixture()
    session = Accounts.generate_user_session_token(user)
    {bearer, _} = Accounts.generate_api_token(user)
    conn = log_in_user(conn, user)
    disable_password()
    assert Accounts.get_user_by_session_token(session)
    assert Accounts.get_user_by_api_token(bearer)
    assert get(conn, "/users/settings").status == 200
  end
end
