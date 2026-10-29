defmodule Kith.DAV.WriteServiceReviewTest do
  # Includes a committed, two-connection snapshot probe; keep it isolated from
  # the ordinary sandbox-only account tests.
  use Kith.DataCase, async: false

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo}
  alias Kith.Contacts.{ContactField, Write}
  alias Kith.DAV.{AddressObject, ContactDav, Document, FieldRegistry, Store, VCardAdapter}
  alias Kith.Reminders.Reminder

  setup do
    user = user_fixture()
    %{user: user, account: user.account_id, contact: contact_fixture(user.account_id)}
  end

  test "migrated PUT requires a current explicit version validator", c do
    dav = gate(c.contact)
    before = Repo.reload!(c.contact)

    for header <- [
          nil,
          "*",
          ~s("#{dav.revision}"),
          ~s("#{dav.revision - 1}-v30"),
          ~s(W/"#{dav.revision}-v40")
        ] do
      assert request(c.contact, :put, card(c.contact, ["ORG:Rejected stale edit"]), header).status ==
               412

      assert Repo.reload!(c.contact) == before
      assert Repo.get!(ContactDav, c.contact.id) == dav
    end

    for version <- [:v30, :v40] do
      current = Repo.get!(ContactDav, c.contact.id)
      tag = ~s("#{Store.etag(%{dav: current}, version)}")

      assert request(c.contact, :put, card(c.contact, ["ORG:Accepted #{version}"]), tag).status ==
               204

      assert Repo.reload!(c.contact).company == "Accepted #{version}"
    end

    assert request(
             c.contact,
             :put,
             card(c.contact, ["ORG:Stale original"]),
             ~s("#{dav.revision}-v30")
           ).status == 412
  end

  test "migrated DELETE rejects unconditional wildcard and obsolete validators", c do
    dav = gate(c.contact)

    for header <- [nil, "*", ~s("#{dav.revision}"), ~s("#{dav.revision - 1}-v40")] do
      assert request(c.contact, :delete, "", header).status == 412
      assert Repo.reload!(c.contact).deleted_at == nil
      assert Repo.get!(ContactDav, c.contact.id) == dav
    end

    assert request(c.contact, :delete, "", ~s("#{Store.etag(%{dav: dav}, :v40)}")).status == 204
    assert Repo.reload!(c.contact).deleted_at != nil
  end

  test "stale child structs publish the actual current owner after a native move", c do
    other = contact_fixture(c.account)
    type = FieldRegistry.canonical_type!(:emails)
    stale_field = contact_field_fixture(c.contact, type.id, %{"value" => "before@example.com"})
    stale_address = address_fixture(c.contact)
    assert {:ok, _} = Contacts.update_contact_field(stale_field, %{contact_id: other.id})
    assert {:ok, _} = Contacts.update_address(stale_address, %{contact_id: other.id})
    before = Repo.get!(ContactDav, other.id)
    source_before = Repo.get!(ContactDav, c.contact.id)

    assert {:ok, _} = Contacts.update_contact_field(stale_field, %{value: "after@example.com"})
    assert {:ok, _} = Contacts.update_address(stale_address, %{city: "Current owner city"})
    assert Repo.get!(ContactField, stale_field.id).contact_id == other.id
    assert Repo.get!(ContactDav, other.id).revision > before.revision
    assert Repo.get!(ContactDav, c.contact.id) == source_before
    body = VCardAdapter.contact_to_vcard(Repo.reload!(other))
    assert body =~ "after@example.com"
    assert body =~ "Current owner city"

    before_delete = Repo.get!(ContactDav, other.id)
    assert {:ok, _} = Contacts.delete_contact_field(stale_field)
    assert {:ok, _} = Contacts.delete_address(stale_address)
    assert Repo.get!(ContactDav, other.id).revision > before_delete.revision
    refute VCardAdapter.contact_to_vcard(Repo.reload!(other)) =~ "after@example.com"
    assert Repo.get!(ContactDav, c.contact.id) == source_before
  end

  test "reordered equal-value home and work fields keep metadata bound to the correct native row",
       c do
    type = FieldRegistry.canonical_type!(:emails)

    home =
      contact_field_fixture(c.contact, type.id, %{
        "value" => "same@example.com",
        "label" => "Home"
      })

    work =
      contact_field_fixture(c.contact, type.id, %{
        "value" => "same@example.com",
        "label" => "Work"
      })

    body =
      card(c.contact, [
        "EMAIL;TYPE=work;X-MARK=work:same@example.com",
        "EMAIL;TYPE=home;X-MARK=home:same@example.com"
      ])

    assert request(c.contact, :put, body).status == 204
    assert Repo.get!(ContactField, home.id).label == "Home"
    assert Repo.get!(ContactField, work.id).label == "Work"
    assert {:ok, _} = Contacts.update_contact_field(home, %{value: "home-changed@example.com"})

    {:ok, document} =
      c.contact
      |> Repo.reload!()
      |> VCardAdapter.contact_to_vcard(version: :v40)
      |> Kith.VCard.Document.parse()

    changed =
      Enum.find(
        Kith.VCard.Document.properties(document, "EMAIL"),
        &(&1.value == "home-changed@example.com")
      )

    assert changed

    assert Enum.any?(
             changed.parameters,
             &(&1.normalized_name == "X-MARK" and &1.values == ["home"])
           )

    assert Enum.any?(
             changed.parameters,
             &(&1.normalized_name == "TYPE" and &1.values == ["home"])
           )
  end

  test "cross-account contact and private type reassignment rolls back native and DAV state", c do
    foreign = contact_fixture(user_fixture().account_id)
    type = FieldRegistry.canonical_type!(:emails)
    field = contact_field_fixture(c.contact, type.id)
    before = Repo.get!(ContactDav, c.contact.id)
    foreign_before = Repo.get!(ContactDav, foreign.id)

    assert {:error, %Ecto.Changeset{}} =
             Contacts.update_contact_field(field, %{contact_id: foreign.id})

    assert Repo.get!(ContactField, field.id).contact_id == c.contact.id

    {:ok, foreign_type} =
      Contacts.create_contact_field_type(foreign.account_id, %{name: "Foreign private type"})

    assert {:error, %Ecto.Changeset{}} =
             Contacts.update_contact_field(field, %{contact_field_type_id: foreign_type.id})

    assert Repo.get!(ContactField, field.id).contact_field_type_id == type.id
    assert Repo.get!(ContactDav, c.contact.id) == before
    assert Repo.get!(ContactDav, foreign.id) == foreign_before
  end

  test "DAV birthday changes preserve private reminders while native edits still reconcile them",
       c do
    assert {:ok, contact} = Contacts.update_contact(c.contact, %{birthdate: ~D[1990-01-02]})

    reminder =
      Repo.one!(from r in Reminder, where: r.contact_id == ^contact.id and r.type == "birthday")

    assert request(contact, :put, card(contact, ["BDAY:19910203"])).status == 204
    assert Repo.reload!(contact).birthdate == ~D[1991-02-03]
    assert Repo.get!(Reminder, reminder.id) == reminder
    assert request(contact, :put, card(contact, [])).status == 204
    assert Repo.reload!(contact).birthdate == nil
    assert Repo.get!(Reminder, reminder.id) == reminder
    assert Write.origin() == :kith

    assert {:ok, _} = Contacts.update_contact(contact, %{birthdate: ~D[1992-04-05]})
    assert Repo.get!(Reminder, reminder.id).anchor_date == ~D[1992-04-05]
  end

  test "failure after document persistence before publication rolls back the entire write", c do
    before = Repo.get!(ContactDav, c.contact.id)
    native_before = Repo.reload!(c.contact)

    assert {:error, :review_failure} =
             Store.transaction(c.account, fn ->
               assert {:ok, updated} =
                        Contacts.update_contact(c.contact, %{company: "Transient shared value"})

               current = Repo.preload(updated, Contacts.dav_preloads(), force: true)

               document =
                 Document.accept(current, card(current, ["NOTE:Transient client document"]))

               Repo.update!(Ecto.Changeset.change(current.dav, document: document))

               assert inspect(Repo.get!(ContactDav, current.id).document) =~
                        "Transient client document"

               assert Repo.get!(ContactDav, current.id).revision == before.revision
               Repo.rollback(:review_failure)
             end)

    assert Repo.reload!(c.contact) == native_before
    assert Repo.get!(ContactDav, c.contact.id) == before
    assert Write.origin() == :kith
  end

  test "a snapshot returns one body revision and token while a shared writer waits" do
    {account, contact} =
      Sandbox.unboxed_run(Repo, fn ->
        account = user_fixture().account_id
        {account, contact_fixture(account, %{first_name: "Snapshot before"})}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^account)
      end)
    end)

    parent = self()

    reader =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Store.snapshot(account, fn ->
            first = Store.get_by_uid(account, Repo.get!(ContactDav, contact.id).uid)
            first_body = VCardAdapter.contact_to_vcard(first)
            token = Store.sync_state(account).token
            send(parent, :review_snapshot_ready)

            receive do
              :review_continue -> :ok
            after
              10_000 -> raise "snapshot coordination timed out"
            end

            last = Store.get_by_uid(account, first.dav.uid)
            assert last.dav.revision == first.dav.revision
            assert VCardAdapter.contact_to_vcard(last) == first_body
            assert Store.sync_state(account).token == token
            {first_body, first.dav.revision, token}
          end)
        end)
      end)

    assert_receive :review_snapshot_ready, 5_000

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, :review_writer_started)
          Contacts.update_contact(contact, %{first_name: "Snapshot after"})
        end)
      end)

    assert_receive :review_writer_started, 5_000
    assert Task.yield(writer, 20) == nil
    send(reader.pid, :review_continue)
    {body, revision, token} = Task.await(reader, 15_000)
    assert body =~ "Snapshot before"
    refute body =~ "Snapshot after"
    assert token >= revision
    assert {:ok, _} = Task.await(writer, 15_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(ContactDav, contact.id).revision > revision
      assert VCardAdapter.contact_to_vcard(Repo.reload!(contact)) =~ "Snapshot after"
    end)
  end

  test "after-commit effects wait for the outer service transaction and disappear on rollback",
       c do
    owner = self()

    assert {:ok, :committed} =
             Store.transaction(c.account, fn ->
               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{company: "Committed effect value"})

               Write.after_commit(fn ->
                 send(
                   owner,
                   {:review_effect, Repo.reload!(c.contact).company, Write.active?(c.account)}
                 )
               end)

               assert {:ok, :nested} =
                        Store.transaction(c.account, fn ->
                          Write.after_commit(fn -> send(owner, :review_nested_effect) end)
                          refute_received {:review_effect, _, _}
                          refute_received :review_nested_effect
                          :nested
                        end)

               refute_received {:review_effect, _, _}
               refute_received :review_nested_effect
               :committed
             end)

    assert_received {:review_effect, "Committed effect value", false}
    assert_received :review_nested_effect

    assert {:error, :discard} =
             Store.transaction(c.account, fn ->
               Write.after_commit(fn -> send(owner, :review_rolled_back_effect) end)

               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{company: "Rolled back effect value"})

               Repo.rollback(:discard)
             end)

    refute_received :review_rolled_back_effect
    assert Repo.reload!(c.contact).company == "Committed effect value"
  end

  test "reset storage cleanup retains original and selected avatar files on rollback", c do
    {photo, original} = Kith.AvatarFixtures.stored_photo(c.contact)
    assert {:ok, selected} = Contacts.set_avatar(c.contact, photo)
    assert {:ok, rendition} = Kith.Storage.read(selected.avatar)
    asset = Repo.get!(Kith.Contacts.AvatarAsset, selected.avatar)
    keys = [photo.storage_key, selected.avatar]
    on_exit(fn -> Enum.each(keys, &Kith.Storage.delete/1) end)
    before = Repo.get!(ContactDav, c.contact.id)

    assert {:error, :reset_failed} =
             Store.transaction(c.account, fn ->
               assert :ok = Kith.Storage.AccountCleanup.wipe_for_account(c.account)
               assert :ok = Contacts.Cleanup.wipe_for_account(c.account)
               Repo.rollback(:reset_failed)
             end)

    assert Repo.get!(Kith.Contacts.Photo, photo.id)
    assert Repo.get!(ContactDav, c.contact.id) == before
    assert Kith.Storage.read(photo.storage_key) == {:ok, original}
    assert Kith.Storage.read(selected.avatar) == {:ok, rendition}
    assert Repo.get!(Kith.Contacts.AvatarAsset, selected.avatar) == asset

    assert :ok =
             Kith.Workers.AccountResetWorker.perform(%Oban.Job{
               args: %{"account_id" => c.account}
             })

    assert {:error, _} = Kith.Storage.read(photo.storage_key)
    assert {:error, _} = Kith.Storage.read(selected.avatar)
    assert Repo.get(Kith.Contacts.AvatarAsset, selected.avatar) == nil
    assert Repo.get(ContactDav, c.contact.id) == nil
  end

  test "after-commit exceptions throws and exits preserve the committed native result", c do
    effects = [
      {"exception", fn -> raise "Review effect failure" end},
      {"throw", fn -> throw(:review_effect_failure) end},
      {"exit", fn -> exit(:review_effect_failure) end}
    ]

    for {kind, effect} <- effects do
      company = "Committed despite #{kind} effect failure"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :committed} =
                   Store.transaction(c.account, fn ->
                     assert {:ok, _} = Contacts.update_contact(c.contact, %{company: company})
                     Write.after_commit(effect)
                     :committed
                   end)
        end)

      assert log =~ "Post-commit contact effect"
      assert Repo.reload!(c.contact).company == company
      assert VCardAdapter.contact_to_vcard(Repo.reload!(c.contact)) =~ company
    end
  end

  test "reports and queries see client-only values without discovering private native sentinels",
       c do
    {:ok, gender} = Contacts.create_gender(c.account, %{name: "Private query gender sentinel"})

    {:ok, contact} =
      Contacts.update_contact(c.contact, %{
        description: "Private query description sentinel",
        gender_id: gender.id,
        aliases: ["Private query alias sentinel"],
        first_met_where: "Private query location sentinel"
      })

    {:ok, type} =
      Contacts.create_contact_field_type(c.account, %{
        name: "Private query type",
        vcard_label: "X-PRIVATE-QUERY"
      })

    contact_field_fixture(contact, type.id, %{"value" => "Private query field sentinel"})
    dav = Repo.get!(ContactDav, contact.id)
    href = Store.href(%{contact | dav: dav})
    ctx = %{conn: Phoenix.ConnTest.build_conn(), user: c.user}

    report =
      KithWeb.DAV.TestHelpers.authed_dav(
        ctx,
        "REPORT",
        "/dav/addressbooks/default/",
        KithWeb.DAV.TestHelpers.multiget_body([href])
      )

    assert report.status == 207
    assert KithWeb.DAV.TestHelpers.count_responses(report.resp_body) == 1
    refute report.resp_body =~ "Private query"

    for {property, value} <- [
          {"NOTE", "Private query description sentinel"},
          {"GENDER", "Private query gender sentinel"},
          {"X-PRIVATE-QUERY", "Private query field sentinel"}
        ] do
      result =
        KithWeb.DAV.TestHelpers.authed_dav(
          ctx,
          "REPORT",
          "/dav/addressbooks/default/",
          query(property, value)
        )

      assert result.status == 207
      assert KithWeb.DAV.TestHelpers.count_responses(result.resp_body) == 0
    end

    assert request(contact, :put, card(contact, ["NOTE:Client query note sentinel"])).status ==
             204

    result =
      KithWeb.DAV.TestHelpers.authed_dav(
        ctx,
        "REPORT",
        "/dav/addressbooks/default/",
        query("NOTE", "Client query note sentinel")
      )

    assert result.status == 207
    assert KithWeb.DAV.TestHelpers.count_responses(result.resp_body) == 1
    assert result.resp_body =~ "Client query note sentinel"
    refute result.resp_body =~ "Private query"
    assert Repo.reload!(contact).description == "Private query description sentinel"
  end

  defp query(property, value) do
    """
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop><d:getetag/><card:address-data/></d:prop>
      <card:filter><card:prop-filter name="#{property}"><card:text-match collation="i;unicode-casemap" match-type="contains">#{value}</card:text-match></card:prop-filter></card:filter>
    </card:addressbook-query>
    """
  end

  defp gate(contact) do
    contact
    |> then(&Repo.get!(ContactDav, &1.id))
    |> Ecto.Changeset.change(requires_precondition: true)
    |> Repo.update!()
  end

  defp request(contact, method, body, tag \\ nil) do
    dav = Repo.get!(ContactDav, contact.id)
    conn = Plug.Test.conn(method, "/dav/addressbooks/default/" <> dav.resource_name, body)
    conn = assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    conn = if tag, do: put_req_header(conn, "if-match", tag), else: conn

    if method == :put,
      do: AddressObject.put(conn, dav.resource_name, body),
      else: AddressObject.delete(conn, dav.resource_name)
  end

  defp card(contact, properties) do
    dav = Repo.get!(ContactDav, contact.id)

    Enum.join(
      [
        "BEGIN:VCARD",
        "VERSION:4.0",
        "FN:#{contact.first_name}",
        "N:;#{contact.first_name};;;",
        "UID:urn:uuid:#{dav.uid}" | properties
      ],
      "\r\n"
    ) <> "\r\nEND:VCARD\r\n"
  end
end
