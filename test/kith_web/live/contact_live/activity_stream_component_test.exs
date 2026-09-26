defmodule KithWeb.ContactLive.ActivityStreamComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    contact = contact_fixture(user.account_id)
    %{contact: contact, account_id: user.account_id}
  end

  describe "photo timeline entries" do
    test "timeline mode renders an <img> pointing at the storage URL", %{
      conn: conn,
      contact: contact
    } do
      photo = photo_fixture(contact, %{"file_name" => "beach.jpg"})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      assert html =~ ~s(src="#{Kith.Storage.url(photo.storage_key)}")
      assert html =~ ~s(alt="beach.jpg")
      assert html =~ "size-[72px] rounded-lg object-cover"
    end

    test "photos gallery mode renders an <img> for the tile", %{conn: conn, contact: contact} do
      photo = photo_fixture(contact, %{"file_name" => "portrait.jpg"})

      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

      html =
        view
        |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
        |> render_click()

      assert html =~ "grid-cols-3"
      assert html =~ ~s(src="#{Kith.Storage.url(photo.storage_key)}")
      assert html =~ "w-full h-full object-cover"
    end

    test "each thumbnail is an isolated stateful component with the 404 fallback wired", %{
      conn: conn,
      contact: contact
    } do
      photo = photo_fixture(contact, %{"file_name" => "hike.jpg"})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      # Stateful LiveComponent per photo -> its own change-tracking scope.
      assert html =~ ~s(id="photo-#{photo.id}")
      # CSP-safe broken-image detection instead of an inline onerror.
      assert html =~ ~s(phx-hook="ImgFallback")
      # Distinct "unavailable" state, hidden until the <img> actually errors.
      assert html =~ "Image unavailable"
      assert html =~ "group-data-[img-failed]:hidden"
    end

    test "pending-sync photo keeps the placeholder and renders no image for it", %{
      conn: conn,
      contact: contact
    } do
      photo_fixture(contact, %{"storage_key" => "pending_sync:immich-abc123"})

      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")

      refute html =~ ~s(src="#{Kith.Storage.url("pending_sync:immich-abc123")}")
      assert html =~ "Syncing"
      assert html =~ "from-stone-100"

      # Also placeholder-only in gallery mode.
      gallery_html =
        view
        |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
        |> render_click()

      refute gallery_html =~ ~s(src="#{Kith.Storage.url("pending_sync:immich-abc123")}")
      assert gallery_html =~ "Syncing"
    end
  end
end
