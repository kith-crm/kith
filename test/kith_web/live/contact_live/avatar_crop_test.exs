defmodule KithWeb.ContactLive.AvatarCropTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  alias Kith.Contacts

  setup :register_and_log_in_user

  test "choosing an existing photo opens a crop dialog without changing the avatar", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)
    photo = photo_fixture(contact)
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

    render_click(view, "pick-avatar-photo", %{"id" => Integer.to_string(photo.id)})
    assert has_element?(view, "#avatar-crop-dialog[role=dialog]")
    assert has_element?(view, "#avatar-crop-editor[data-source]")
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == nil

    view |> element("button", "Cancel") |> render_click()
    refute has_element?(view, "#avatar-crop-dialog")
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == nil
  end

  test "a photo from another contact cannot be selected", %{conn: conn, user: user} do
    contact = contact_fixture(user.account_id)
    other = contact_fixture(user.account_id)
    photo = photo_fixture(other)
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

    render_click(view, "pick-avatar-photo", %{"id" => Integer.to_string(photo.id)})
    refute has_element?(view, "#avatar-crop-dialog")
    assert render(view) =~ "Photo not found"
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == nil
  end

  test "a failed crop shows an error and retains the previous avatar", %{conn: conn, user: user} do
    contact = contact_fixture(user.account_id)
    {photo, _original} = Kith.AvatarFixtures.stored_photo(contact)
    {:ok, contact} = Contacts.set_avatar(contact, photo)
    before = Kith.DAV.Store.sync_state(user.account_id)

    on_exit(fn ->
      Kith.Storage.delete(photo.storage_key)
      Kith.Storage.delete(contact.avatar)
    end)

    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    render_click(view, "pick-avatar-photo", %{"id" => Integer.to_string(photo.id)})

    render_submit(view, "upload-avatar", %{
      "crop" => %{"x" => "-1", "y" => "0", "width" => "50", "height" => "50"}
    })

    assert render(view) =~ "Could not save this avatar"
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == contact.avatar
    assert Kith.DAV.Store.sync_state(user.account_id) == before
  end

  test "saving a chosen crop stores a processed avatar and preserves its source", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)
    {photo, original} = Kith.AvatarFixtures.stored_photo(contact, width: 900, height: 600)
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    render_click(view, "pick-avatar-photo", %{"id" => Integer.to_string(photo.id)})

    render_submit(view, "upload-avatar", %{
      "crop" => %{"x" => "300", "y" => "100", "width" => "400", "height" => "400"}
    })

    refute has_element?(view, "#avatar-crop-dialog")
    updated = Contacts.get_contact!(user.account_id, contact.id)
    assert is_binary(updated.avatar)
    assert updated.avatar != photo.storage_key
    assert Kith.Storage.read(photo.storage_key) == {:ok, original}
    {:ok, bytes} = Kith.Storage.read(updated.avatar)
    image = Image.from_binary!(bytes)
    assert {Image.width(image), Image.height(image)} == {400, 400}
    assert byte_size(bytes) <= 512 * 1024

    on_exit(fn ->
      Kith.Storage.delete(photo.storage_key)
      Kith.Storage.delete(updated.avatar)
    end)
  end

  test "a failed new upload leaves photos and DAV revision unchanged", %{conn: conn, user: user} do
    contact = contact_fixture(user.account_id)
    Kith.DAV.Store.ensure_rows(user.account_id)
    before = Kith.DAV.Store.sync_state(user.account_id)
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    render_click(view, "toggle-avatar-picker")

    upload =
      file_input(view, "#avatar-upload-form", :avatar, [
        %{
          name: "broken.png",
          content: "not an image",
          type: "image/png"
        }
      ])

    render_upload(upload, "broken.png")

    render_submit(view, "upload-avatar", %{
      "crop" => %{"x" => "0", "y" => "0", "width" => "1", "height" => "1"}
    })

    assert render(view) =~ "Could not save this avatar"
    assert Contacts.list_photos(contact.id) == []
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == nil
    assert Kith.DAV.Store.sync_state(user.account_id) == before
  end

  test "unsupported uploads display validation errors without opening the crop dialog", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    render_click(view, "toggle-avatar-picker")

    upload =
      file_input(view, "#avatar-upload-form", :avatar, [
        %{
          name: "unsupported.txt",
          content: "not an image",
          type: "text/plain"
        }
      ])

    assert {:error, _} = render_upload(upload, "unsupported.txt")
    refute has_element?(view, "#avatar-crop-dialog")
    assert render(view) =~ "Choose a JPEG, PNG, GIF, or WebP image"
  end
end
