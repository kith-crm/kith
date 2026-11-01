defmodule KithWeb.API.ContactExportControllerTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Accounts
  alias Kith.VCard.Parser

  setup %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw_token}"), user: user}
  end

  test "GET /api/contacts/export.vcf exports every active contact", %{conn: conn, user: user} do
    for i <- 1..105, do: contact_fixture(user.account_id, %{first_name: "Export #{i}"})
    other = user_fixture()
    contact_fixture(other.account_id, %{first_name: "Other account"})
    deleted = contact_fixture(user.account_id, %{first_name: "Deleted"})
    Kith.Contacts.soft_delete_contact(deleted)
    conn = get(conn, ~p"/api/contacts/export.vcf")
    assert conn.status == 200
    assert {:ok, contacts} = Parser.parse(conn.resp_body)
    assert length(contacts) == 105
    refute Enum.any?(contacts, &(&1.first_name in ["Deleted", "Other account"]))
  end

  test "explicit exports preserve identity, legacy extras and names while DAV applies its boundary",
       %{
         conn: conn,
         user: user
       } do
    contact = contact_fixture(user.account_id, %{first_name: "Alice"})

    target =
      contact_fixture(user.account_id, %{first_name: "Bob", last_name: nil, display_name: "Bob"})

    {:ok, type} =
      Kith.Contacts.create_relationship_type(user.account_id, %{
        name: "Friend",
        reverse_name: "Friend"
      })

    relationship_fixture(contact, target, type.id)
    Kith.DAV.Store.ensure_rows(user.account_id)
    dav = Kith.Repo.get!(Kith.DAV.ContactDav, contact.id)
    uid = Ecto.UUID.generate()

    Kith.Repo.update!(Ecto.Changeset.change(dav, uid: uid, extras: ["X-CUSTOM:kept"]))

    single = get(conn, ~p"/api/contacts/#{contact.id}/export.vcf")
    assert single.status == 200
    assert single.resp_body =~ "UID:urn:uuid:#{uid}\r\n"
    assert single.resp_body =~ "X-ABRELATEDNAMES:Bob\r\n"
    assert single.resp_body =~ "X-CUSTOM:kept\r\nEND:VCARD"

    bulk = get(recycle(conn), ~p"/api/contacts/export.vcf")
    assert bulk.status == 200
    assert bulk.resp_body =~ "UID:urn:uuid:#{uid}\r\n"
    assert bulk.resp_body =~ "X-ABRELATEDNAMES:Bob\r\n"

    target_dav = Kith.Repo.get!(Kith.DAV.ContactDav, target.id)
    card = Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: :v40)
    assert card =~ "UID:urn:uuid:#{uid}\r\n"
    assert card =~ "RELATED;TYPE=contact:urn:uuid:#{target_dav.uid}\r\n"
    refute card =~ "X-CUSTOM:kept"
  end

  test "authorized API exports retain private native description, gender and custom fields", %{
    conn: conn,
    user: user
  } do
    {:ok, gender} = Kith.Contacts.create_gender(user.account_id, %{name: "Private export gender"})

    contact =
      contact_fixture(user.account_id, %{
        description: "Private export description",
        gender_id: gender.id
      })

    {:ok, field_type} =
      Kith.Contacts.create_contact_field_type(user.account_id, %{
        name: "Private export field",
        vcard_label: "X-PRIVATE-EXPORT"
      })

    contact_field_fixture(contact, field_type.id, %{"value" => "Private export field value"})

    single = get(conn, ~p"/api/contacts/#{contact.id}/export.vcf")
    assert single.status == 200
    assert single.resp_body =~ "NOTE:Private export description"
    assert single.resp_body =~ "X-GENDER:Private export gender"
    assert single.resp_body =~ "X-PRIVATE-EXPORT:Private export field value"

    bulk = get(recycle(conn), ~p"/api/contacts/export.vcf")
    assert bulk.status == 200
    assert bulk.resp_body =~ "NOTE:Private export description"
    assert bulk.resp_body =~ "X-GENDER:Private export gender"
    assert bulk.resp_body =~ "X-PRIVATE-EXPORT:Private export field value"

    dav = Kith.DAV.VCardAdapter.contact_to_vcard(contact)
    refute dav =~ "Private export description"
    refute dav =~ "Private export gender"
    refute dav =~ "Private export field value"
  end
end
