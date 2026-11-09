defmodule KithWeb.UserLive.SettingsTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures

  @moduletag token_authenticated_at: DateTime.utc_now(:second)
  setup :register_and_log_in_user

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Profile Settings"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert flash["error"] =~ "You must log in"
    end
  end

  describe "update email form" do
    test "updates the user email", %{conn: conn} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", user: %{email: new_email})
        |> render_submit()

      assert result =~ "A link to confirm your email"
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{user: %{email: "bad"}})

      assert result =~ "must have the @ sign"
    end
  end

  test "email confirmation returns to Profile and updates the email", %{conn: conn, user: user} do
    new_email = unique_user_email()

    changed =
      Ecto.Changeset.apply_changes(Kith.Accounts.change_user_email(user, %{email: new_email}))

    token =
      extract_user_token(fn url ->
        Kith.Accounts.deliver_user_update_email_instructions(changed, user.email, url)
      end)

    assert {:error, {:live_redirect, %{to: "/users/settings"}}} =
             live(conn, "/users/settings/confirm-email/#{token}")

    assert Kith.Accounts.get_user!(user.id).email == new_email
  end
end
