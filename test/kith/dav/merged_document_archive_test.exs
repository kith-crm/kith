defmodule Kith.DAV.MergedDocumentArchiveTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts
  alias Kith.Contacts.{ContactField, Write}
  alias Kith.DAV.{AddressObject, ContactDav, Store, VCardAdapter}

  setup do
    account = user_fixture().account_id
    %{account: account, survivor: contact_fixture(account), loser: contact_fixture(account)}
  end

  test "merge archives the full loser document without restoring cached shared values", c do
    put_card(c.loser, [
      "mail.EMAIL;TYPE=work;PID=5.1;X-CLIENT=archived-mail:archived-only@example.com",
      "mail.X-ABLabel:Archived client mail label",
      "place.ADR;TYPE=home;PID=6.1;X-CLIENT=archived-place:Archived PO BOX;;Archived native street;City;Region;12345;US",
      "place.X-ABLabel:Archived client address label",
      "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111",
      "NOTE:Client history sentinel"
    ])

    before = Repo.get!(ContactDav, c.loser.id)
    [field] = Contacts.list_contact_fields(c.loser.id)
    [address] = Contacts.list_addresses(c.loser.id)
    assert before.archived_document == nil
    assert Enum.any?(before.document["properties"], &(&1["binding"] == "field:#{field.id}:EMAIL"))

    assert Enum.any?(
             before.document["properties"],
             &(&1["binding"] == "address:#{address.id}:ADR")
           )

    assert {:ok, _} = Contacts.merge_contacts(c.survivor.id, c.loser.id)
    merged_loser = Repo.reload!(c.loser)
    archived = Repo.get!(ContactDav, c.loser.id)
    assert merged_loser.deleted_at
    assert archived.archived_document == before.document
    assert archived.uid == before.uid
    assert archived.resource_name == before.resource_name
    assert Repo.get!(ContactDav, c.survivor.id).archived_document == nil
    assert Repo.get!(ContactField, field.id).contact_id == c.survivor.id
    assert Repo.get!(Kith.Contacts.Address, address.id).contact_id == c.survivor.id

    # Restore projects current native ownership. History cannot resurrect the
    # shared rows that the authorized merge moved to the survivor.
    assert {:ok, restored} = Contacts.restore_contact(merged_loser)
    body = VCardAdapter.contact_to_vcard(restored, version: :v40)
    refute body =~ "archived-only@example.com"
    refute body =~ "Archived native street"
    refute body =~ "Archived PO BOX"
    refute body =~ "X-CLIENT=archived-mail"
    refute body =~ "X-CLIENT=archived-place"
    assert Contacts.list_contact_fields(restored.id) == []
    assert Contacts.list_addresses(restored.id) == []

    put_card(restored, [
      "EMAIL:current@example.com",
      "NOTE:Current client note",
      "X-KITH-ARCHIVED-DOCUMENT:Client echo only"
    ])

    after_put = Repo.get!(ContactDav, restored.id)
    assert after_put.archived_document == before.document
    assert Repo.get!(ContactField, field.id).contact_id == c.survivor.id
    [new_field] = Contacts.list_contact_fields(restored.id)
    assert new_field.value == "current@example.com"
    assert new_field.id != field.id
    current = VCardAdapter.contact_to_vcard(Repo.reload!(restored), version: :v40)
    assert current =~ "EMAIL:current@example.com"
    assert current =~ "NOTE:Current client note"
    assert current =~ "X-KITH-ARCHIVED-DOCUMENT:Client echo only"
    refute current =~ "archived-only@example.com"
  end

  test "private archive-only changes cannot change DAV bytes validators or timestamps", c do
    before = Repo.get!(ContactDav, c.loser.id)
    v30 = VCardAdapter.contact_to_vcard(c.loser, version: :v30)
    v40 = VCardAdapter.contact_to_vcard(c.loser, version: :v40)

    history = %{
      "schema_version" => 1,
      "source_version" => "v40",
      "properties" => [
        %{
          "id" => Ecto.UUID.generate(),
          "binding" => nil,
          "property" => %{
            "group" => nil,
            "name" => "EMAIL",
            "normalized_name" => "EMAIL",
            "parameters" => [],
            "value" => "private-history@example.com"
          }
        }
      ]
    }

    Repo.update!(Ecto.Changeset.change(before, archived_document: history))
    assert :ok = Store.touch(c.account, [c.loser.id])
    after_history = Repo.get!(ContactDav, c.loser.id)
    assert after_history.archived_document == history
    assert after_history.revision == before.revision
    assert after_history.representation_modified_at == before.representation_modified_at
    assert after_history.representation_fingerprint == before.representation_fingerprint
    assert VCardAdapter.contact_to_vcard(c.loser, version: :v30) == v30
    assert VCardAdapter.contact_to_vcard(c.loser, version: :v40) == v40
  end

  test "failed merge rolls back archive replacement alongside native ownership", c do
    put_card(c.loser, ["EMAIL:rollback@example.com", "NOTE:Latest pre-merge document"])
    before = Repo.get!(ContactDav, c.loser.id)
    [field] = Contacts.list_contact_fields(c.loser.id)
    previous_history = %{"schema_version" => 1, "source_version" => "v40", "properties" => []}
    Repo.update!(Ecto.Changeset.change(before, archived_document: previous_history))

    assert {:error, :cancelled} =
             Store.transaction(c.account, fn ->
               assert {:ok, _} = Contacts.merge_contacts(c.survivor.id, c.loser.id)
               assert Repo.get!(ContactDav, c.loser.id).archived_document == before.document
               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(ContactDav, c.loser.id).archived_document == previous_history
    assert Repo.get!(ContactField, field.id).contact_id == c.loser.id
    assert Repo.reload!(c.loser).deleted_at == nil
    assert Write.origin() == :kith

    assert {:ok, _} = Contacts.merge_contacts(c.survivor.id, c.loser.id)
    assert Repo.get!(ContactDav, c.loser.id).archived_document == before.document
  end

  defp put_card(contact, properties) do
    dav = Repo.get!(ContactDav, contact.id)

    raw =
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

    conn = Plug.Test.conn(:put, Store.href(%{contact | dav: dav}), raw)
    conn = Plug.Conn.assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    assert %{status: 204} = AddressObject.put(conn, dav.resource_name, raw)
  end
end
