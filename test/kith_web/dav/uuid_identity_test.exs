defmodule KithWeb.DAV.UUIDIdentityTest do
  use KithWeb.ConnCase, async: true
  import KithWeb.DAV.TestHelpers
  alias Kith.{Contacts, Repo}
  alias Kith.DAV.{ContactDav, Store}

  setup :setup_dav_user

  test "equivalent UUID forms update one resource and conflict at another", c do
    uuid = Ecto.UUID.generate()
    href = "/dav/addressbooks/default/client-choice.vcf"

    assert authed_dav(c, "PUT", href, build_vcard("First", "Name", uid: String.upcase(uuid))).status ==
             201

    contact = Store.get_by_resource_name(c.account_id, "client-choice.vcf")
    assert contact.dav.uid == uuid

    for uid <- [uuid, "urn:uuid:" <> uuid, "URN:UUID:" <> String.upcase(uuid)] do
      assert authed_dav(c, "PUT", href, build_vcard("Updated", "Name", uid: uid)).status == 204

      response =
        authed_dav(
          c,
          "PUT",
          "/dav/addressbooks/default/other.vcf",
          build_vcard("Duplicate", "Name", uid: uid)
        )

      assert response.status == 409
      assert response.resp_body =~ "no-uid-conflict"
      assert response.resp_body =~ href
    end

    for version <- [:v30, :v40] do
      assert Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: version) =~
               "UID:urn:uuid:#{uuid}\r\n"
    end

    assert Contacts.count_contacts(c.account_id) == 1
  end

  test "invalid UID updates are rejected atomically", c do
    href = "/dav/addressbooks/default/atomic.vcf"
    assert authed_dav(c, "PUT", href, build_vcard("Original", "Name")).status == 201
    contact = Store.get_by_resource_name(c.account_id, "atomic.vcf")
    before = Repo.get!(ContactDav, contact.id)

    for uid <- [
          "not-a-uuid",
          "https://example.test/person",
          String.replace(before.uid, "-", ""),
          before.uid <> "\\nFN:Injected"
        ] do
      card = build_vcard("Changed", "Name", uid: uid, categories: ["Must not exist"])
      response = authed_dav(c, "PUT", href, card)
      assert response.status == 403
      assert response.resp_body =~ "valid-address-data"
      assert Repo.get!(ContactDav, contact.id) == before
      assert Repo.get!(Contacts.Contact, contact.id).first_name == "Original"
      assert Contacts.list_tags(c.account_id) == []
    end
  end

  test "normalized identities stay reserved while archived or trashed", c do
    for hide <- [:archive_contact, :soft_delete_contact] do
      contact = Kith.ContactsFixtures.contact_fixture(c.account_id)
      contact_path(contact)
      contact = Repo.preload(contact, :dav)
      apply(Contacts, hide, [contact])
      card = build_vcard("Duplicate", "Name", uid: "URN:UUID:" <> String.upcase(contact.dav.uid))
      assert authed_dav(c, "PUT", "/dav/addressbooks/default/#{hide}.vcf", card).status == 409
    end
  end

  test "BDAY edits and deletion ignore a stale legacy extension", c do
    href = "/dav/addressbooks/default/birthday.vcf"

    assert authed_dav(c, "PUT", href, build_vcard("Birthday", "Test", birthdate: "--0615")).status ==
             201

    card = authed_dav(c, "GET", href).resp_body
    refute card =~ "X-KITH-BDAY"

    edited =
      card
      |> String.replace("BDAY:--0615", "BDAY:1990-07-20")
      |> String.replace("END:VCARD", "X-KITH-BDAY:--0615\r\nEND:VCARD")

    assert authed_dav(c, "PUT", href, edited).status == 204
    assert authed_dav(c, "GET", href).resp_body =~ "BDAY:1990-07-20"
    cleared = String.replace(edited, "BDAY:1990-07-20\r\n", "")
    assert authed_dav(c, "PUT", href, cleared).status == 204
    refute authed_dav(c, "GET", href).resp_body =~ "BDAY"
  end
end
