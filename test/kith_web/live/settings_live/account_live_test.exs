defmodule KithWeb.SettingsLive.AccountTest do
  use KithWeb.ConnCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures

  @moduletag :integration

  setup :register_and_log_in_user

  describe "mount and access control" do
    test "admin can render the account settings page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/account")
      assert html =~ "Account Settings"
    end

    test "non-admin is redirected with error flash", %{conn: conn} do
      # register_and_log_in_user creates an admin; create a viewer in same account
      viewer = user_fixture(%{role: "viewer"})
      conn = log_in_user(conn, viewer)

      # handle_params does push_navigate, so live/2 returns a redirect error directly
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/settings/account")
    end
  end

  describe "delete account" do
    test "correct account name confirmation enqueues deletion job", %{conn: conn, user: user} do
      account = Kith.Accounts.Scope.for_user(user).account

      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      lv
      |> element("form[phx-submit='delete-account']")
      |> render_change(%{"confirmation" => account.name})

      lv
      |> element("form[phx-submit='delete-account']")
      |> render_submit()

      assert_enqueued(worker: Kith.Workers.AccountDeletionWorker, args: %{account_id: account.id})
    end

    test "wrong account name shows error flash and no job is enqueued", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      lv
      |> element("form[phx-submit='delete-account']")
      |> render_change(%{"confirmation" => "wrong-name"})

      html =
        lv
        |> element("form[phx-submit='delete-account']")
        |> render_submit()

      assert html =~ "Account name does not match"
      refute_enqueued(worker: Kith.Workers.AccountDeletionWorker)
    end
  end

  describe "reset account" do
    test ~s(typing "RESET" and submitting enqueues reset job and shows success flash), %{
      conn: conn,
      user: user
    } do
      account = Kith.Accounts.Scope.for_user(user).account

      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      lv
      |> element("form[phx-submit='reset-account']")
      |> render_change(%{"confirmation" => "RESET"})

      html =
        lv
        |> element("form[phx-submit='reset-account']")
        |> render_submit(%{"confirmation" => "RESET"})

      assert html =~ "Account data reset has been queued"
      assert_enqueued(worker: Kith.Workers.AccountResetWorker, args: %{account_id: account.id})
    end

    test "submitted confirmation is checked even when validation has not run", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      html = render_submit(lv, "reset-account", %{"confirmation" => "RESET"})

      assert html =~ "Account data reset has been queued"

      assert_enqueued(
        worker: Kith.Workers.AccountResetWorker,
        args: %{account_id: user.account_id}
      )
    end

    test "wrong confirmation shows error flash and no job is enqueued", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/account")

      lv
      |> element("form[phx-submit='reset-account']")
      |> render_change(%{"confirmation" => "reset"})

      html =
        lv
        |> element("form[phx-submit='reset-account']")
        |> render_submit()

      assert html =~ "Type RESET exactly to confirm"
      refute_enqueued(worker: Kith.Workers.AccountResetWorker)
    end
  end
end
