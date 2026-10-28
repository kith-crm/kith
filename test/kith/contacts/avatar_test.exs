defmodule Kith.Contacts.AvatarTest do
  use Kith.DataCase, async: true
  alias Kith.{Contacts, Repo, Storage}
  alias Kith.Contacts.Photo
  alias Kith.DAV.Store
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.AvatarFixtures

  setup do
    contact = contact_fixture(user_fixture().account_id)
    Store.ensure_rows(contact.account_id)
    {photo, bytes} = stored_photo(contact)
    on_exit(fn -> Storage.delete(photo.storage_key) end)
    %{contact: contact, photo: photo, original: bytes}
  end

  test "selection keeps the original and caches one processed rendition", c do
    assert {:ok, updated} = Contacts.set_avatar(c.contact, c.photo)
    on_exit(fn -> Storage.delete(updated.avatar) end)
    photo = Repo.get!(Photo, c.photo.id)
    assert Contacts.avatar_photo?(updated, photo)
    assert updated.avatar == photo.avatar_storage_key
    assert updated.avatar != photo.storage_key
    assert {:ok, c.original} == Storage.read(photo.storage_key)
    assert {:ok, result} = Storage.read(updated.avatar)
    assert byte_size(result) == photo.avatar_file_size
    assert byte_size(result) <= 512 * 1024
    before = Store.sync_state(c.contact.account_id)
    assert {:ok, again} = Contacts.set_avatar(updated, photo)
    assert again.avatar == updated.avatar
    assert Store.sync_state(c.contact.account_id) == before
    assert Kith.Contacts.Avatar.current_bytes?(again, result)
  end

  test "invalid processing leaves the selected avatar and revisions unchanged", c do
    {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
    on_exit(fn -> Storage.delete(selected.avatar) end)
    before = Store.sync_state(c.contact.account_id)

    assert {:error, :invalid_crop} =
             Contacts.set_avatar(selected, c.photo, crop: %{x: -1, y: 0, width: 20, height: 20})

    assert Repo.get!(Contacts.Contact, selected.id).avatar == selected.avatar
    assert Store.sync_state(c.contact.account_id) == before
  end

  test "public contact writes cannot assign raw storage keys", c do
    before = Store.sync_state(c.contact.account_id)

    assert {:error, changeset} =
             Contacts.update_contact(c.contact, %{avatar: c.photo.storage_key})

    assert Keyword.has_key?(changeset.errors, :avatar)

    assert {:error, changeset} =
             Contacts.create_contact(
               c.contact.account_id,
               %{first_name: "Bypass", avatar: c.photo.storage_key}
             )

    assert Keyword.has_key?(changeset.errors, :avatar)
    assert Store.sync_state(c.contact.account_id) == before
    assert Repo.get!(Contacts.Contact, c.contact.id).avatar == nil
  end

  test "cross-contact or cross-account sources cannot be selected", c do
    other = contact_fixture(user_fixture().account_id)
    assert {:error, :invalid_photo} = Contacts.set_avatar(other, c.photo)
    assert Repo.get!(Contacts.Contact, other.id).avatar == nil
  end

  test "deleting the selected source clears avatar and advances revision", c do
    {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
    before = Store.sync_state(c.contact.account_id)
    assert {:ok, _} = Contacts.delete_photo(c.photo)
    assert Repo.get!(Contacts.Contact, selected.id).avatar == nil
    assert Store.sync_state(c.contact.account_id).token > before.token
  end

  test "merge preserves selected rendition when its original loses deduplication", c do
    survivor = contact_fixture(c.contact.account_id)
    hash = Kith.Contacts.Avatar.hash(c.original)
    survivor_photo = photo_fixture(survivor, %{"content_hash" => hash})
    c.photo |> Ecto.Changeset.change(content_hash: hash) |> Repo.update!()
    {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
    on_exit(fn -> Storage.delete(selected.avatar) end)

    assert {:ok, merged} =
             Contacts.merge_contacts(survivor.id, c.contact.id, %{"avatar" => "non_survivor"})

    assert merged.avatar == selected.avatar
    retained = Repo.get!(Photo, survivor_photo.id)
    assert retained.avatar_storage_key == selected.avatar
    assert Contacts.avatar_photo?(merged, retained)
    assert {:ok, _} = Storage.read(merged.avatar)
  end

  test "account storage cleanup removes source and processed files", c do
    {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
    assert :ok = Kith.Storage.AccountCleanup.wipe_for_account(c.contact.account_id)
    assert {:error, :enoent} = Storage.read(c.photo.storage_key)
    assert {:error, :enoent} = Storage.read(selected.avatar)
  end

  test "missing source bytes leave the current avatar unchanged", c do
    {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
    on_exit(fn -> Storage.delete(selected.avatar) end)
    Storage.delete(c.photo.storage_key)
    before = Store.sync_state(c.contact.account_id)
    assert {:error, :enoent} = Contacts.set_avatar(selected, c.photo)
    assert Repo.get!(Contacts.Contact, selected.id).avatar == selected.avatar
    assert Store.sync_state(c.contact.account_id) == before
  end

  test "outer rollback removes staged objects and leaves original references", c do
    assert {:error, :cancelled} =
             Kith.Contacts.Avatar.with_cleanup(fn ->
               Repo.transaction(fn ->
                 {:ok, selected} = Contacts.set_avatar(c.contact, c.photo)
                 send(self(), {:key, selected.avatar})
                 Repo.rollback(:cancelled)
               end)
             end)

    assert_receive {:key, key}
    assert {:error, :enoent} = Storage.read(key)
    assert Repo.get!(Contacts.Contact, c.contact.id).avatar == nil
    assert Repo.get!(Photo, c.photo.id).avatar_storage_key == nil
  end
end
