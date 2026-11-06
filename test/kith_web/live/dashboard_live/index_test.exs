defmodule KithWeb.DashboardLive.IndexTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  test "recent contacts display stored avatars and retain initials for contacts without one", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)
    {photo, _binary} = Kith.AvatarFixtures.stored_photo(contact)
    {:ok, contact} = Kith.Contacts.set_avatar(contact, photo)
    without_avatar = contact_fixture(user.account_id, %{first_name: "Alice", last_name: "Smith"})

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    avatar_id = "#recent-contact-avatar-#{contact.id}"
    url = Kith.Storage.url(contact.avatar)
    assert has_element?(view, ~s|#{avatar_id}[phx-hook="ImgFallback"] img[src="#{url}"]|)

    fallback_id = "#recent-contact-avatar-#{without_avatar.id}"
    assert has_element?(view, "#{fallback_id} span", "AS")
    refute has_element?(view, "#{fallback_id} img")
  end
end
