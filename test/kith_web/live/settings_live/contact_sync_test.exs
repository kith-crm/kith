defmodule KithWeb.SettingsLive.ContactSyncTest do
  use KithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Kith.Accounts.DavAppPasswords
  @moduletag token_authenticated_at: DateTime.utc_now(:second)
  setup :register_and_log_in_user

  test "viewers can access personal sync without managing integrations", %{conn: conn} do
    user = Kith.AccountsFixtures.user_fixture(%{role: "viewer"})
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/settings/contact-sync")
    assert has_element?(view, "#dav-app-passwords")
    assert has_element?(view, "#carddav-url")
    refute has_element?(view, "a[href='/settings/integrations']")
  end

  test "creation is focused, owned and revealed only until navigation", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/settings/contact-sync")
    refute has_element?(view, "#dav-password-form")
    view |> element("a[href='/settings/contact-sync/new']", "Create") |> render_click()
    view |> form("#dav-password-form", credential: %{name: "Phone"}) |> render_submit()
    assert has_element?(view, "#dav-secret[readonly]")
    assert has_element?(view, "#dav-secret-copy [x-show=copied][role=status][aria-live=polite]")
    [row] = DavAppPasswords.list(user)
    assert row.name == "Phone"

    secret =
      view
      |> element("#dav-secret")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    assert {:ok, _} = DavAppPasswords.authenticate(user.email, secret)
    refute render(view) =~ "data-copy-value=\"#{secret}"
    view |> element("a", "Done") |> render_click()
    refute render(view) =~ secret

    {:error, {:live_redirect, %{to: "/settings/contact-sync"}}} =
      live(conn, "/settings/contact-sync/created")

    {:ok, reconnected, _} = live(conn, "/settings/contact-sync")
    refute render(reconnected) =~ secret
    refute has_element?(reconnected, "#dav-secret")
  end

  test "invalid names and cross-owner revocation are rejected", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/settings/contact-sync/new")
    view |> form("#dav-password-form", credential: %{name: ""}) |> render_submit()
    assert render(view) =~ "can&#39;t be blank"

    other =
      Kith.AccountsFixtures.user_fixture()
      |> Map.put(:authenticated_at, DateTime.utc_now(:second))

    {:ok, row, _} = DavAppPasswords.create(other, %{name: "Other private device"})
    render_click(view, "revoke", %{"id" => row.id, "user_id" => other.id})
    assert hd(DavAppPasswords.list(other)).revoked_at == nil
    refute render(view) =~ "Other private device"
    assert DavAppPasswords.list(user) == []
  end

  test "owned revoke asks for confirmation and reports success", %{conn: conn, user: user} do
    {:ok, row, _} =
      DavAppPasswords.create(%{user | authenticated_at: DateTime.utc_now(:second)}, %{
        name: "Android"
      })

    {:ok, view, _} = live(conn, "/settings/contact-sync/#{row.id}/revoke")
    assert render(view) =~ "Android"
    view |> element("button", "Revoke app password") |> render_click()
    assert hd(DavAppPasswords.list(user)).revoked_at
    assert render(view) =~ "App password revoked"
  end

  test "stale mutations return safely without replay", %{conn: conn, user: user} do
    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
      )

    {:ok, view, _} = live(conn, "/settings/contact-sync/new")
    view |> form("#dav-password-form", credential: %{name: "Phone"}) |> render_submit()
    assert_redirect(view, "/settings/contact-sync/reauth?return_to=new")
    assert DavAppPasswords.list(user) == []
  end

  test "HTTP pages are not cached and reauth return is fixed local allowlist", %{conn: conn} do
    response = get(conn, "/settings/contact-sync")
    assert "no-store" in get_resp_header(response, "cache-control")
    response = get(conn, "/settings/contact-sync/reauth?return_to=new")
    assert redirected_to(response) == "/users/log-in"
    assert get_session(response, :user_return_to) == "/settings/contact-sync/new"
    response = get(conn, "/settings/contact-sync/reauth?return_to=https://evil.example")
    assert get_session(response, :user_return_to) == "/settings/contact-sync"
  end

  test "socket events recheck expired authentication for revoke", %{conn: conn, user: user} do
    {:ok, row, _} =
      DavAppPasswords.create(%{user | authenticated_at: DateTime.utc_now(:second)}, %{
        name: "Phone"
      })

    {:ok, view, _} = live(conn, "/settings/contact-sync/#{row.id}/revoke")

    :sys.replace_state(view.pid, fn state ->
      stale = %{
        state.socket.assigns.current_scope.user
        | authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
      }

      socket =
        Phoenix.Component.assign(state.socket, :current_scope, %{
          state.socket.assigns.current_scope
          | user: stale
        })

      %{state | socket: socket}
    end)

    render_click(view, "revoke", %{"id" => row.id})
    assert_redirect(view, "/settings/contact-sync/reauth?return_to=index")
    assert hd(DavAppPasswords.list(user)).revoked_at == nil
  end

  test "compatibility instructions follow password policy", %{conn: conn} do
    auth = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, auth) end)
    {:ok, view, _} = live(conn, "/settings/contact-sync")
    assert render(view) =~ "account password also works"
    assert has_element?(view, "details summary", "DAVx5 (Android)")
    Application.put_env(:kith, :auth, %{auth | password_login_enabled: false})
    {:ok, view, _} = live(conn, "/settings/contact-sync")
    refute render(view) =~ "account password also works"
    assert has_element?(view, "a", "Create app password")
  end

  test "editor access and authenticated confirmed boundary", %{conn: conn, user: user} do
    editor = Kith.AccountsFixtures.user_fixture(%{role: "editor"})
    {:ok, view, _} = live(log_in_user(conn, editor), "/settings/contact-sync")
    assert has_element?(view, "#dav-app-passwords")

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), "/settings/contact-sync")

    optin = Application.get_env(:kith, :signup_double_optin, false)
    on_exit(fn -> Application.put_env(:kith, :signup_double_optin, optin) end)
    Application.put_env(:kith, :signup_double_optin, true)
    unconfirmed = Kith.Repo.update!(Ecto.Changeset.change(user, confirmed_at: nil))

    assert {:error, {:redirect, %{to: "/users/confirm-email"}}} =
             live(log_in_user(conn, unconfirmed), "/settings/contact-sync")
  end

  test "creation ignores forged owner and does not replay the revealed result", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, "/settings/contact-sync/new")
    other = Kith.AccountsFixtures.user_fixture()

    render_submit(view, "create", %{
      "credential" => %{"name" => "<script>device</script>", "user_id" => other.id}
    })

    assert has_element?(view, "#dav-secret")
    refute has_element?(view, "script", "device")
    assert render(view) =~ "&lt;script&gt;device&lt;/script&gt;"
    render_submit(view, "create", %{"credential" => %{"name" => "Replay"}})
    assert length(DavAppPasswords.list(user)) == 1
    assert DavAppPasswords.list(other) == []
  end

  test "integrations retains personal sync link", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings/integrations")
    assert has_element?(view, "a[href='/settings/contact-sync']", "Contact sync")
    refute has_element?(view, "#carddav-url")
  end
end
