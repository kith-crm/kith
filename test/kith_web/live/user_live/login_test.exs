defmodule KithWeb.UserLive.LoginTest do
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures

  test "OIDC-only signup and reauthentication use escaped provider label", %{conn: conn} do
    old = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, old) end)

    Application.put_env(:kith, :auth, %{
      old
      | password_login_enabled: false,
        oidc_enabled: true,
        oidc: [display_name: "<Provider>"]
    })

    {:ok, login, html} = live(conn, "/users/log-in")
    assert has_element?(login, "a[href='/auth/oidc']", "Continue with <Provider>")
    assert html =~ "&lt;Provider&gt;"
    assert has_element?(login, "a[href='/auth/oidc']", "Sign up")
    refute has_element?(login, "#login_form")
    assert {:error, {:redirect, %{to: "/auth/oidc"}}} = live(conn, "/users/register")
    {:ok, reauth, _} = conn |> log_in_user(user_fixture()) |> live("/users/log-in")
    assert has_element?(reauth, "form[action='/users/oidc/reauth'][method='post']")
    refute has_element?(reauth, "a[href='/auth/oidc']")
    reauth |> form("#oidc-reauth-form") |> render_submit()
    assert has_element?(reauth, "#oidc-reauth-form[phx-trigger-action]")
  end

  describe "user login page" do
    test "renders log in page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Forgot password?"
    end

    test "renders reauthentication page if already logged in", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/log-in")

      assert html =~ "reauthenticate"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form", user: %{email: user.email, password: valid_user_password()})

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "redirects to login page with a flash error for invalid credentials", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form", user: %{email: "invalid@email.com", password: "invalid_password"})

      conn = submit_form(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
