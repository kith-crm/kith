defmodule Kith.Storage.AccountCleanupTest do
  use Kith.DataCase, async: false

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Storage
  alias Kith.Storage.AccountCleanup

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "deletes target account's photo + import-upload files; leaves other account's files alone",
       ctx do
    {target_photo_key, _} = upload_and_attach_photo!(ctx.target_account)
    {other_photo_key, _} = upload_and_attach_photo!(ctx.other_account)

    target_upload_key = upload_import_file!(ctx.target_account, ctx.target_user)
    other_upload_key = upload_import_file!(ctx.other_account, ctx.other_user)

    # Ensure ALL files are cleaned up after the test, regardless of what wipe does.
    # Files written via Storage.upload_binary are real disk I/O outside the Ecto sandbox.
    on_exit(fn ->
      Enum.each(
        [target_photo_key, other_photo_key, target_upload_key, other_upload_key],
        fn key -> _ = Storage.delete(key) end
      )
    end)

    assert {:ok, _} = Storage.read(target_photo_key)
    assert {:ok, _} = Storage.read(other_photo_key)
    assert {:ok, _} = Storage.read(target_upload_key)
    assert {:ok, _} = Storage.read(other_upload_key)

    assert :ok = AccountCleanup.wipe_for_account(ctx.target_account)

    assert {:error, _} = Storage.read(target_photo_key)
    assert {:error, _} = Storage.read(target_upload_key)

    # Control account untouched
    assert {:ok, _} = Storage.read(other_photo_key)
    assert {:ok, _} = Storage.read(other_upload_key)
  end

  test "is a no-op when account has no files", ctx do
    assert :ok = AccountCleanup.wipe_for_account(ctx.target_account)
  end

  defp upload_and_attach_photo!(account_id) do
    contact = contact_fixture(account_id)
    binary = <<0xFF, 0xD8, 0xFF, 0xE0>>
    key = Storage.generate_key(account_id, "photos", "test.jpg")
    {:ok, _} = Storage.upload_binary(binary, key)

    {:ok, photo} =
      Contacts.create_photo(contact, %{
        "file_name" => "test.jpg",
        "storage_key" => key,
        "file_size" => byte_size(binary),
        "content_type" => "image/jpeg"
      })

    {key, photo}
  end

  defp upload_import_file!(account_id, user_id) do
    uuid = Ecto.UUID.generate()
    key = "#{account_id}/imports/#{uuid}.vcf"
    {:ok, _} = Storage.upload_binary("BEGIN:VCARD\nEND:VCARD\n", key)

    {:ok, _} =
      Imports.create_import(account_id, user_id, %{
        source: "vcard",
        file_name: "export.vcf",
        file_size: 22,
        file_storage_key: key
      })

    key
  end
end
