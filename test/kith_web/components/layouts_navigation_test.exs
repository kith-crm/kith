defmodule KithWeb.LayoutsNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Kith.Accounts.User
  alias KithWeb.Layouts

  defp render_navigation(path, role \\ "admin") do
    render_component(&Layouts.app/1,
      current_scope: %{user: %User{email: "navigation@example.com", role: role}},
      current_path: path,
      flash: %{},
      inner_block: []
    )
    |> LazyHTML.from_fragment()
  end

  test "mobile navigation has three primary links and More, with no Jobs destination for any role" do
    for role <- ["admin", "editor", "viewer"] do
      dom = render_navigation("/dashboard", role)
      mobile = LazyHTML.query(dom, "nav[aria-label='Mobile navigation']")

      assert LazyHTML.attribute(LazyHTML.query(mobile, "a:not([role='menuitem'])"), "href") == [
               "/dashboard",
               "/contacts",
               "/users/settings"
             ]

      assert LazyHTML.text(LazyHTML.query(mobile, "#mobile-more-button")) =~ "More"

      assert LazyHTML.attribute(LazyHTML.query(mobile, "[role='menuitem']"), "href") == [
               "/reminders/upcoming",
               "/journal"
             ]

      assert Enum.empty?(LazyHTML.query(mobile, "a[href='/admin/oban']"))
      refute LazyHTML.text(mobile) =~ "Jobs"
    end
  end

  test "desktop Jobs link keeps its existing role gate" do
    assert Enum.count(
             LazyHTML.query(render_navigation("/dashboard"), "aside a[href='/admin/oban']")
           ) == 1

    for role <- ["editor", "viewer"] do
      assert Enum.empty?(
               LazyHTML.query(
                 render_navigation("/dashboard", role),
                 "aside a[href='/admin/oban']"
               )
             )
    end
  end

  test "Settings is current in desktop and mobile navigation on both settings route families" do
    for path <- [
          "/users/settings",
          "/users/settings/confirm-email/token",
          "/settings/account",
          "/settings/tags"
        ] do
      dom = render_navigation(path)
      current = LazyHTML.query(dom, "a[href='/users/settings'][aria-current='page']")
      assert Enum.count(current) == 2
    end
  end

  test "settings lookalike prefixes do not activate Settings" do
    for path <- ["/settings-other", "/users/settings-other", "/dashboard"] do
      dom = render_navigation(path)
      assert Enum.empty?(LazyHTML.query(dom, "a[href='/users/settings'][aria-current='page']"))
    end
  end

  test "More and its matching child reflect the current destination" do
    for {path, href} <- [
          {"/journal", "/journal"},
          {"/journal/entry", "/journal"},
          {"/reminders/upcoming", "/reminders/upcoming"}
        ] do
      dom = render_navigation(path)

      assert LazyHTML.attribute(LazyHTML.query(dom, "#mobile-more-button"), "aria-current") == [
               "page"
             ]

      assert LazyHTML.attribute(
               LazyHTML.query(dom, "#mobile-more-menu [aria-current='page']"),
               "href"
             ) == [href]
    end

    for path <- ["/dashboard", "/journaling", "/reminders-other"] do
      assert LazyHTML.attribute(
               LazyHTML.query(render_navigation(path), "#mobile-more-button"),
               "aria-current"
             ) == []
    end
  end

  test "More exposes a named, controlled menu and mobile logout has an accessible name" do
    dom = render_navigation("/dashboard")
    trigger = LazyHTML.query(dom, "#mobile-more-button")
    assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(trigger, "aria-controls") == ["mobile-more-menu"]
    assert LazyHTML.attribute(trigger, "aria-haspopup") == ["menu"]

    assert Enum.count(
             LazyHTML.query(dom, "#mobile-more-menu[role='menu'][aria-label='More destinations']")
           ) == 1

    assert LazyHTML.attribute(
             LazyHTML.query(dom, "header a[href='/users/log-out']"),
             "aria-label"
           ) == ["Log out"]
  end
end
