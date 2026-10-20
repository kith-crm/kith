defmodule KithWeb.DAV.ConcurrencyTest do
  @moduledoc """
  Concurrent CardDAV writes. These run outside the Ecto sandbox (real
  transactions and row locks), so the module is not async and every test
  deletes its account afterwards.
  """
  use KithWeb.ConnCase, async: false

  import Ecto.Query
  import KithWeb.DAV.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo}

  @book "/dav/addressbooks/default/"

  setup do
    user = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^user.account_id)
      end)
    end)

    %{user: user, account_id: user.account_id}
  end

  defp dav_put(user, href, vcard, headers \\ []) do
    Sandbox.unboxed_run(Repo, fn ->
      headers
      |> Enum.reduce(build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> basic_auth(user.email, dav_password())
      |> dav_request("PUT", href, vcard)
    end)
  end

  defp card(tel), do: build_vcard("Race", "Card", phone: tel)

  defp tels(account_id, href) do
    Sandbox.unboxed_run(Repo, fn ->
      name = href |> String.split("/") |> List.last()
      contact = Contacts.get_contact_by_dav_name(account_id, name)
      contact.id |> Contacts.list_contact_fields() |> Enum.map(& &1.value)
    end)
  end

  describe "CDV-24: preconditions are evaluated under a row lock" do
    test "CDV-24: a PUT whose If-Match is overtaken by an uncommitted write is 412, not a lost update",
         %{user: user, account_id: account_id} do
      href = @book <> "lock.vcf"
      created = dav_put(user, href, card("+15550000000"))
      assert created.status == 201
      [etag] = get_resp_header(created, "etag")

      # Another writer changes the contact and holds its row lock while the
      # PUT (carrying the now-stale ETag) runs; it commits half a second later.
      task =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, task} =
            Repo.transaction(fn ->
              contact = Contacts.get_contact_by_dav_name(account_id, "lock.vcf")
              {:ok, _} = Contacts.update_contact(contact, %{"last_name" => "Other"})

              {:ok, _} =
                Contacts.replace_contact_children(contact, account_id, %{
                  emails: [],
                  phones: [%{value: "+15559999999", label: "cell"}],
                  urls: [],
                  addresses: []
                })

              task =
                Task.async(fn ->
                  dav_put(user, href, card("+15551111111"), [{"if-match", etag}])
                end)

              Process.sleep(500)
              task
            end)

          task
        end)

      assert Task.await(task, 10_000).status == 412
      assert tels(account_id, href) == ["+15559999999"]
    end

    test "CDV-24: two concurrent PUTs with the same If-Match: one 2xx, one 412, children of one body",
         %{user: user, account_id: account_id} do
      href = @book <> "pair.vcf"
      created = dav_put(user, href, card("+15550000000"))
      [etag] = get_resp_header(created, "etag")

      results =
        ["+15551111111", "+15552222222"]
        |> Enum.map(fn tel ->
          Task.async(fn -> {tel, dav_put(user, href, card(tel), [{"if-match", etag}]).status} end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert results |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [204, 412]
      [{winner, 204}] = Enum.filter(results, &(elem(&1, 1) == 204))
      assert tels(account_id, href) == [winner]
    end
  end

  describe "CDV-25: concurrent creates of one name" do
    # Another writer creates `name` and holds the transaction open while the PUT
    # runs, then commits: the PUT's insert hits the unique index.
    defp put_during_create(user, account_id, name, headers) do
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, task} =
          Repo.transaction(fn ->
            {:ok, c} = Contacts.create_contact(account_id, %{"first_name" => "First"})
            {:ok, _} = Contacts.put_dav_identity(c, %{dav_resource_name: name})

            task =
              Task.async(fn -> dav_put(user, @book <> name, card("+15553333333"), headers) end)

            Process.sleep(500)
            task
          end)

        Task.await(task, 10_000)
      end)
    end

    defp count(account_id),
      do: Sandbox.unboxed_run(Repo, fn -> Contacts.count_contacts(account_id) end)

    test "CDV-25: the losing unconditional create becomes an update of the winner",
         %{user: user, account_id: account_id} do
      assert put_during_create(user, account_id, "race.vcf", []).status == 204
      assert count(account_id) == 1
      assert tels(account_id, @book <> "race.vcf") == ["+15553333333"]
    end

    test "CDV-25: the losing If-None-Match: * create is 412",
         %{user: user, account_id: account_id} do
      assert put_during_create(user, account_id, "race2.vcf", [{"if-none-match", "*"}]).status ==
               412

      assert count(account_id) == 1
    end
  end

  describe "CDV-33: PUT row lock vs. relationship foreign keys" do
    test "CDV-33: a PUT whose RELATED points at a contact another writer holds does not deadlock",
         %{user: user, account_id: account_id} do
      {a, b, type} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, a} = Contacts.create_contact(account_id, %{"first_name" => "Ann"})
          {:ok, b} = Contacts.create_contact(account_id, %{"first_name" => "Bob"})

          type =
            Repo.one!(
              from t in Kith.Contacts.RelationshipType,
                where: is_nil(t.account_id),
                order_by: t.id,
                limit: 1
            )

          {a, b, type}
        end)

      card =
        Enum.join(
          [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:;Ann;;;",
            "FN:Ann",
            "RELATED;TYPE=friend:urn:uuid:kith-contact-#{b.id}",
            "END:VCARD",
            ""
          ],
          "\r\n"
        )

      # Another writer holds B's row lock (as a PUT of B would), the PUT of A
      # needs a key-share lock on B for its relationship row, then the other
      # writer inserts a relationship pointing at A, which the PUT has locked.
      put_status =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, task} =
            Repo.transaction(fn ->
              Contacts.lock_contact(b)
              task = Task.async(fn -> dav_put(user, contact_path(a), card) end)
              Process.sleep(500)

              %Kith.Contacts.Relationship{}
              |> Kith.Contacts.Relationship.changeset(%{
                account_id: account_id,
                contact_id: b.id,
                related_contact_id: a.id,
                relationship_type_id: type.id
              })
              |> Repo.insert!()

              task
            end)

          Task.await(task, 10_000).status
        end)

      assert put_status == 204
    end
  end

  describe "CDV-36: concurrent creates with one UID" do
    test "CDV-36: a create racing an uncommitted create with the same UID is 409 no-uid-conflict",
         %{user: user, account_id: account_id} do
      conn =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, task} =
            Repo.transaction(fn ->
              {:ok, c} = Contacts.create_contact(account_id, %{"first_name" => "First"})

              {:ok, _} =
                Contacts.put_dav_identity(c, %{
                  dav_resource_name: "uid-1.vcf",
                  dav_uid: "race-uid"
                })

              task =
                Task.async(fn ->
                  dav_put(
                    user,
                    @book <> "uid-2.vcf",
                    build_vcard("Second", "Card", uid: "race-uid")
                  )
                end)

              Process.sleep(500)
              task
            end)

          Task.await(task, 10_000)
        end)

      assert conn.status == 409
      assert conn.resp_body =~ "<d:href>#{@book}uid-1.vcf</d:href>"
      assert count(account_id) == 1
    end
  end

  # ── Commit order (sync token, ctag) ──────────────────────────────────────

  # Runs `write` in a transaction in another process and holds it open
  # (uncommitted) until `commit/1` is called on the returned handle.
  defp hold_write(write) do
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            write.()
            send(parent, {:written, self()})

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive {:written, pid}, 5_000
    {task, pid}
  end

  defp commit({task, pid}) do
    send(pid, :commit)
    Task.await(task, 10_000)
  end

  defp unboxed_contact(account_id, first_name),
    do:
      Sandbox.unboxed_run(Repo, fn ->
        Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: first_name})
      end)

  defp rename(contact, first_name),
    do: {:ok, _} = Contacts.update_contact(Repo.reload!(contact), %{first_name: first_name})

  defp dav(user, method, path, body, headers \\ []) do
    Sandbox.unboxed_run(Repo, fn ->
      headers
      |> Enum.reduce(build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> basic_auth(user.email, dav_password())
      |> dav_request(method, path, body)
    end)
  end

  defp ctag(user) do
    body =
      ~s(<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop><cs:getctag/></d:prop></d:propfind>)

    conn = dav(user, "PROPFIND", @book, body, [{"depth", "0"}])

    [ctag] =
      Regex.run(~r{<cs:getctag>([^<]+)</cs:getctag>}, conn.resp_body, capture: :all_but_first)

    ctag
  end

  describe "CDV-53: the ctag follows commit order" do
    test "CDV-53: a write that commits after a later-started write still changes the ctag",
         %{user: user, account_id: account_id} do
      slow = unboxed_contact(account_id, "Slow")
      fast = unboxed_contact(account_id, "Fast")

      # T1 writes first (older revision) but commits last
      t1 = hold_write(fn -> rename(slow, "SlowEdited") end)
      Sandbox.unboxed_run(Repo, fn -> rename(fast, "FastEdited") end)
      before = ctag(user)

      commit(t1)
      refute ctag(user) == before
    end
  end

  defp sync(user, token) do
    body =
      ~s(<d:sync-collection xmlns:d="DAV:"><d:sync-token>#{token}</d:sync-token>) <>
        ~s(<d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>)

    conn = dav(user, "REPORT", @book, body)
    assert conn.status == 207, conn.resp_body

    [next] =
      Regex.run(~r{<d:sync-token>([^<]+)</d:sync-token>}, conn.resp_body, capture: :all_but_first)

    hrefs = Regex.scan(~r{<d:href>([^<]+)</d:href>}, conn.resp_body, capture: :all_but_first)
    {List.flatten(hrefs), next}
  end

  describe "CDV-54: sync tokens follow commit order" do
    test "CDV-54: a write uncommitted when the token was issued is reported once it commits",
         %{user: user, account_id: account_id} do
      slow = unboxed_contact(account_id, "Slow")
      fast = unboxed_contact(account_id, "Fast")
      quiet = unboxed_contact(account_id, "Quiet")

      # T1 writes first and stays open while the token is issued
      t1 = hold_write(fn -> rename(slow, "SlowEdited") end)
      {_, token} = sync(user, "")
      Sandbox.unboxed_run(Repo, fn -> rename(fast, "FastEdited") end)
      commit(t1)

      {changed, next} = sync(user, token)
      assert "#{@book}kith-contact-#{slow.id}.vcf" in changed
      assert "#{@book}kith-contact-#{fast.id}.vcf" in changed
      refute "#{@book}kith-contact-#{quiet.id}.vcf" in changed

      # and nothing is re-reported once everything has committed
      assert {[], ^next} = sync(user, next)
    end
  end
end
