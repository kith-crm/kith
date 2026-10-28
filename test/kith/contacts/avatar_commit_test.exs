defmodule Kith.Contacts.AvatarCommitTest do
  use Kith.DataCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo, Storage}
  alias Kith.Contacts.Avatar
  import Kith.AvatarFixtures

  test "real commits retire replaced files and deletion removes both assets" do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)
    on_exit(fn -> cleanup(account) end)

    Sandbox.unboxed_run(Repo, fn ->
      contact = Kith.ContactsFixtures.contact_fixture(account)
      {photo, _} = stored_photo(contact, width: 800, height: 600)
      {:ok, first} = Contacts.set_avatar(contact, photo)
      assert {:ok, _} = Storage.read(first.avatar)

      {:ok, second} =
        Contacts.set_avatar(first, photo, crop: %{x: 0, y: 0, width: 200, height: 200})

      assert second.avatar != first.avatar
      assert {:error, :enoent} = Storage.read(first.avatar)
      assert {:ok, _} = Storage.read(photo.storage_key)
      assert {:ok, _} = Contacts.delete_photo(photo)
      assert {:error, :enoent} = Storage.read(second.avatar)
      assert {:error, :enoent} = Storage.read(photo.storage_key)
      assert Repo.get!(Contacts.Contact, contact.id).avatar == nil
    end)
  end

  test "an outer exception rolls back references and removes its staged derivative" do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)
    on_exit(fn -> cleanup(account) end)

    Sandbox.unboxed_run(Repo, fn ->
      contact = Kith.ContactsFixtures.contact_fixture(account)
      {photo, _} = stored_photo(contact)

      assert_raise RuntimeError, "rollback probe", fn ->
        Avatar.with_cleanup(fn ->
          Repo.transaction(fn ->
            {:ok, selected} = Contacts.set_avatar(contact, photo)
            send(self(), {:staged, selected.avatar})
            raise "rollback probe"
          end)
        end)
      end

      assert_receive {:staged, key}
      assert {:error, :enoent} = Storage.read(key)
      assert {:ok, _} = Storage.read(photo.storage_key)
      assert Repo.get!(Contacts.Contact, contact.id).avatar == nil
    end)
  end

  test "merge retires overwritten duplicate-source renditions only after commit" do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)
    on_exit(fn -> cleanup(account) end)

    Sandbox.unboxed_run(Repo, fn ->
      survivor = Kith.ContactsFixtures.contact_fixture(account)
      loser = Kith.ContactsFixtures.contact_fixture(account)
      {a, original} = stored_photo(survivor)
      {b, _} = stored_photo(loser)
      hash = Avatar.hash(original)

      for photo <- [a, b],
          do: photo |> Ecto.Changeset.change(content_hash: hash) |> Repo.update!()

      {:ok, survivor} = Contacts.set_avatar(survivor, a)
      {:ok, loser} = Contacts.set_avatar(loser, b, crop: %{x: 0, y: 0, width: 100, height: 100})

      assert {:error, :probe} =
               Avatar.with_cleanup(fn ->
                 Repo.transaction(fn ->
                   assert {:ok, _} =
                            Contacts.merge_contacts(survivor.id, loser.id, %{
                              "avatar" => "non_survivor"
                            })

                   Repo.rollback(:probe)
                 end)
               end)

      assert {:ok, _} = Storage.read(survivor.avatar)
      assert {:ok, _} = Storage.read(loser.avatar)

      assert {:ok, merged} =
               Contacts.merge_contacts(survivor.id, loser.id, %{"avatar" => "non_survivor"})

      assert merged.avatar == loser.avatar
      assert {:error, :enoent} = Storage.read(survivor.avatar)
      assert {:ok, _} = Storage.read(loser.avatar)
      assert {:error, :enoent} = Storage.read(b.storage_key)
      assert {:ok, _} = Storage.read(a.storage_key)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Kith.Avatars.Backfill.run(["--account-id", to_string(account)])
        end)

      assert output =~ "0 converted, 2 already normalized, 0 failed"
    end)
  end

  test "warm cached usage cannot hide a newly uploaded original during quota checks" do
    previous = Application.get_env(:kith, :max_storage_size_mb)
    Application.put_env(:kith, :max_storage_size_mb, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kith, :max_storage_size_mb, previous),
        else: Application.delete_env(:kith, :max_storage_size_mb)
    end)

    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)
    on_exit(fn -> cleanup(account) end)

    Sandbox.unboxed_run(Repo, fn ->
      contact = Kith.ContactsFixtures.contact_fixture(account)
      Kith.DAV.Store.ensure_rows(account)
      before = Kith.DAV.Store.sync_state(account)
      assert {:ok, 0} = Storage.usage(account)
      binary = image_binary() <> :binary.copy(<<0>>, 1_100_000)
      key = Storage.generate_key(account, "photos", "large-source.png")

      assert {:error, :storage_limit_exceeded} =
               Avatar.with_cleanup(fn ->
                 Kith.DAV.Store.transaction(account, fn ->
                   {:ok, _} = Storage.upload_binary(binary, key)
                   Avatar.stage_created(key)

                   {:ok, photo} =
                     Contacts.create_photo(contact, %{
                       file_name: "large-source.png",
                       storage_key: key,
                       file_size: byte_size(binary),
                       content_type: "image/png"
                     })

                   # Deliberately repopulate stale cache to prove enforcement bypasses it.
                   Cachex.put(:kith_cache, {:storage_usage, account}, 0)

                   case Contacts.set_avatar(contact, photo) do
                     {:ok, updated} -> updated
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end)
               end)

      assert {:error, :enoent} = Storage.read(key)
      assert Contacts.list_photos(contact.id) == []
      assert Kith.DAV.Store.sync_state(account) == before
    end)
  end

  test "backfill repairs a corrupt rendition with the saved crop and is resumable" do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)
    on_exit(fn -> cleanup(account) end)

    Sandbox.unboxed_run(Repo, fn ->
      contact = Kith.ContactsFixtures.contact_fixture(account)
      {photo, _} = stored_photo(contact)
      crop = %{x: 100, y: 100, width: 150, height: 150}
      {:ok, selected} = Contacts.set_avatar(contact, photo, crop: crop)
      {:ok, expected} = Storage.read(selected.avatar)
      {:ok, _} = Storage.upload_binary("broken image", selected.avatar)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Kith.Avatars.Backfill.run(["--account-id", to_string(account)])
        end)

      assert output =~ "1 converted, 0 already normalized, 0 failed"
      repaired = Repo.get!(Contacts.Contact, contact.id)
      assert repaired.avatar != selected.avatar
      assert {:ok, ^expected} = Storage.read(repaired.avatar)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Kith.Avatars.Backfill.run(["--account-id", to_string(account)])
        end)

      assert output =~ "0 converted, 1 already normalized, 0 failed"
    end)
  end

  for choice <- ["survivor", "non_survivor"] do
    test "#{choice} merge preserves snapshots, counts shared assets once, and survives source deletion" do
      account =
        Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)

      on_exit(fn -> cleanup(account) end)

      Sandbox.unboxed_run(Repo, fn ->
        survivor = Kith.ContactsFixtures.contact_fixture(account)
        loser = Kith.ContactsFixtures.contact_fixture(account)
        {a, original} = stored_photo(survivor)
        {b, _} = stored_photo(loser)

        for photo <- [a, b],
            do:
              photo
              |> Ecto.Changeset.change(content_hash: Avatar.hash(original))
              |> Repo.update!()

        {:ok, survivor} = Contacts.set_avatar(survivor, a)
        {:ok, loser} = Contacts.set_avatar(loser, b, crop: %{x: 0, y: 0, width: 100, height: 100})
        {:ok, a_bytes} = Storage.read(survivor.avatar)
        {:ok, b_bytes} = Storage.read(loser.avatar)

        assert {:ok, merged} =
                 Contacts.merge_contacts(survivor.id, loser.id, %{"avatar" => unquote(choice)})

        historical = Repo.get!(Contacts.Contact, loser.id)
        assert historical.avatar == loser.avatar
        assert {:ok, ^b_bytes} = Storage.read(historical.avatar)

        expected_avatar_bytes =
          if merged.avatar == loser.avatar,
            do: byte_size(b_bytes),
            else: byte_size(a_bytes) + byte_size(b_bytes)

        Storage.bust_usage_cache(account)
        assert {:ok, total} = Storage.usage(account)
        assert total == byte_size(original) + expected_avatar_bytes

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Tasks.Kith.Avatars.Backfill.run(["--account-id", to_string(account)])
          end)

        assert output =~ "0 converted, 2 already normalized, 0 failed"
        source = Repo.get!(Kith.Contacts.Photo, a.id)
        assert {:ok, _} = Contacts.delete_photo(source)
        assert Repo.get!(Contacts.Contact, merged.id).avatar == nil
        assert Repo.get!(Contacts.Contact, historical.id).avatar == loser.avatar
        assert {:ok, ^b_bytes} = Storage.read(loser.avatar)
        assert Avatar.current_bytes?(historical, b_bytes)
        Storage.bust_usage_cache(account)
        assert {:ok, remaining} = Storage.usage(account)
        assert remaining == byte_size(b_bytes)

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Tasks.Kith.Avatars.Backfill.run(["--account-id", to_string(account)])
          end)

        assert output =~ "0 converted, 1 already normalized, 0 failed"
        assert {:ok, restored} = Contacts.restore_contact(historical)
        assert {:ok, ^b_bytes} = Storage.read(restored.avatar)
        assert :ok = Kith.Storage.AccountCleanup.wipe_for_account(account)
        assert {:error, :enoent} = Storage.read(loser.avatar)

        assert Repo.aggregate(
                 from(asset in Kith.Contacts.AvatarAsset, where: asset.account_id == ^account),
                 :count,
                 :storage_key
               ) == 0
      end)
    end
  end

  defp cleanup(account) do
    Sandbox.unboxed_run(Repo, fn ->
      Kith.Storage.AccountCleanup.wipe_for_account(account)
      Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^account)
    end)
  end
end
