defmodule KithWeb.UserLive.RegistrationTest do
  # async: false — this module flips :require_tos_acceptance, which is
  # node-global. See the note in Kith.Accounts.TosAcceptanceTest.
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create an account"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/dashboard")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "bad", "password" => "short"})

      assert result =~ "must have the @ sign"
      assert result =~ "should be at least 12 character"
    end
  end

  describe "register user" do
    test "creates account and triggers auto-login", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      result =
        lv
        |> form("#registration_form", user: %{email: email, password: valid_user_password()})
        |> render_submit()

      # After successful registration, phx-trigger-action submits the form
      # to the session controller for auto-login. Password inputs don't render
      # values in HTML, so we verify the LiveView side here; the browser
      # handles the actual POST with the typed password.
      assert result =~ "phx-trigger-action"
      assert Kith.Accounts.get_user_by_email(email)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email, "password" => valid_user_password()}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "Registration with ToS required" do
    setup do
      original = Application.get_env(:kith, :require_tos_acceptance, false)
      Application.put_env(:kith, :require_tos_acceptance, true)
      on_exit(fn -> Application.put_env(:kith, :require_tos_acceptance, original) end)
      :ok
    end

    test "shows ToS checkbox when required", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Terms of Service"
    end

    test "requires ToS acceptance for registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: %{email: unique_user_email(), password: valid_user_password()}
        )
        |> render_submit()

      assert result =~ "you must accept the Terms of Service"
    end
  end
end
