defmodule KithWeb.DAV.PhotoDeduplicationTest do
  use KithWeb.ConnCase, async: false

  import Kith.ContactsFixtures
  import KithWeb.DAV.TestHelpers

  alias Kith.{AvatarFixtures, Contacts, Storage}
  alias Kith.Contacts.Avatar

  setup :setup_dav_user

  setup %{account_id: account_id} do
    root = Path.join(System.tmp_dir!(), "kith-dav-photo-#{Ecto.UUID.generate()}")
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{contact: contact_fixture(account_id)}
  end

  test "PUT selects the matching legacy original", ctx do
    {source, bytes} = AvatarFixtures.stored_photo(ctx.contact, suffix: ".jpg")
    assert is_nil(source.content_hash)
    assert is_nil(ctx.contact.avatar)

    assert put_photo(ctx, bytes).status == 204
    assert [stored] = Contacts.list_photos(ctx.contact.id)
    assert stored.id == source.id
    assert stored.storage_key == source.storage_key
    assert stored.content_hash == Avatar.hash(bytes)
    assert Contacts.avatar_photo?(Contacts.get_contact!(ctx.account_id, ctx.contact.id), stored)
  end

  test "GET followed by PUT of the selected rendition preserves the original and ETag", ctx do
    {source, _bytes} = AvatarFixtures.stored_photo(ctx.contact, suffix: ".jpg")
    assert {:ok, _} = Contacts.set_avatar(ctx.contact, source)
    path = contact_path(ctx.contact)
    before = authed_dav(ctx, "GET", path)
    assert before.status == 200
    assert before.resp_body =~ "PHOTO"

    assert authed_dav(ctx, "PUT", path, before.resp_body).status == 204
    assert [stored] = Contacts.list_photos(ctx.contact.id)
    assert stored.id == source.id

    assert get_resp_header(authed_dav(ctx, "GET", path), "etag") ==
             get_resp_header(before, "etag")
  end

  test "PUT of different source bytes creates another original", ctx do
    {source, _bytes} = AvatarFixtures.stored_photo(ctx.contact, suffix: ".jpg")
    bytes = AvatarFixtures.image_binary(suffix: ".jpg", color: [20, 40, 180])

    assert put_photo(ctx, bytes).status == 204
    assert [_, _] = photos = Contacts.list_photos(ctx.contact.id)
    assert Enum.any?(photos, &(&1.id == source.id))
    selected = Enum.find(photos, &(&1.id != source.id))
    assert Storage.read(selected.storage_key) == {:ok, bytes}
    assert Contacts.avatar_photo?(Contacts.get_contact!(ctx.account_id, ctx.contact.id), selected)
  end

  defp put_photo(ctx, bytes) do
    card = build_vcard("Photo", "Repro", photo_b64: Base.encode64(bytes))
    authed_dav(ctx, "PUT", contact_path(ctx.contact), card)
  end
end
