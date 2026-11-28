defmodule Kith.Contacts.PhotoDeduplicationMigrationTest do
  use Kith.DataCase, async: false

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  alias Kith.{AvatarFixtures, Contacts, Imports, Storage}
  alias Kith.Contacts.Avatar
  alias Kith.Repo.Migrations.DeduplicateContactPhotos

  Code.require_file("priv/repo/data_migrations/20261128000000_deduplicate_contact_photos.exs")

  @tag :tmp_dir
  test "consolidates verified duplicates and preserves the selected avatar and import records", %{
    tmp_dir: root
  } do
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    on_exit(fn -> File.rm_rf!(root) end)

    user = user_fixture()
    contact = contact_fixture(user.account_id)
    other = contact_fixture(user.account_id)
    import_job = import_fixture(user.account_id, user.id)

    {duplicate, bytes} = AvatarFixtures.stored_photo(contact)
    {selected, ^bytes} = AvatarFixtures.stored_photo(contact)
    {independent, ^bytes} = AvatarFixtures.stored_photo(other)
    {different, _} = AvatarFixtures.stored_photo(contact, color: [20, 40, 180])

    duplicate
    |> Ecto.Changeset.change(content_hash: Avatar.hash(bytes), is_private: true)
    |> Repo.update!()

    assert {:ok, _} =
             Imports.record_imported_entity(
               import_job,
               "photo",
               "original",
               "photo",
               duplicate.id
             )

    assert {:ok, %{avatar: avatar}} = Contacts.set_avatar(contact, selected)

    assert :ok = DeduplicateContactPhotos.up()
    assert :ok = DeduplicateContactPhotos.up()

    photos = Map.new(Contacts.list_photos(contact.id), &{&1.id, &1})
    assert Enum.sort(Map.keys(photos)) == Enum.sort([selected.id, different.id])
    assert photos[selected.id].avatar_storage_key == avatar
    assert photos[selected.id].storage_key == selected.storage_key
    assert photos[selected.id].content_hash == Avatar.hash(bytes)
    assert photos[selected.id].is_private
    assert Contacts.get_contact!(user.account_id, contact.id).avatar == avatar
    assert [^independent] = Contacts.list_photos(other.id)
    assert {:ok, ^bytes} = Storage.read(duplicate.storage_key)

    record = Imports.find_import_record(user.account_id, import_job.source, "photo", "original")
    assert record.local_entity_id == selected.id
  end
end
