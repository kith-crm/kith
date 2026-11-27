defmodule Kith.DAV.StoreConcurrencyTest do
  use Kith.DataCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{AvatarFixtures, Contacts, Repo, Storage, DAV.Store}
  alias Kith.Contacts.Write
  import Ecto.Query

  setup do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^account)
      end)
    end)

    %{account: account}
  end

  test "a revision drawn before a token is issued but committed after is newer than that token",
       %{account: account} do
    [x, y] =
      Sandbox.unboxed_run(Repo, fn ->
        contacts = for _ <- 1..2, do: Kith.ContactsFixtures.contact_fixture(account)
        Store.ensure_rows(account)
        contacts
      end)

    parent = self()

    a =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = Kith.Contacts.update_contact(x, %{first_name: "Concurrent first"})
            send(parent, :locked)

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000

    b =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, pid})
          assert {:ok, _} = Kith.Contacts.update_contact(y, %{first_name: "Concurrent second"})
          :ok
        end)
      end)

    assert_receive {:backend, pid}, 5_000
    Sandbox.unboxed_run(Repo, fn -> wait_for_lock(pid, 250) end)
    assert Task.yield(b, 0) == nil
    token = Sandbox.unboxed_run(Repo, fn -> Store.sync_state(account).token end)
    send(a.pid, :commit)
    assert {:ok, :ok} = Task.await(a)
    assert :ok = Task.await(b)
    changed = Sandbox.unboxed_run(Repo, fn -> Store.list_changed_since(account, token) end)
    assert Enum.sort(Enum.map(changed, & &1.id)) == Enum.sort([x.id, y.id])
  end

  test "merge and hard deletion acquire account before contact locks", %{account: account} do
    [survivor, loser] =
      Sandbox.unboxed_run(Repo, fn ->
        contacts = for _ <- 1..2, do: Kith.ContactsFixtures.contact_fixture(account)
        Store.ensure_rows(account)
        contacts
      end)

    parent = self()

    deletion =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          try do
            Repo.transaction(fn ->
              Store.touch(account, [survivor.id])
              send(parent, :delete_account_locked)

              receive do
                :delete -> :ok
              after
                10_000 -> Repo.rollback(:timeout)
              end

              assert {:ok, _} = Kith.Contacts.hard_delete_contact(survivor)
              Repo.rollback(:probe)
            end)
          rescue
            error -> {:raised, error}
          end
        end)
      end)

    assert_receive :delete_account_locked, 5_000

    merge =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:merge_backend, pid})

          try do
            Kith.Contacts.merge_contacts(survivor.id, loser.id)
          rescue
            error -> {:raised, error}
          end
        end)
      end)

    assert_receive {:merge_backend, pid}, 5_000
    Sandbox.unboxed_run(Repo, fn -> wait_for_lock(pid, 250) end)
    send(deletion.pid, :delete)
    assert {:error, :probe} = Task.await(deletion, 15_000)
    assert {:ok, _} = Task.await(merge, 15_000)
  end

  @tag :tmp_dir
  test "concurrent writes of the same photo commit one original", %{
    account: account,
    tmp_dir: root
  } do
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    on_exit(fn -> File.rm_rf!(root) end)

    contact =
      Sandbox.unboxed_run(Repo, fn -> Kith.ContactsFixtures.contact_fixture(account) end)

    parent = self()
    bytes = AvatarFixtures.image_binary(suffix: ".jpg")
    attrs = %{file_name: "photo.jpg", content_type: "image/jpeg"}

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Write.transaction(account, fn ->
            assert {:ok, {:created, photo}} = Contacts.store_photo(contact, bytes, attrs)
            send(parent, :photo_staged)

            receive do
              :commit -> photo
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive :photo_staged, 5_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:photo_backend, pid})
          Contacts.store_photo(contact, bytes, attrs)
        end)
      end)

    assert_receive {:photo_backend, pid}, 5_000
    Sandbox.unboxed_run(Repo, fn -> wait_for_lock(pid, 250) end)
    send(first.pid, :commit)
    assert {:ok, original} = Task.await(first)
    assert {:ok, {:existing, reused}} = Task.await(second)
    assert reused.id == original.id

    assert [stored] = Sandbox.unboxed_run(Repo, fn -> Contacts.list_photos(contact.id) end)
    assert stored.id == original.id
    assert Path.wildcard(Path.join(root, "*/photos/*")) == [Path.join(root, original.storage_key)]
  end

  defp wait_for_lock(pid, tries) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid])

    cond do
      waiting ->
        :ok

      tries == 0 ->
        flunk("writer never waited on the account lock")

      true ->
        Process.sleep(20)
        wait_for_lock(pid, tries - 1)
    end
  end
end
