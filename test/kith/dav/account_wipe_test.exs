defmodule Kith.DAV.AccountWipeTest do
  use Kith.DataCase, async: false

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo, Storage}
  alias Kith.Contacts.{Cleanup, Contact, Tag}
  alias Kith.DAV.{ContactDav, Store}

  test "standalone wipe removes every batch without initializing documents and advances one floor" do
    account = user_fixture().account_id
    foreign = contact_fixture(user_fixture().account_id)
    foreign_dav = Repo.get!(ContactDav, foreign.id)
    insert_uninitialized_contacts(account, 401)
    Repo.insert!(%Tag{account_id: account, name: "Wiped tag"})
    before = Store.sync_state(account)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:kith, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:wipe_query, metadata.query})
      end,
      owner
    )

    try do
      assert :ok = Cleanup.wipe_for_account(account)
    after
      :telemetry.detach(handler)
    end

    queries = drain_queries([])
    assert Enum.count(queries, &String.contains?(&1, "INSERT INTO dav_sync_floors")) == 1
    refute Enum.any?(queries, &String.contains?(&1, "INSERT INTO contact_dav"))
    refute Enum.any?(queries, &String.contains?(&1, "UPDATE \"contact_dav\""))
    refute Repo.exists?(from c in Contact, where: c.account_id == ^account)
    refute Repo.exists?(from t in Tag, where: t.account_id == ^account)
    assert Store.sync_state(account).floor > before.token
    assert Store.sync_state(account).token == Store.sync_state(account).floor
    assert Repo.get!(ContactDav, foreign.id) == foreign_dav
  end

  test "outer rollback restores contacts tags validators floor and enumerated files" do
    account = user_fixture().account_id
    contact = contact_fixture(account)
    {photo, original} = Kith.AvatarFixtures.stored_photo(contact)
    {:ok, selected} = Contacts.set_avatar(contact, photo)
    {:ok, rendition} = Storage.read(selected.avatar)
    tag = Repo.insert!(%Tag{account_id: account, name: "Retained tag"})
    before = Repo.get!(ContactDav, contact.id)
    floor = Store.sync_state(account)
    on_exit(fn -> Enum.each([photo.storage_key, selected.avatar], &Storage.delete/1) end)

    assert {:error, :discard_wipe} =
             Store.transaction(account, fn ->
               assert :ok = Storage.AccountCleanup.wipe_for_account(account)
               assert :ok = Cleanup.wipe_for_account(account)
               refute Repo.exists?(from c in Contact, where: c.account_id == ^account)
               assert {:ok, ^original} = Storage.read(photo.storage_key)
               assert {:ok, ^rendition} = Storage.read(selected.avatar)
               Repo.rollback(:discard_wipe)
             end)

    assert Repo.get!(Contact, contact.id).avatar == selected.avatar
    assert Repo.get!(Tag, tag.id) == tag
    assert Repo.get!(ContactDav, contact.id) == before
    assert Store.sync_state(account) == floor
    assert Storage.read(photo.storage_key) == {:ok, original}
    assert Storage.read(selected.avatar) == {:ok, rendition}
  end

  test "standalone wipe holds all batches atomically while a native creator waits" do
    account =
      Sandbox.unboxed_run(Repo, fn ->
        account = user_fixture().account_id
        insert_uninitialized_contacts(account, 401)
        account
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^account)
      end)
    end)

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:kith, :repo, :query],
      fn _event, _measurements, metadata, parent ->
        if Process.get(:account_wipe_probe) == :pause and
             String.starts_with?(metadata.query, "DELETE FROM \"contacts\"") do
          Process.put(:account_wipe_probe, :continued)
          send(parent, {:wipe_first_batch, self()})

          receive do
            :continue_wipe -> :ok
          after
            10_000 -> raise "account wipe coordination timed out"
          end
        end
      end,
      parent
    )

    try do
      wipe =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Process.put(:account_wipe_probe, :pause)
            Cleanup.wipe_for_account(account)
          end)
        end)

      assert_receive {:wipe_first_batch, wipe_pid}, 5_000

      # Another connection sees the complete pre-wipe account, even after one
      # batch has been deleted inside the standalone cleanup transaction.
      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(c in Contact, where: c.account_id == ^account), :count) == 401
      end)

      creator =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:wipe_creator_backend, backend})
            Contacts.create_contact(account, %{first_name: "Created after wipe"})
          end)
        end)

      assert_receive {:wipe_creator_backend, backend}, 5_000
      Sandbox.unboxed_run(Repo, fn -> wait_for_lock(backend, 250) end)
      send(wipe_pid, :continue_wipe)
      assert Task.await(wipe, 15_000) == :ok
      assert {:ok, created} = Task.await(creator, 15_000)

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.all(from(c in Contact, where: c.account_id == ^account, select: c.id)) ==
                 [created.id]
      end)
    after
      :telemetry.detach(handler)
    end
  end

  defp insert_uninitialized_contacts(account, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(1..count, fn n ->
        %{
          account_id: account,
          first_name: "Uninitialized #{n}",
          display_name: "Uninitialized #{n}",
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Contact, rows)
  end

  defp drain_queries(acc) do
    receive do
      {:wipe_query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp wait_for_lock(backend, tries) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [
        backend
      ])

    cond do
      waiting ->
        :ok

      tries == 0 ->
        flunk("native creator did not wait for the account wipe lock")

      true ->
        Process.sleep(20)
        wait_for_lock(backend, tries - 1)
    end
  end
end
