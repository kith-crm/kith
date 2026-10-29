defmodule Kith.DAV.LifecycleBoundaryTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Repo}
  alias Kith.Contacts.{Contact, ContactField, RelationshipType}
  alias Kith.DAV.{AddressObject, Audit, ContactDav, FieldRegistry, Store, VCardAdapter}

  setup do
    user = user_fixture()
    %{user: user, account: user.account_id, contact: contact_fixture(user.account_id)}
  end

  test "audit reports duplicate candidates and untrusted fields without deleting or reclassifying",
       c do
    type = FieldRegistry.canonical_type!(:emails)
    first = contact_field_fixture(c.contact, type.id, %{"value" => "duplicate@example.com"})
    second = contact_field_fixture(c.contact, type.id, %{"value" => "duplicate@example.com"})

    {:ok, custom_type} =
      Contacts.create_contact_field_type(c.account, %{
        name: "Private EMAIL",
        protocol: "mailto",
        vcard_label: "EMAIL"
      })

    private =
      contact_field_fixture(c.contact, custom_type.id, %{"value" => "private@example.com"})

    foreign = contact_fixture(user_fixture().account_id)
    foreign_field = contact_field_fixture(foreign, type.id, %{"value" => "duplicate@example.com"})
    dav = Repo.get!(ContactDav, c.contact.id)
    {:ok, _} = Store.put_extras(dav, ["X-LEGACY:quarantined"])
    before_rows = Contacts.list_contact_fields(c.contact.id)
    before_dav = Repo.get!(ContactDav, c.contact.id)

    report = Audit.report(c.account)
    assert [%{contact_id: id, field_ids: ids}] = report.duplicate_candidates
    assert id == c.contact.id
    assert Enum.sort(ids) == Enum.sort([first.id, second.id])
    assert private.id in report.untrusted_protocol_field_ids
    refute foreign_field.id in List.flatten(Enum.map(report.duplicate_candidates, & &1.field_ids))
    assert report.quarantined_extras_contact_ids == [c.contact.id]
    assert Contacts.list_contact_fields(c.contact.id) == before_rows
    assert Repo.get!(ContactDav, c.contact.id) == before_dav
    assert Repo.get!(Kith.Contacts.ContactFieldType, custom_type.id).system_key == nil
  end

  test "backfill initializes sanitized documents without copying legacy private exports", c do
    {:ok, contact} =
      Contacts.update_contact(c.contact, %{description: "Private legacy description"})

    dav = Repo.get!(ContactDav, contact.id)

    legacy =
      Repo.update!(
        Ecto.Changeset.change(dav,
          document: %{},
          representation_fingerprint: nil,
          extras: ["NOTE:Legacy echoed private text"],
          requires_precondition: true
        )
      )

    assert Audit.report(c.account).pending_document_contact_ids == [contact.id]

    report = Audit.backfill(c.account)
    assert report.pending_document_contact_ids == []
    migrated = Repo.get!(ContactDav, contact.id)
    assert migrated.uid == legacy.uid
    assert migrated.resource_name == legacy.resource_name
    assert migrated.requires_precondition
    body = VCardAdapter.contact_to_vcard(contact)
    refute body =~ "Private legacy description"
    refute body =~ "Legacy echoed private text"
    assert migrated.extras == legacy.extras

    Audit.backfill(c.account)
    assert Repo.get!(ContactDav, contact.id) == migrated
  end

  test "account reset preserves the account and advances its sync floor", c do
    neighbor = contact_fixture(c.account)

    type =
      Repo.one!(
        from t in RelationshipType, where: is_nil(t.account_id) and t.system_key == "friend"
      )

    relationship_fixture(c.contact, neighbor, type.id)
    foreign = contact_fixture(user_fixture().account_id)
    foreign_dav = Repo.get!(ContactDav, foreign.id)
    put_card(c.contact, ["NOTE:Client-only reset note"])
    before = Store.sync_state(c.account)

    assert :ok =
             Kith.Workers.AccountResetWorker.perform(%Oban.Job{
               args: %{"account_id" => c.account}
             })

    assert Repo.get!(Kith.Accounts.Account, c.account)
    assert Repo.all(from contact in Contact, where: contact.account_id == ^c.account) == []
    assert Repo.all(from dav in ContactDav, where: dav.account_id == ^c.account) == []
    assert Store.sync_state(c.account).floor > before.token
    assert Store.sync_state(c.account).token == Store.sync_state(c.account).floor
    assert Repo.get!(ContactDav, foreign.id) == foreign_dav
  end

  test "hard deletion republishes visible relationship neighbors and leaves controls unchanged",
       c do
    target = contact_fixture(c.account, %{first_name: "Visible relationship target"})
    control = contact_fixture(c.account)

    type =
      Repo.one!(
        from t in RelationshipType, where: is_nil(t.account_id) and t.system_key == "friend"
      )

    relationship_fixture(c.contact, target, type.id)
    before = Repo.get!(ContactDav, c.contact.id)
    control_before = Repo.get!(ContactDav, control.id)
    target_dav = Repo.get!(ContactDav, target.id)
    before_card = VCardAdapter.contact_to_vcard(c.contact, version: :v40)
    assert before_card =~ target_dav.uid

    assert {:ok, _} = Contacts.hard_delete_contact(target)
    assert Repo.get(ContactDav, target.id) == nil
    assert Repo.get!(ContactDav, c.contact.id).revision > before.revision
    refute VCardAdapter.contact_to_vcard(c.contact, version: :v40) =~ target_dav.uid
    assert Repo.get!(ContactDav, control.id) == control_before
    assert Store.sync_state(c.account).floor > target_dav.revision
  end

  test "merge keeps survivor client metadata, loser documents and valid moved native bindings",
       c do
    loser = contact_fixture(c.account, %{first_name: "Merge loser"})

    {:ok, survivor} =
      Contacts.update_contact(c.contact, %{description: "Survivor private description"})

    {:ok, loser} = Contacts.update_contact(loser, %{description: "Loser private description"})
    put_card(survivor, ["NOTE:Survivor client note", "EMAIL:survivor@example.com"])
    put_card(loser, ["NOTE:Loser client note", "EMAIL:loser@example.com"])
    loser_field = Repo.one!(from f in ContactField, where: f.contact_id == ^loser.id)
    loser_dav = Repo.get!(ContactDav, loser.id)
    survivor_dav = Repo.get!(ContactDav, survivor.id)

    assert {:ok, _merged} = Contacts.merge_contacts(survivor.id, loser.id)
    survivor = Repo.reload!(survivor)
    loser = Repo.reload!(loser)
    assert survivor.description == "Survivor private description"
    assert loser.description == "Loser private description"
    assert loser.deleted_at != nil
    assert Repo.get!(ContactDav, survivor.id).uid == survivor_dav.uid
    assert Repo.get!(ContactDav, loser.id).uid == loser_dav.uid
    assert Repo.get!(ContactDav, loser.id).resource_name == loser_dav.resource_name
    assert Repo.get!(ContactField, loser_field.id).contact_id == survivor.id

    body = VCardAdapter.contact_to_vcard(survivor, version: :v40)
    assert body =~ "NOTE:Survivor client note"
    refute body =~ "NOTE:Loser client note"
    assert body =~ "loser@example.com"
    refute body =~ "private description"
    loser_document = Repo.get!(ContactDav, loser.id).document
    assert inspect(loser_document) =~ "Loser client note"

    for entry <- Repo.get!(ContactDav, survivor.id).document["properties"],
        binding = entry["binding"],
        is_binary(binding),
        String.starts_with?(binding, "field:") do
      ["field", id | _] = String.split(binding, ":")
      assert Repo.get!(ContactField, String.to_integer(id)).contact_id == survivor.id
    end
  end

  test "merge dedupe rebinds survivor metadata when older loser fields and addresses win", c do
    loser = contact_fixture(c.account, %{first_name: "Older record owner"})
    type = FieldRegistry.canonical_type!(:emails)
    older_email = contact_field_fixture(loser, type.id, %{"value" => "same@example.com"})

    older_address =
      address_fixture(loser, %{
        "line1" => "123 Main St",
        "postal_code" => "12345",
        "city" => "Older city"
      })

    newer_email =
      contact_field_fixture(c.contact, type.id, %{
        "value" => "same@example.com",
        "label" => "Home"
      })

    newer_address =
      address_fixture(c.contact, %{
        "line1" => "123 Main St",
        "postal_code" => "12345",
        "line2" => "Suite",
        "city" => "Survivor city",
        "province" => "Region",
        "country" => "US"
      })

    put_card(c.contact, [
      "mail.EMAIL;TYPE=home;PID=5.1;X-CLIENT=survivor-email:same@example.com",
      "mail.X-ABLabel:Survivor client email label",
      "place.ADR;TYPE=home;PID=6.1;X-CLIENT=survivor-address:PO BOX;Suite;123 Main St;Survivor city;Region;12345;US",
      "place.X-ABLabel:Survivor client address label",
      "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111",
      "NOTE:Survivor client-only note",
      "X-CLIENT-BINDING:field:#{newer_email.id}:EMAIL"
    ])

    before = Repo.get!(ContactDav, c.contact.id).document
    assert Enum.any?(before["properties"], &(&1["binding"] == "field:#{newer_email.id}:EMAIL"))
    assert Enum.any?(before["properties"], &(&1["binding"] == "address:#{newer_address.id}:ADR"))

    assert {:ok, _} = Contacts.merge_contacts(c.contact.id, loser.id)
    assert Repo.get(ContactField, newer_email.id) == nil
    assert Repo.get(Kith.Contacts.Address, newer_address.id) == nil
    assert [retained_email] = Contacts.list_contact_fields(c.contact.id)
    assert retained_email.id == older_email.id
    assert [retained_address] = Contacts.list_addresses(c.contact.id)
    assert retained_address.id == older_address.id
    document = Repo.get!(ContactDav, c.contact.id).document
    assert Enum.any?(document["properties"], &(&1["binding"] == "field:#{older_email.id}:EMAIL"))

    assert Enum.any?(
             document["properties"],
             &(&1["binding"] == "address:#{older_address.id}:ADR")
           )

    body =
      VCardAdapter.contact_to_vcard(Repo.reload!(c.contact), version: :v40)
      |> String.replace(~r/\r\n[ \t]/, "")

    assert body =~ "mail.EMAIL"
    assert body =~ "X-CLIENT=survivor-email"
    assert body =~ "PID=5.1"
    assert body =~ "mail.X-ABLabel:Survivor client email label"
    assert body =~ "place.ADR"
    assert body =~ "X-CLIENT=survivor-address"
    assert body =~ "PID=6.1"
    assert body =~ "PO BOX"
    assert body =~ "Older city"
    assert body =~ "place.X-ABLabel:Survivor client address label"
    assert body =~ "NOTE:Survivor client-only note"
    assert body =~ "X-CLIENT-BINDING:field:#{newer_email.id}:EMAIL"
  end

  test "explicit Kith vCard import retains private NOTE intent without exporting it through DAV",
       c do
    input =
      Enum.join(
        [
          "BEGIN:VCARD",
          "VERSION:4.0",
          "FN:Explicit import",
          "N:Import;Explicit;;;",
          "NOTE:Imported private description",
          "EMAIL:import@example.com",
          "END:VCARD",
          ""
        ],
        "\r\n"
      )

    assert {:ok, %{contacts: 1, error_count: 0}} =
             Kith.Imports.Sources.VCard.import(c.account, c.user.id, input, [])

    contact =
      Repo.one!(
        from contact in Contact,
          where: contact.account_id == ^c.account and contact.first_name == "Explicit"
      )

    assert contact.description == "Imported private description"
    dav_card = VCardAdapter.contact_to_vcard(contact, version: :v40)
    refute dav_card =~ "Imported private description"
    assert dav_card =~ "EMAIL:import@example.com"

    native = Contacts.get_contact(c.account, contact.id, preload: Contacts.export_preloads())
    assert Kith.VCard.Serializer.serialize(native) =~ "NOTE:Imported private description"
  end

  defp put_card(contact, properties) do
    dav = Repo.get!(ContactDav, contact.id)

    input =
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

    conn = Plug.Test.conn(:put, "/dav/addressbooks/default/" <> dav.resource_name, input)
    conn = Plug.Conn.assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    assert %{status: 204} = AddressObject.put(conn, dav.resource_name, input)
  end
end
