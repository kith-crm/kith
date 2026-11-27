defmodule KithWeb.UserLive.SignupControlsTest do
  # async: false because we modify global Application config
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "registration when DISABLE_SIGNUP=true" do
    setup do
      old = Application.get_env(:kith, :auth)

      Application.put_env(:kith, :auth, %{
        password_login_enabled: true,
        registration_enabled: false,
        oidc_enabled: false
      })

      on_exit(fn -> Application.put_env(:kith, :auth, old) end)
      :ok
    end

    test "redirects to login with error message", %{conn: conn} do
      {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/register")
    end

    test "hides signup link on login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      refute html =~ "Sign up"
    end
  end

  describe "registration when DISABLE_SIGNUP=false" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Create an account"
    end

    test "shows signup link on login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Sign up"
    end
  end
end
