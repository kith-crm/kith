defmodule Kith.Contacts.PhotoStorageTest do
  use Kith.DataCase, async: false

  import Kith.ContactsFixtures

  alias Kith.{Contacts, Storage}
  alias Kith.Contacts.Write

  @moduletag :tmp_dir
  @attrs %{file_name: "source.jpg", content_type: "image/jpeg"}

  setup %{tmp_dir: root} do
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{contact: contact_fixture(Kith.AccountsFixtures.user_fixture().account_id)}
  end

  test "same-size bytes and different contacts each have independent originals", %{
    contact: contact,
    tmp_dir: root
  } do
    other_contact = contact_fixture(contact.account_id)

    assert {:ok, {:created, first}} = Contacts.store_photo(contact, <<1, 2>>, @attrs)
    assert {:ok, {:created, second}} = Contacts.store_photo(contact, <<2, 1>>, @attrs)
    assert {:ok, {:created, third}} = Contacts.store_photo(other_contact, <<1, 2>>, @attrs)
    keys = Enum.sort([first.storage_key, second.storage_key, third.storage_key])
    assert length(Enum.uniq(keys)) == 3

    assert {:ok, {:existing, reused}} =
             Contacts.store_photo(contact, <<1, 2>>, @attrs, check_quota: true)

    assert reused.id == first.id
    assert reused.storage_key == first.storage_key
    assert Path.wildcard(Path.join(root, "*/photos/*")) == Enum.map(keys, &Path.join(root, &1))
  end

  test "rollback removes the staged original and preserves an existing object", %{
    contact: contact
  } do
    assert {:ok, {:created, original}} = Contacts.store_photo(contact, <<1, 2>>, @attrs)

    assert {:error, :rollback_probe} =
             Write.transaction(contact.account_id, fn ->
               {:ok, {:created, photo}} = Contacts.store_photo(contact, <<2, 1>>, @attrs)
               send(self(), {:new_storage_key, photo.storage_key})
               Repo.rollback(:rollback_probe)
             end)

    assert_received {:new_storage_key, key}
    assert [stored] = Contacts.list_photos(contact.id)
    assert stored.id == original.id
    assert {:error, :enoent} = Storage.read(key)
    assert {:ok, <<1, 2>>} = Storage.read(original.storage_key)
  end
end
