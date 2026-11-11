defmodule KithWeb.SettingsLive.SettingsLayoutTest do
  use KithWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures
  alias KithWeb.SettingsLive.SettingsLayout

  @paths [
    "/users/settings",
    "/settings/security",
    "/settings/contact-sync",
    "/settings/account",
    "/settings/tags",
    "/settings/emotions",
    "/settings/activity-types",
    "/settings/life-event-types",
    "/settings/integrations",
    "/settings/import",
    "/settings/imports",
    "/settings/export",
    "/settings/audit-log"
  ]
  @admin_paths ["/settings/account", "/settings/integrations", "/settings/audit-log"]

  test "groups preserve destinations allowed by each role" do
    for role <- ["admin", "editor", "viewer"] do
      scope = user_scope_fixture(user_fixture(%{role: role}))
      groups = SettingsLayout.destinations(scope)
      assert Enum.map(groups, & &1.label) == ["Personal", "Workspace", "Data"]
      assert Enum.all?(groups, &(&1.items != []))
      paths = Enum.flat_map(groups, fn group -> Enum.map(group.items, & &1.path) end)

      expected =
        case role do
          "admin" -> @paths
          "editor" -> @paths -- @admin_paths
          "viewer" -> @paths -- (@admin_paths ++ ["/settings/import"])
        end

      assert paths == expected

      html =
        render_component(&SettingsLayout.settings_shell/1,
          current_path: "/settings/security",
          current_scope: scope,
          inner_block: []
        )

      doc = LazyHTML.from_document(html)
      assert LazyHTML.attribute(LazyHTML.query(doc, "nav a"), "href") == paths
      assert LazyHTML.attribute(LazyHTML.query(doc, "select option"), "value") == paths

      assert LazyHTML.attribute(LazyHTML.query(doc, "nav a[aria-current=page]"), "href") == [
               "/settings/security"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "option[selected]"), "value") == [
               "/settings/security"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "label"), "for") == ["settings-destination"]
      assert LazyHTML.text(LazyHTML.query(doc, "label")) == "Settings"

      assert LazyHTML.attribute(LazyHTML.query(doc, "select[disabled]"), "id") == [
               "settings-destination"
             ]
    end
  end

  test "every destination and nested import history select their current location" do
    scope = user_scope_fixture()

    for path <- @paths ++ ["/settings/imports/123"] do
      html =
        render_component(&SettingsLayout.settings_shell/1,
          current_path: path,
          current_scope: scope,
          inner_block: []
        )

      doc = LazyHTML.from_document(html)
      expected = if path == "/settings/imports/123", do: "/settings/imports", else: path

      assert LazyHTML.attribute(LazyHTML.query(doc, "nav a[aria-current=page]"), "href") == [
               expected
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "option[selected]"), "value") == [expected]
    end
  end

  test "non-admin direct routes retain authorization", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "editor"}))

    for path <- @admin_paths do
      expected = if path == "/settings/audit-log", do: "/dashboard", else: "/"
      assert {:error, {_kind, %{to: ^expected}}} = live(conn, path)
    end

    assert {:ok, _, _} = live(conn, "/settings/security")
  end
end
