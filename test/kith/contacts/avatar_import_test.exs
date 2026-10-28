defmodule Kith.Contacts.AvatarImportTest do
  use Kith.DataCase, async: true
  import Kith.AccountsFixtures
  import Kith.AvatarFixtures
  alias Kith.{Contacts, Repo, Storage}
  alias Kith.Contacts.Photo
  alias Kith.VCard.Parser

  test "file vCard imports normalize PHOTO and preserve its original" do
    account = user_fixture().account_id
    original = image_binary(width: 900, height: 1600)
    {:ok, [parsed]} = Parser.parse(card(original))
    assert {:ok, contact} = Contacts.import_contact(account, parsed)
    assert [source] = Contacts.list_photos(contact.id)

    on_exit(fn ->
      Storage.delete(source.storage_key)
      Storage.delete(source.avatar_storage_key)
    end)

    assert contact.avatar == source.avatar_storage_key
    assert {:ok, ^original} = Storage.read(source.storage_key)
    assert {:ok, jpeg} = Storage.read(contact.avatar)
    assert byte_size(jpeg) <= 512 * 1024
    assert Image.shape(Image.from_binary!(jpeg)) == {512, 512, 3}
  end

  test "an invalid imported PHOTO rolls back the card" do
    account = user_fixture().account_id
    {:ok, [parsed]} = Parser.parse(card("not an image"))
    assert {:error, :invalid_image} = Contacts.import_contact(account, parsed)
    assert Contacts.count_contacts(account) == 0
    assert Repo.aggregate(Photo, :count) == 0
  end

  defp card(binary) do
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Imported Avatar\r\nN:Avatar;Imported;;;\r\nPHOTO;ENCODING=b;TYPE=PNG:" <>
      Base.encode64(binary) <> "\r\nEND:VCARD\r\n"
  end
end
