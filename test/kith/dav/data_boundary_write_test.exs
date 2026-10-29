defmodule Kith.DAV.DataBoundaryWriteTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Plug.Conn

  alias Kith.Contacts
  alias Kith.Contacts.{Contact, ContactFieldType, Photo, RelationshipType, Write}
  alias Kith.DAV.{AddressObject, ContactDav, Store, UID, VCardAdapter}

  setup do
    account = user_fixture().account_id
    contact = contact_fixture(account, %{first_name: "Boundary", last_name: "Person"})
    Store.ensure_rows(account)
    %{account: account, contact: contact}
  end

  test "private description edits preserve both versions, timestamp, revision and document", c do
    before = state(c.contact)

    assert {:ok, updated} =
             Contacts.update_contact(c.contact, %{description: "Private description"})

    assert updated.description == "Private description"
    assert state(c.contact) == before
  end

  test "private gender edits preserve the published state", c do
    {:ok, gender} = Contacts.create_gender(c.account, %{name: "Private gender"})
    before = state(c.contact)
    assert {:ok, _} = Contacts.update_contact(c.contact, %{gender_id: gender.id})
    assert state(c.contact) == before
  end

  test "private custom field create update and delete preserve publication", c do
    {:ok, type} =
      Contacts.create_contact_field_type(c.account, %{
        name: "Private field",
        protocol: "mailto",
        vcard_label: "EMAIL"
      })

    before = state(c.contact)

    assert {:ok, field} =
             Contacts.create_contact_field(c.contact, %{
               value: "private@example.com",
               contact_field_type_id: type.id
             })

    assert state(c.contact) == before

    assert {:ok, field} =
             Contacts.update_contact_field(field, %{value: "other-private@example.com"})

    assert state(c.contact) == before
    assert {:ok, _} = Contacts.delete_contact_field(field)
    assert state(c.contact) == before
  end

  test "favorite aliases first-met and integration edits remain private", c do
    before = state(c.contact)

    assert {:ok, _} =
             Contacts.update_contact(c.contact, %{
               favorite: true,
               aliases: ["private alias"],
               first_met_where: "private location",
               first_met_additional_info: "private details",
               immich_person_id: "private integration id",
               immich_person_url: "https://private.example.com/person"
             })

    assert state(c.contact) == before
  end

  test "private edits preserve a native display-name preference result", c do
    assert {:ok, _} =
             Write.run(c.account, [c.contact.id], fn ->
               c.contact
               |> Ecto.Changeset.change(display_name: "Person, Boundary")
               |> Repo.update()
             end)

    before = state(c.contact)
    assert {:ok, _} = Contacts.update_contact(c.contact, %{favorite: true})
    assert Repo.get!(Contact, c.contact.id).display_name == "Person, Boundary"
    assert state(c.contact) == before
  end

  test "a no-op shared update preserves publication", c do
    before = state(c.contact)
    assert {:ok, _} = Contacts.update_contact(c.contact, %{first_name: c.contact.first_name})
    assert state(c.contact) == before
  end

  test "unchanged PUT preserves occurrence IDs without rewriting document JSONB", c do
    assert put(c.contact, card(c.contact, ["NOTE:Keep metadata", "EMAIL:roundtrip@example.test"])) ==
             204

    before = state(c.contact)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:kith, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == owner and String.starts_with?(metadata.query, "UPDATE") and
             String.contains?(metadata.query, "contact_dav") and
             String.contains?(metadata.query, "document") do
          send(owner, :document_rewritten)
        end
      end,
      nil
    )

    try do
      assert put(c.contact, before.v40) == 204
      assert state(c.contact) == before
      refute_received :document_rewritten
    after
      :telemetry.detach(handler)
    end
  end

  test "a shared name edit publishes both versions and advances dedicated DAV time", c do
    before = state(c.contact)
    assert {:ok, _} = Contacts.update_contact(c.contact, %{first_name: "Updated"})
    after_state = state(c.contact)
    assert after_state.revision > before.revision
    assert DateTime.compare(after_state.modified_at, before.modified_at) in [:gt, :eq]
    assert after_state.v30 =~ "Updated"
    assert after_state.v40 =~ "Updated"
    refute after_state.v30 == before.v30
    refute Store.etag(%{dav: dav(c.contact)}, :v30) == Store.etag(%{dav: dav(c.contact)}, :v40)
  end

  test "nested native changes publish only at the outer transaction boundary", c do
    before = state(c.contact)

    assert {:ok, :done} =
             Store.transaction(c.account, fn ->
               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{first_name: "First shared change"})

               assert dav(c.contact).revision == before.revision

               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{company: "Final shared company"})

               assert dav(c.contact).revision == before.revision
               :done
             end)

    after_state = state(c.contact)
    assert after_state.revision > before.revision
    assert after_state.v30 =~ "First shared change"
    assert after_state.v30 =~ "Final shared company"
  end

  test "a native command after a staged DAV document preserves the accepted client metadata", c do
    raw = card(c.contact, ["NOTE:New client metadata in the same transaction"])
    {attrs, children} = VCardAdapter.vcard_to_attrs(raw, account_id: c.account, strip_nils: false)

    assert {:ok, :done} =
             Store.transaction(c.account, fn ->
               assert {:ok, updated} = Contacts.update_contact(c.contact, attrs)
               assert {:ok, :ok} = Contacts.replace_contact_children(updated, c.account, children)

               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{company: "Later native shared edit"})

               :done
             end)

    after_state = state(c.contact)
    assert after_state.v40 =~ "NOTE:New client metadata in the same transaction"
    assert after_state.v40 =~ "ORG:Later native shared edit"
    assert Repo.get!(Contact, c.contact.id).description == nil
  end

  test "rolling back a staged DAV document plus a later native command restores the old publication",
       c do
    before = state(c.contact)
    raw = card(c.contact, ["NOTE:Uncommitted client metadata"])
    {attrs, children} = VCardAdapter.vcard_to_attrs(raw, account_id: c.account, strip_nils: false)

    assert {:error, :staged_rollback} =
             Store.transaction(c.account, fn ->
               assert {:ok, updated} = Contacts.update_contact(c.contact, attrs)
               assert {:ok, :ok} = Contacts.replace_contact_children(updated, c.account, children)

               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{company: "Uncommitted native value"})

               Repo.rollback(:staged_rollback)
             end)

    assert state(c.contact) == before
    assert Repo.get!(Contact, c.contact.id).company == nil
  end

  test "outer rollback restores native shared rows and published document together", c do
    before = state(c.contact)

    assert {:error, :deliberate_failure} =
             Store.transaction(c.account, fn ->
               assert {:ok, _} =
                        Contacts.update_contact(c.contact, %{first_name: "Should rollback"})

               assert {:ok, _} = Contacts.create_address(c.contact, %{line1: "Rollback street"})
               Repo.rollback(:deliberate_failure)
             end)

    assert Repo.get!(Contact, c.contact.id).first_name == c.contact.first_name
    assert Contacts.list_addresses(c.contact.id) == []
    assert state(c.contact) == before
  end

  test "failed shared validation leaves native and DAV state unchanged", c do
    before = state(c.contact)
    assert {:error, _} = Contacts.update_contact(c.contact, %{first_name: nil, last_name: nil})
    assert Repo.get!(Contact, c.contact.id).first_name == c.contact.first_name
    assert state(c.contact) == before
  end

  test "private update through a stale Contact does not restore an older shared name", c do
    assert {:ok, _} = Contacts.update_contact(c.contact, %{first_name: "Newer name"})
    before = state(c.contact)
    assert {:ok, _} = Contacts.update_contact(c.contact, %{description: "Private stale edit"})
    assert Repo.get!(Contact, c.contact.id).first_name == "Newer name"
    assert state(c.contact) == before
  end

  test "client NOTE and GENDER survive separately from native private values", c do
    {:ok, gender} = Contacts.create_gender(c.account, %{name: "Native private gender"})

    assert {:ok, _} =
             Contacts.update_contact(c.contact, %{
               description: "Native private description",
               gender_id: gender.id
             })

    assert put(c.contact, card(c.contact, ["NOTE:Client note", "GENDER:O;Client gender"])) == 204
    native = Repo.get!(Contact, c.contact.id)
    assert native.description == "Native private description"
    assert native.gender_id == gender.id
    assert state(c.contact).v40 =~ "NOTE:Client note"
    assert state(c.contact).v40 =~ "GENDER:O;Client gender"
    refute state(c.contact).v40 =~ "Native private"
  end

  test "Kith shared edits preserve client groups parameters and NOTE metadata", c do
    assert put(
             c.contact,
             card(c.contact, [
               "NOTE;LANGUAGE=en:Client note",
               "item-a.X-CLIENT;X-P=\"a:b;c\":Grouped metadata"
             ])
           ) == 204

    assert {:ok, _} = Contacts.update_contact(c.contact, %{company: "Kith company"})
    body = state(c.contact).v40
    assert body =~ "ORG:Kith company"
    assert body =~ "NOTE;LANGUAGE=en:Client note"
    assert body =~ "item-a.X-CLIENT;X-P=\"a:b;c\":Grouped metadata"
  end

  test "PUT omission clears only shared values and preserves private rows", c do
    {:ok, _} =
      Contacts.update_contact(c.contact, %{
        company: "Shared company",
        description: "Private description"
      })

    {:ok, type} =
      Contacts.create_contact_field_type(c.account, %{name: "Private", vcard_label: "EMAIL"})

    private = contact_field_fixture(c.contact, type.id, %{"value" => "private@example.com"})

    shared =
      contact_field_fixture(c.contact, trusted_field!("email").id, %{
        "value" => "shared@example.com"
      })

    assert put(c.contact, card(c.contact, [])) == 204
    native = Repo.get!(Contact, c.contact.id)
    assert native.company in [nil, ""]
    assert native.description == "Private description"
    assert Repo.get!(Kith.Contacts.ContactField, private.id)
    refute Repo.get(Kith.Contacts.ContactField, shared.id)
  end

  for version <- [:v30, :v40] do
    test "#{version} unchanged GET/PUT preserves built-in subtype private type metadata and row IDs",
         c do
      type = trusted_field!("mobile")

      shared =
        contact_field_fixture(c.contact, type.id, %{"value" => "+12025550123", "label" => "Cell"})

      {:ok, custom} =
        Contacts.create_contact_field_type(c.account, %{
          name: "Private email mimic",
          vcard_label: "EMAIL"
        })

      private = contact_field_fixture(c.contact, custom.id, %{"value" => "private@example.com"})
      address = address_fixture(c.contact)
      before_ids = Enum.sort([shared.id, private.id])

      for _ <- 1..4 do
        body =
          VCardAdapter.contact_to_vcard(Repo.reload!(c.contact),
            version: unquote(version),
            include_photo: false
          )

        assert put(c.contact, body) == 204

        assert Enum.sort(Enum.map(Contacts.list_contact_fields(c.contact.id), & &1.id)) ==
                 before_ids

        assert Repo.get!(Kith.Contacts.ContactField, shared.id).contact_field_type_id == type.id
        assert Repo.get!(Kith.Contacts.ContactField, private.id).value == "private@example.com"
        assert Enum.map(Contacts.list_addresses(c.contact.id), & &1.id) == [address.id]
      end
    end
  end

  test "DAV fields never use a lower-position private protocol type", c do
    {:ok, private_type} =
      Contacts.create_contact_field_type(c.account, %{
        name: "Private destination",
        protocol: "mailto",
        position: -1_000_000
      })

    assert put(c.contact, card(c.contact, ["EMAIL:shared@example.com"])) == 204
    assert [field] = Contacts.list_contact_fields(c.contact.id)
    assert field.contact_field_type_id == trusted_field!("email").id
    refute field.contact_field_type_id == private_type.id
  end

  test "hiding a relationship target updates both endpoint publications without deleting edge",
       c do
    other = contact_fixture(c.account)
    edge = relationship_fixture(c.contact, other, trusted_relationship!("parent").id)
    before_source = state(c.contact)
    before_target = state(other)
    assert before_source.v40 =~ UID.urn(dav(other).uid)
    assert before_target.v40 =~ UID.urn(dav(c.contact).uid)
    assert {:ok, _} = Contacts.archive_contact(other)
    assert state(c.contact).revision > before_source.revision
    assert dav(other).revision > before_target.revision
    refute state(c.contact).v40 =~ UID.urn(dav(other).uid)
    assert Repo.get!(Kith.Contacts.Relationship, edge.id)
  end

  test "a new reverse relationship refreshes an earlier staged target document", c do
    source = contact_fixture(c.account, %{first_name: "New source"})
    source_uid = UID.urn(dav(source).uid)
    before = state(c.contact)

    assert {:ok, :accepted} =
             Store.transaction(c.account, fn ->
               assert put(c.contact, card(c.contact, ["NOTE:Accepted before edge"])) == 204
               relationship_fixture(source, c.contact, trusted_relationship!("parent").id)
               :accepted
             end)

    final = state(c.contact)
    assert final.revision > before.revision
    assert inspect(final.document) =~ source_uid
    assert final.v30 =~ source_uid
    assert final.v40 =~ source_uid
    assert final.v40 =~ "NOTE:Accepted before edge"
    assert {:ok, _} = Contacts.update_contact(c.contact, %{description: "Still private"})
    assert state(c.contact) == final
    assert {:ok, _} = Contacts.update_contact(c.contact, %{first_name: c.contact.first_name})
    assert state(c.contact) == final
  end

  test "moving a child to a staged destination refreshes its accepted document", c do
    source = contact_fixture(c.account)
    address = address_fixture(source, %{"city" => "Moved city"})

    assert {:ok, :accepted} =
             Store.transaction(c.account, fn ->
               assert put(c.contact, card(c.contact, ["NOTE:Keep destination metadata"])) == 204
               assert {:ok, _} = Contacts.update_address(address, %{contact_id: c.contact.id})
               :accepted
             end)

    final = state(c.contact)
    assert inspect(final.document) =~ "Moved city"
    assert final.v30 =~ "Moved city"
    assert final.v40 =~ "Moved city"
    assert final.v40 =~ "Keep destination metadata"
    assert {:ok, _} = Contacts.update_contact(c.contact, %{favorite: true})
    assert state(c.contact) == final
  end

  test "PUT rejects conflicting PID sources atomically in both source versions", c do
    before = state(c.contact)
    native = Repo.reload!(c.contact)

    for version <- ["3.0", "4.0"] do
      body =
        card(c.contact, [
          "CLIENTPIDMAP:1;https://one.example/source",
          "CLIENTPIDMAP:1;https://two.example/source",
          "EMAIL;PID=1.1:rejected@example.test"
        ])
        |> String.replace("VERSION:4.0", "VERSION:" <> version)

      assert put(c.contact, body) == 403
      assert state(c.contact) == before
      assert Repo.reload!(c.contact) == native
      assert Contacts.list_contact_fields(c.contact.id) == []
    end
  end

  test "rolling back a staged target and newly created edge restores all publication state", c do
    source = contact_fixture(c.account)
    before = state(c.contact)
    source_before = state(source)

    assert {:error, :discard_edge} =
             Store.transaction(c.account, fn ->
               assert put(c.contact, card(c.contact, ["NOTE:Rolled back edge"])) == 204
               relationship_fixture(source, c.contact, trusted_relationship!("parent").id)
               Repo.rollback(:discard_edge)
             end)

    assert state(c.contact) == before
    assert state(source) == source_before
    assert Contacts.list_relationships(source.id) == []
  end

  test "a new URI dependency follows target creation and hiding without spurious publication",
       c do
    uid = Ecto.UUID.generate()
    urn = UID.urn(uid)
    before = state(c.contact)
    references_before = Repo.all(Kith.DAV.DocumentReference)

    for outcome <- [:rollback, :commit] do
      result =
        Store.transaction(c.account, fn ->
          assert put(c.contact, card(c.contact, ["RELATED;TYPE=friend:" <> urn])) == 204

          target =
            contact_fixture(c.account, %{first_name: "New hidden target", is_archived: true})

          Store.ensure_contact_rows(c.account, [target.id])
          assert {:ok, _} = Store.put_identity(dav(target), %{uid: uid})
          if outcome == :rollback, do: Repo.rollback(:discard_reference), else: :accepted
        end)

      if outcome == :rollback do
        assert result == {:error, :discard_reference}
        assert state(c.contact) == before
        assert Repo.all(Kith.DAV.DocumentReference) == references_before
      else
        assert result == {:ok, :accepted}
        final = state(c.contact)
        refute final.v30 =~ urn
        refute final.v40 =~ urn
        assert Contacts.list_relationships(c.contact.id) == []

        assert {:ok, _} =
                 Contacts.update_contact(c.contact, %{description: "Private reference edit"})

        assert state(c.contact) == final
      end
    end
  end

  test "renaming a tag publishes only contacts using that tag", c do
    other = contact_fixture(c.account)
    {:ok, tag} = Contacts.create_tag(c.account, %{name: "Old shared tag"})
    Contacts.tag_contact(c.contact, tag)
    before_member = state(c.contact)
    before_other = state(other)
    assert {:ok, _} = Contacts.rename_tag(tag, "New shared tag")
    assert state(c.contact).revision > before_member.revision
    assert state(c.contact).v40 =~ "New shared tag"
    assert state(other) == before_other
  end

  test "PUT without PHOTO clears selection but preserves the original source photo", c do
    photo = photo_fixture(c.contact)
    bytes = Image.new!(24, 24, color: :blue) |> Image.write!(:memory, suffix: ".png")
    assert {:ok, _} = Kith.Storage.upload_binary(bytes, photo.storage_key)
    on_exit(fn -> Kith.Storage.delete(photo.storage_key) end)
    assert {:ok, _} = Contacts.set_avatar(c.contact, photo)
    assert Repo.get!(Contact, c.contact.id).avatar
    assert put(c.contact, card(c.contact, [])) == 204
    assert Repo.get!(Contact, c.contact.id).avatar == nil
    assert Repo.get!(Photo, photo.id).storage_key == photo.storage_key
    assert {:ok, ^bytes} = Kith.Storage.read(photo.storage_key)
  end

  defp state(contact) do
    current = Repo.reload!(contact)
    dav = dav(current)

    %{
      revision: dav.revision,
      fingerprint: dav.representation_fingerprint,
      etags: {Store.etag(%{dav: dav}, :v30), Store.etag(%{dav: dav}, :v40)},
      modified_at: dav.representation_modified_at,
      document: dav.document,
      v30: VCardAdapter.contact_to_vcard(current, version: :v30, include_photo: false),
      v40: VCardAdapter.contact_to_vcard(current, version: :v40, include_photo: false)
    }
  end

  defp dav(contact), do: Repo.get!(ContactDav, contact.id)

  defp put(contact, body) do
    conn =
      Plug.Test.conn(:put, "/dav/addressbooks/default/" <> dav(contact).resource_name)
      |> assign(:current_scope, %{account: %{id: contact.account_id}})

    AddressObject.put(conn, dav(contact).resource_name, body).status
  end

  defp card(contact, properties) do
    Enum.join(
      [
        "BEGIN:VCARD",
        "VERSION:4.0",
        "UID:" <> UID.urn(dav(contact).uid),
        "FN:Boundary Person",
        "N:Person;Boundary;;;"
      ] ++ properties ++ ["END:VCARD", ""],
      "\r\n"
    )
  end

  defp trusted_field!(key),
    do:
      Repo.one!(from(t in ContactFieldType, where: is_nil(t.account_id) and t.system_key == ^key))

  defp trusted_relationship!(key),
    do:
      Repo.one!(from(t in RelationshipType, where: is_nil(t.account_id) and t.system_key == ^key))
end

defmodule Kith.DAV.DataBoundaryWriteConcurrencyTest do
  use Kith.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.Contacts
  alias Kith.Contacts.Contact
  alias Kith.DAV.{ContactDav, Store}

  setup do
    contact =
      Sandbox.unboxed_run(Repo, fn ->
        account = Kith.AccountsFixtures.user_fixture().account_id
        Kith.ContactsFixtures.contact_fixture(account, %{first_name: "Before"})
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(a in Kith.Accounts.Account, where: a.id == ^contact.account_id))
      end)
    end)

    %{contact: contact}
  end

  test "other database connections cannot observe native edits before document publication", %{
    contact: contact
  } do
    before = read_pair(contact)
    parent = self()

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Store.transaction(contact.account_id, fn ->
            assert {:ok, _} = Contacts.update_contact(contact, %{first_name: "After commit"})
            send(parent, :native_changed_inside_transaction)

            receive do
              :commit -> :done
            after
              5_000 -> Repo.rollback(:test_timeout)
            end
          end)
        end)
      end)

    assert_receive :native_changed_inside_transaction, 5_000
    assert read_pair(contact) == before
    send(writer.pid, :commit)
    assert {:ok, :done} = Task.await(writer, 10_000)
    after_pair = read_pair(contact)
    assert after_pair.name == "After commit"
    assert after_pair.revision > before.revision
    assert inspect(after_pair.document) =~ "After commit"
  end

  test "concurrent shared writers serialize native changes and retain both results", %{
    contact: contact
  } do
    parent = self()

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Store.transaction(contact.account_id, fn ->
            assert {:ok, _} = Contacts.update_contact(contact, %{first_name: "First writer"})
            send(parent, :first_writer_inside)

            receive do
              :commit -> :done
            after
              5_000 -> Repo.rollback(:test_timeout)
            end
          end)
        end)
      end)

    assert_receive :first_writer_inside, 5_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:second_backend, pid})
          Contacts.update_contact(contact, %{company: "Second writer company"})
        end)
      end)

    assert_receive {:second_backend, pid}, 5_000
    Sandbox.unboxed_run(Repo, fn -> wait_for_lock(pid, 250) end)
    send(first.pid, :commit)
    assert {:ok, :done} = Task.await(first, 10_000)
    assert {:ok, _} = Task.await(second, 10_000)
    final = read_pair(contact)
    assert final.name == "First writer"
    assert final.company == "Second writer company"
    assert inspect(final.document) =~ "First writer"
    assert inspect(final.document) =~ "Second writer company"
  end

  defp read_pair(contact) do
    Sandbox.unboxed_run(Repo, fn ->
      native = Repo.get!(Contact, contact.id)
      dav = Repo.get!(ContactDav, contact.id)

      %{
        name: native.first_name,
        company: native.company,
        revision: dav.revision,
        fingerprint: dav.representation_fingerprint,
        etags: {Store.etag(%{dav: dav}, :v30), Store.etag(%{dav: dav}, :v40)},
        document: dav.document
      }
    end)
  end

  defp wait_for_lock(pid, tries) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid])

    cond do
      waiting ->
        :ok

      tries == 0 ->
        flunk("concurrent native writer did not wait for the account lock")

      true ->
        Process.sleep(20)
        wait_for_lock(pid, tries - 1)
    end
  end
end
