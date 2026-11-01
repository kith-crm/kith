defmodule Kith.CacheDataIntegrationTest do
  # Real commits are required: independent connections must observe old data
  # while a writer is blocked, then the context must invalidate after commit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kith.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.Cache
  alias Kith.Cache.Store
  alias Kith.{Contacts, DuplicateDetection, Repo, Storage}

  setup do
    {first, second} = unboxed(fn -> {insert(:account), insert(:account)} end)

    on_exit(fn ->
      ensure_store_started()

      unboxed(fn ->
        ids = [first.id, second.id]
        Repo.delete_all(from(account in Kith.Accounts.Account, where: account.id in ^ids))
      end)

      for account <- [first, second], key <- [:storage_usage, :duplicate_cluster_count] do
        Cache.delete({key, account.id})
      end
    end)

    %{first: first, second: second}
  end

  test "actual photo/document CRUD invalidates account storage totals after persistence", ctx do
    unboxed(fn ->
      first_contact = insert(:contact, account: ctx.first)
      second_contact = insert(:contact, account: ctx.second)
      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert {:ok, _} = Contacts.create_photo(second_contact, media_attrs("other.jpg", 900))
      assert {:ok, 900} = Storage.usage(ctx.second.id)

      assert {:ok, photo} = Contacts.create_photo(first_contact, media_attrs("photo.jpg", 100))
      assert {:ok, 100} = Storage.usage(ctx.first.id)

      assert {:ok, document} =
               Contacts.create_document(first_contact, media_attrs("file.pdf", 250))

      assert {:ok, 350} = Storage.usage(ctx.first.id)
      assert {:ok, ttl} = Cache.ttl({:storage_usage, ctx.first.id})
      assert ttl > :timer.minutes(4) and ttl <= :timer.minutes(5)

      assert {:ok, _} = Contacts.delete_document(document)
      assert {:ok, 100} = Storage.usage(ctx.first.id)
      assert {:ok, _} = Contacts.delete_photo(photo)
      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert {:ok, 900} = Storage.usage(ctx.second.id)
    end)
  end

  test "committed CardDAV photo replacement invalidates nested media storage usage", ctx do
    directory =
      Path.join(System.tmp_dir!(), "kith-carddav-cache-#{System.unique_integer([:positive])}")

    Kith.TestEnv.put_env_restoring(:kith, Kith.Storage, backend: :local, path: directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    unboxed(fn ->
      contact = insert(:contact, account: ctx.first)
      bytes = "synthetic-jpeg-photo"

      vcard =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Cache Photo\r\nN:Photo;Cache;;;\r\nPHOTO;ENCODING=b;TYPE=JPEG:#{Base.encode64(bytes)}\r\nEND:VCARD\r\n"

      {_attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(vcard, account_id: ctx.first.id)
      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, ctx.first.id, nested)
      assert :miss = Cache.get({:storage_usage, ctx.first.id})
      assert {:ok, size} = Storage.usage(ctx.first.id)
      assert size == byte_size(bytes)
      assert [photo] = Contacts.list_photos(contact.id)
      assert {:ok, ^bytes} = Storage.read(photo.storage_key)
      assert Repo.get!(Kith.Contacts.Contact, contact.id).avatar == photo.storage_key
    end)
  end

  test "committed empty_trash clears storage and duplicate caches after cascades", ctx do
    unboxed(fn ->
      candidate = pair(ctx.first)
      contact = Repo.get!(Kith.Contacts.Contact, candidate.contact_id)
      assert {:ok, _} = Contacts.create_document(contact, media_attrs("trash.pdf", 250))
      assert {:ok, _} = Contacts.soft_delete_contact(contact)
      assert {:ok, 250} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert {:ok, 1} = Contacts.empty_trash(ctx.first.id)
      assert :miss = Cache.get({:storage_usage, ctx.first.id})
      assert :miss = Cache.get({:duplicate_cluster_count, ctx.first.id})
      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
    end)
  end

  test "the purge worker invalidates after its enclosing deletion transaction commits", ctx do
    unboxed(fn ->
      candidate = pair(ctx.first)
      contact = Repo.get!(Kith.Contacts.Contact, candidate.contact_id)
      assert {:ok, _} = Contacts.create_document(contact, media_attrs("purge.pdf", 250))
      assert {:ok, trashed} = Contacts.soft_delete_contact(contact)
      old = DateTime.utc_now(:second) |> DateTime.add(-31 * 86_400, :second)
      trashed |> Ecto.Changeset.change(deleted_at: old) |> Repo.update!()
      assert {:ok, 250} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert :ok = Kith.Workers.ContactPurgeWorker.perform(%Oban.Job{args: %{}})
      assert Repo.get(Kith.Contacts.Contact, contact.id) == nil
      assert :miss = Cache.get({:storage_usage, ctx.first.id})
      assert :miss = Cache.get({:duplicate_cluster_count, ctx.first.id})
      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
    end)
  end

  test "duplicate counts retain tenant isolation and post-persistence dismissal invalidation",
       ctx do
    unboxed(fn ->
      candidate = pair(ctx.first)
      pair(ctx.second)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert DuplicateDetection.cluster_count(ctx.second.id) == 1
      assert {:ok, ttl} = Cache.ttl({:duplicate_cluster_count, ctx.first.id})
      assert ttl > :timer.minutes(4) and ttl <= :timer.minutes(5)
      assert {:ok, _} = DuplicateDetection.dismiss_candidate(candidate)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert DuplicateDetection.cluster_count(ctx.second.id) == 1
    end)
  end

  test "scan and selected dismissal invalidate counts through their real boundaries", ctx do
    unboxed(fn ->
      # The generic factory's display_name has its own sequence; creating through
      # the context exercises the actual derived name used by the trigram scan.
      attrs = %{first_name: "Cache Unique", last_name: "Match"}
      assert {:ok, one} = Contacts.create_contact(ctx.first.id, attrs)
      assert {:ok, two} = Contacts.create_contact(ctx.first.id, attrs)
      assert one.display_name == "Cache Unique Match"
      assert two.display_name == one.display_name
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert :ok = DuplicateDetection.scan_account(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert :ok = DuplicateDetection.dismiss_selection(ctx.first.id, [one.id, two.id], [])
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
    end)
  end

  test "contact trash/restore and permanent cascade invalidate affected counts and storage",
       ctx do
    unboxed(fn ->
      candidate = pair(ctx.first)
      contact = Repo.get!(Kith.Contacts.Contact, candidate.contact_id)
      assert {:ok, _} = Contacts.create_document(contact, media_attrs("file.pdf", 250))
      assert {:ok, 250} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert {:ok, trashed} = Contacts.soft_delete_contact(contact)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert {:ok, restored} = Contacts.restore_contact(trashed)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert {:ok, _} = Contacts.hard_delete_contact(restored)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert {:ok, 0} = Storage.usage(ctx.first.id)
    end)
  end

  test "the outer Contacts merge commits before invalidating pair and storage caches", ctx do
    unboxed(fn ->
      candidate = pair(ctx.first)
      contact = Repo.get!(Kith.Contacts.Contact, candidate.contact_id)
      assert {:ok, _} = Contacts.create_document(contact, media_attrs("file.pdf", 250))
      assert {:ok, 250} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1

      assert {:ok, _} =
               Contacts.merge_contacts(candidate.contact_id, candidate.duplicate_contact_id)

      assert :miss = Cache.get({:duplicate_cluster_count, ctx.first.id})
      assert :miss = Cache.get({:storage_usage, ctx.first.id})
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
      assert {:ok, 250} = Storage.usage(ctx.first.id)
    end)
  end

  test "transactions bypass cached derived values and cannot publish rolled-back totals", ctx do
    unboxed(fn ->
      contact = insert(:contact, account: ctx.first)
      assert {:ok, 0} = Storage.usage(ctx.first.id)

      assert {:error, :discard} =
               Repo.transaction(fn ->
                 assert {:ok, _} =
                          Contacts.create_photo(contact, media_attrs("rolled-back.jpg", 100))

                 assert {:ok, 100} = Storage.usage(ctx.first.id)
                 Repo.rollback(:discard)
               end)

      assert {:ok, 0} = Storage.usage(ctx.first.id)
      assert {:ok, 0} = Cache.get({:storage_usage, ctx.first.id})
    end)
  end

  test "actual storage totals and duplicate badges survive backend outage and restart", ctx do
    unboxed(fn ->
      contact = insert(:contact, account: ctx.first)
      assert {:ok, _} = Contacts.create_photo(contact, media_attrs("photo.jpg", 123))
      pair(ctx.first)
      assert {:ok, 123} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert :ok = Supervisor.terminate_child(Kith.Supervisor, Store)
      assert {:ok, 123} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      ensure_store_started()
      assert :miss = Cache.get({:storage_usage, ctx.first.id})
      assert :miss = Cache.get({:duplicate_cluster_count, ctx.first.id})
      assert {:ok, 123} = Storage.usage(ctx.first.id)
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
    end)
  end

  test "a blocked dismissal cannot leave a reader's precommit count cached", ctx do
    candidate = unboxed(fn -> pair(ctx.first) end)
    parent = self()

    locker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM duplicate_candidates WHERE id = $1 FOR UPDATE", [
              candidate.id
            ])

            send(parent, {:row_locked, self()})
            receive do: (:release_lock -> :ok)
          end)
        end)
      end)

    assert_receive {:row_locked, locker_pid}, 5_000

    writer =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:writer_connection, backend_pid})
          DuplicateDetection.dismiss_candidate(candidate)
        end)
      end)

    on_exit(fn ->
      send(locker_pid, :release_lock)
      for task <- [locker, writer], Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    assert_receive {:writer_connection, backend_pid}, 5_000
    assert eventually_blocked?(backend_pid)

    unboxed(fn ->
      assert DuplicateDetection.cluster_count(ctx.first.id) == 1
      assert {:ok, 1} = Cache.get({:duplicate_cluster_count, ctx.first.id})
    end)

    send(locker_pid, :release_lock)
    assert {:ok, :ok} = Task.await(locker, 5_000)
    assert {:ok, _} = Task.await(writer, 5_000)

    unboxed(fn ->
      assert :miss = Cache.get({:duplicate_cluster_count, ctx.first.id})
      assert DuplicateDetection.cluster_count(ctx.first.id) == 0
    end)
  end

  defp eventually_blocked?(backend_pid, attempts \\ 100)
  defp eventually_blocked?(_backend_pid, 0), do: false

  defp eventually_blocked?(backend_pid, attempts) do
    blocked =
      unboxed(fn ->
        %{rows: [[blocked]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend_pid])

        blocked
      end)

    if blocked do
      true
    else
      Process.sleep(10)
      eventually_blocked?(backend_pid, attempts - 1)
    end
  end

  defp pair(account) do
    first = insert(:contact, account: account)
    second = insert(:contact, account: account)
    insert(:duplicate_candidate, account: account, contact: first, duplicate_contact: second)
  end

  defp media_attrs(name, size),
    do: %{
      file_name: name,
      storage_key: "synthetic/#{name}",
      file_size: size,
      content_type: "application/octet-stream"
    }

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp ensure_store_started do
    case Supervisor.restart_child(Kith.Supervisor, Store) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end
end
