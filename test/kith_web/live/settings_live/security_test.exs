defmodule KithWeb.SettingsLive.SecurityTest do
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag token_authenticated_at: DateTime.utc_now(:second)
  setup :register_and_log_in_user

  test "OIDC identity unlink requires confirmation and preserves the last usable method", %{
    conn: conn,
    user: user
  } do
    old = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, old) end)

    Application.put_env(:kith, :auth, %{
      old
      | oidc_enabled: true,
        oidc: [issuer: "https://issuer.test", display_name: "Company"]
    })

    principal = %Kith.Auth.Principal{issuer: "https://issuer.test", subject: "owner"}

    {:ok, identity} =
      Kith.Accounts.OIDC.link(%{user | authenticated_at: DateTime.utc_now(:second)}, principal)

    {:ok, view, _} = live(conn, "/settings/security")
    assert has_element?(view, "#oidc-status", "Connected")
    view |> element("#oidc-unlink-#{identity.id}") |> render_click()
    assert has_element?(view, "#oidc-unlink-confirm")
    assert Kith.Accounts.OIDC.list(user) != []

    Application.put_env(:kith, :auth, %{
      Application.fetch_env!(:kith, :auth)
      | password_login_enabled: false
    })

    view |> element("#oidc-unlink-confirm") |> render_click()
    assert render(view) =~ "last available sign-in method"
    assert Kith.Accounts.OIDC.list(user) != []

    Application.put_env(:kith, :auth, %{
      Application.fetch_env!(:kith, :auth)
      | password_login_enabled: true
    })

    view |> element("#oidc-unlink-confirm") |> render_click()
    assert Kith.Accounts.OIDC.list(user) == []
    assert has_element?(view, "form[action='/users/oidc/link'][method='post']")
    view |> form("#oidc-link-form") |> render_submit()
    assert has_element?(view, "#oidc-link-form[phx-trigger-action]")
  end

  test "password form moves out of profile", %{conn: conn} do
    user = Kith.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, profile, _} = live(conn, "/users/settings")
    refute has_element?(profile, "#password_form")
    {:ok, security, _} = live(conn, "/settings/security")
    assert has_element?(security, "#password_form")
  end

  test "password validation and update keep the existing POST contract", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/settings/security")

    errors =
      view
      |> form("#password_form", user: %{password: "short", password_confirmation: "mismatch"})
      |> render_change()

    assert errors =~ "should be at least 12 character"
    assert errors =~ "does not match password"
    errors = view |> form("#password_form", user: %{password: "short"}) |> render_submit()
    assert errors =~ "should be at least 12 character"

    form =
      form(view, "#password_form",
        user: %{password: "new password value", password_confirmation: "new password value"}
      )

    render_submit(form)
    conn = follow_trigger_action(form(view, "#password_form"), conn)
    assert redirected_to(conn) == "/settings/security"
    assert Kith.Accounts.get_user_by_email_and_password(user.email, "new password value")
  end

  test "disabled password login hides controls and rejects forged events", %{conn: conn} do
    auth = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, auth) end)
    Application.put_env(:kith, :auth, %{auth | password_login_enabled: false})
    {:ok, view, _} = live(conn, "/settings/security")
    refute has_element?(view, "#password_form")
    assert render(view) =~ "Password login is disabled by your administrator."
    render_submit(view, "update_password", %{"user" => %{"password" => "new password value"}})
    refute has_element?(view, "form[phx-trigger-action]")
    render_change(view, "validate_password", %{"user" => %{"password" => "short"}})
    refute has_element?(view, "#password_form")
  end

  test "TOTP status offers only the existing setup flow", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/settings/security")
    assert has_element?(view, "#totp-status", "Not enabled")
    assert has_element?(view, "a[href='/users/totp-setup']", "Set up authenticator app")
    refute has_element?(view, "button", "Manage recovery codes")
    Kith.Repo.update!(Ecto.Changeset.change(user, totp_enabled: true))
    user = %{user | mfa_authenticated_at: DateTime.utc_now(:second)}
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/settings/security")
    assert has_element?(view, "#totp-status", "Enabled")
    refute has_element?(view, "a[href='/users/totp-setup']")
  end

  test "TOTP setup returns to Security", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/users/totp-setup")
    assert has_element?(view, "a[href='/settings/security']", "Cancel")
    Kith.Repo.update!(Ecto.Changeset.change(user, totp_enabled: true))
    user = %{user | mfa_authenticated_at: DateTime.utc_now(:second)}
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/settings/security"}}} = live(conn, "/users/totp-setup")
  end

  test "completed TOTP setup returns to Security", %{conn: conn} do
    {:ok, view, html} = live(conn, "/users/totp-setup")

    secret =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("details code")
      |> LazyHTML.text()
      |> String.trim()

    code = :pot.totp(secret)
    view |> form("#totp_confirm_form", totp: %{code: code}) |> render_submit()
    assert has_element?(view, "a[href='/settings/security']", "I've saved my recovery codes")

    assert {:ok, security, _} =
             view
             |> element("a[href='/settings/security']")
             |> render_click()
             |> follow_redirect(conn)

    assert has_element?(security, "#totp-status", "Enabled")
  end

  test "Security requires authentication and recent authentication", %{conn: conn, user: user} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), "/settings/security")

    stale_conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
      )

    assert {:error, {:redirect, %{to: "/users/reauth?return_to=security"}}} =
             live(stale_conn, "/settings/security")
  end
end
