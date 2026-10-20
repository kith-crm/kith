defmodule Kith.ContactsDAVTest do
  @moduledoc "Unit tests for DAV-related Contacts context functions."
  use Kith.DataCase, async: true

  alias Kith.Contacts

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    account_id = user.account_id
    contact = contact_fixture(account_id)
    %{account_id: account_id, contact: contact}
  end

  describe "replace_contact_children/3" do
    test "replaces existing children with new data", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [%{value: "old@example.com", label: "Home"}],
        phones: [],
        urls: [],
        addresses: []
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      # Replace with new data
      nested2 = %{
        emails: [%{value: "new@example.com", label: "Work"}],
        phones: [%{value: "555-1234", label: "Mobile"}],
        urls: [],
        addresses: []
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested2)

      # Verify old email is gone and new data is present
      contact = Kith.Repo.preload(contact, [contact_fields: :contact_field_type], force: true)
      values = Enum.map(contact.contact_fields, & &1.value)
      assert "new@example.com" in values
      assert "555-1234" in values
      refute "old@example.com" in values
    end

    test "handles empty lists", %{contact: contact, account_id: aid} do
      nested = %{emails: [], phones: [], urls: [], addresses: []}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end

    test "replaces children with address data", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [%{value: "addr@example.com", label: "Work"}],
        phones: [],
        urls: [],
        addresses: [
          %{
            label: "Home",
            line1: "123 Main St",
            city: "Springfield",
            province: "IL",
            postal_code: "62701",
            country: "US"
          }
        ]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      contact =
        Kith.Repo.preload(contact, [:addresses, contact_fields: :contact_field_type], force: true)

      assert length(contact.addresses) == 1
      assert hd(contact.addresses).line1 == "123 Main St"
      assert hd(contact.addresses).city == "Springfield"

      values = Enum.map(contact.contact_fields, & &1.value)
      assert "addr@example.com" in values
    end
  end

  test "CDV-51: seeded scheme protocols preserve TEL and EMAIL labels", %{
    contact: contact,
    account_id: aid
  } do
    nested = %{
      emails: [%{value: "home@example.test", label: "Home"}],
      phones: [%{value: "+15550001111", label: "Cell"}],
      urls: [],
      addresses: []
    }

    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    card = Kith.DAV.VCardAdapter.contact_to_vcard(contact)
    assert card =~ "EMAIL;TYPE=HOME:home@example.test"
    assert card =~ "TEL;TYPE=CELL:+15550001111"
  end

  test "CDV-58: client properties and parameters survive DAV without overriding UI edits", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:opaque-id\r\nN:Last;First;Middle;Dr;Jr\r\nFN:Dr First Middle Last Jr\r\nORG:Company;Unit\r\nEMAIL;TYPE=WORK,INTERNET;PREF=1;X-CLIENT=custom:a@example.test\r\nitem1.TEL;TYPE=CELL:+15550001111\r\nitem1.X-ABLabel:Mobile\r\nADR;TYPE=HOME:PO 4;Suite;Street;City;Region;Zip;Country\r\nURL;TYPE=WORK:https://example.test\r\nPRODID:-//Client//EN\r\nX-ABUID:apple-id\r\nX-CUSTOM:opaque\r\nX-PHONETIC-FIRST-NAME:First\r\nX-MOZILLA-HTML:TRUE\r\nIMPP;TYPE=HOME:xmpp:first@example.test\r\nEND:VCARD\r\n"

    {attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(body, account_id: aid)
    assert {:ok, contact} = Contacts.update_contact(contact, attrs)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    contact = Kith.Repo.get!(Contacts.Contact, contact.id)

    output =
      Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: :v40)
      |> String.replace("\r\n ", "")

    for line <- [
          "FN:Dr First Middle Last Jr",
          "N:Last;First;Middle;Dr;Jr",
          "ORG:Company;Unit",
          "EMAIL;TYPE=WORK,INTERNET;PREF=1;X-CLIENT=custom:a@example.test",
          "item1.TEL;TYPE=CELL:+15550001111",
          "item1.X-ABLabel:Mobile",
          "ADR;TYPE=HOME:PO 4;Suite;Street;City;Region;Zip;Country",
          "URL;TYPE=WORK:https://example.test",
          "PRODID:-//Client//EN",
          "X-ABUID:apple-id",
          "X-CUSTOM:opaque",
          "X-PHONETIC-FIRST-NAME:First",
          "X-MOZILLA-HTML:TRUE",
          "IMPP;TYPE=HOME:xmpp:first@example.test"
        ] do
      assert output =~ line
    end

    assert {:ok, changed} =
             Contacts.update_contact(contact, %{first_name: "Edited", company: "New company"})

    output = Kith.DAV.VCardAdapter.contact_to_vcard(changed, version: :v40)
    assert output =~ "FN:Edited Middle Last"
    assert output =~ "ORG:New company\r\n"
    refute output =~ "ORG:Company"

    field =
      contact.id |> Contacts.list_contact_fields() |> Enum.find(&(&1.value == "a@example.test"))

    assert {:ok, _} =
             Contacts.update_contact_field(field, %{label: "Home"})

    output =
      Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id),
        version: :v40
      )

    assert output =~ "EMAIL;TYPE=HOME:a@example.test"
    refute output =~ "TYPE=WORK,INTERNET"
  end

  test "CDV-73: yearless birthdays survive both versions without inventing a year", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Leap;Yearless;;;\r\nFN:Yearless Leap\r\nBDAY:--0229\r\nEND:VCARD\r\n"

    {attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(body, account_id: aid)
    assert attrs["birthdate"] == "2000-02-29"
    assert attrs["birthdate_year_unknown"] == true
    assert {:ok, contact} = Contacts.update_contact(contact, attrs)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    contact = Kith.Repo.get!(Contacts.Contact, contact.id)

    for version <- [:v30, :v40] do
      card = Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: version)
      assert card =~ if(version == :v40, do: "BDAY:--0229", else: "X-KITH-BDAY:--0229")
      {attrs, _nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(card)
      assert attrs["birthdate"] == "2000-02-29"
      assert attrs["birthdate_year_unknown"] == true
    end
  end

  test "CDV-79: GET PUT-back preserves native fields and address metadata", %{
    contact: contact,
    account_id: aid
  } do
    {:ok, type} = Contacts.create_contact_field_type(aid, %{name: "Native secret"})

    {:ok, secret} =
      Contacts.create_contact_field(contact, %{
        contact_field_type_id: type.id,
        value: "Native-only value"
      })

    email_type = Kith.Repo.get_by!(Contacts.ContactFieldType, protocol: "mailto:")

    {:ok, email} =
      Contacts.create_contact_field(contact, %{
        contact_field_type_id: email_type.id,
        value: "a@example.test",
        label: "Home"
      })

    address =
      %Contacts.Address{}
      |> Contacts.Address.changeset(%{
        contact_id: contact.id,
        account_id: aid,
        line1: "Street",
        latitude: 31.9,
        longitude: 35.2
      })
      |> Kith.Repo.insert!()

    card = Kith.DAV.VCardAdapter.contact_to_vcard(contact)
    {_attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(card)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    assert Kith.Repo.get(Contacts.ContactField, secret.id).value == "Native-only value"
    assert Kith.Repo.get(Contacts.ContactField, email.id).value == "a@example.test"
    assert Kith.Repo.get(Contacts.Address, address.id).latitude == 31.9
    assert length(Contacts.list_contact_fields(contact.id)) == 2
  end

  test "CDV-80: RELATED resolves exact visible UIDs and preserves relationship rows", %{
    contact: contact,
    account_id: aid
  } do
    target = contact_fixture(aid)
    {:ok, target} = Contacts.put_dav_identity(target, %{dav_uid: "custom-related-uid"})

    nested = %{
      emails: [],
      phones: [],
      urls: [],
      addresses: [],
      related: [
        %{value: target.dav_uid, type: "friend"},
        %{value: target.dav_uid, type: "friend"}
      ]
    }

    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    assert [relationship] = Contacts.list_relationships(contact.id)

    card =
      Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id),
        version: :v40
      )

    assert card =~ "RELATED;TYPE=friend;VALUE=text:custom-related-uid"
    {_attrs, parsed} = Kith.DAV.VCardAdapter.vcard_to_attrs(card, account_id: aid)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, parsed)
    assert [%{id: id}] = Contacts.list_relationships(contact.id)
    assert id == relationship.id
    card30 = Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id))
    {_attrs, parsed30} = Kith.DAV.VCardAdapter.vcard_to_attrs(card30, account_id: aid)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, parsed30)

    card40 =
      Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id),
        version: :v40
      )

    assert length(Regex.scan(~r/^RELATED[;:]/m, card40)) == 1

    for uid <- [
          "urn:evil:kith-contact-#{target.id}-k-extra",
          "kith-contact-#{target.id}",
          "urn:uuid:kith-contact-#{target.id}"
        ] do
      other = contact_fixture(aid)

      assert {:ok, :ok} =
               Contacts.replace_contact_children(other, aid, %{
                 nested
                 | related: [%{value: uid, type: "friend"}]
               })

      assert Contacts.list_relationships(other.id) == []
    end

    {:ok, target} = Contacts.put_dav_identity(target, %{dav_uid: "kith-contact-#{target.id}-k"})

    assert {:ok, :ok} =
             Contacts.replace_contact_children(contact, aid, %{
               nested
               | related: [%{value: target.dav_uid, type: "friend"}]
             })

    assert [_] = Contacts.list_relationships(contact.id)

    card =
      Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id),
        version: :v40
      )

    assert card =~ "RELATED;TYPE=friend;VALUE=text:#{target.dav_uid}"
  end

  test "CDV-83: text UIDs are escaped, folded and declared as text in 4.0", %{contact: contact} do
    uid = String.duplicate("客", 40) <> ";opaque\nFN:Injected"
    {:ok, contact} = Contacts.put_dav_identity(contact, %{dav_uid: uid})

    for version <- [:v30, :v40] do
      card = Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: version)
      refute card |> String.replace("\r\n", "") |> String.contains?("\n")
      for line <- String.split(card, "\r\n"), do: assert(byte_size(line) <= 75)
      assert length(Regex.scan(~r/^FN:/m, card)) == 1
      if version == :v40, do: assert(card =~ "UID;VALUE=text:")
      assert {:ok, [parsed]} = Kith.VCard.Parser.parse(card)
      assert parsed.uid == uid
    end
  end

  test "CDV-84: telephone URIs become phone-number values for 3.0", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:URI;Telephone;;;\r\nFN:Telephone URI\r\nTEL;TYPE=CELL;VALUE=uri:tel:+15550004444\r\nEND:VCARD\r\n"

    {attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(body)
    assert hd(nested.phones).value == "+15550004444"
    assert {:ok, contact} = Contacts.update_contact(contact, attrs)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    card = Kith.DAV.VCardAdapter.contact_to_vcard(Kith.Repo.get!(Contacts.Contact, contact.id))
    assert card =~ "TEL;TYPE=CELL:+15550004444"
    refute card =~ "VALUE=uri"
    {_attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(card)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    assert [%{value: "+15550004444"}] = Contacts.list_contact_fields(contact.id)
  end

  test "CDV-86: Apple social profiles stay one field across repeated PUT-backs", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Social;Sam;;;\r\nFN:Sam Social\r\nitem3.X-SOCIALPROFILE;type=twitter;x-user=sam:https://twitter.com/sam\r\nitem3.X-ABLabel:Twitter\r\nX-TWITTER:https://twitter.com/sam2\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    first = dav_get(contact, :v30)

    for _ <- 1..3 do
      contact = dav_put(contact, aid, dav_get(contact, :v30))
      assert dav_get(contact, :v30) == first
      assert length(Contacts.list_contact_fields(contact.id)) == 2
    end

    assert first =~ "item3.X-SOCIALPROFILE;type=twitter;x-user=sam:https://twitter.com/sam\r\n"
    assert first =~ "item3.X-ABLabel:Twitter\r\n"
    assert first =~ "X-TWITTER:https://twitter.com/sam2\r\n"
    refute first =~ "URL"
  end

  test "CDV-87: retained metadata never resurrects natively deleted children", %{
    contact: contact,
    account_id: aid
  } do
    target = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(target, %{dav_uid: "urn:uuid:cdv87-target"})

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Deleted;Dee;;;\r\nFN:Dee Deleted\r\nIMPP;TYPE=HOME:xmpp:dee@example.test\r\nRELATED;TYPE=friend:urn:uuid:cdv87-target\r\nitem1.TEL;TYPE=CELL:+15550009999\r\nitem1.X-ABLabel:Mobile\r\nitem2.X-ABDATE:2010-06-01\r\nitem2.X-ABLabel:_$!<Anniversary>!$_\r\nEMAIL;TYPE=WORK:keep@example.test\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    assert [_relationship] = Contacts.list_relationships(contact.id)
    card30 = dav_get(contact, :v30)
    assert card30 =~ ".X-ABRELATEDNAMES:"
    contact = dav_put(contact, aid, card30)

    for field <- Contacts.list_contact_fields(contact.id),
        field.value in ["xmpp:dee@example.test", "+15550009999"],
        do: {:ok, _} = Contacts.delete_contact_field(field)

    [relationship] = Contacts.list_relationships(contact.id)
    {:ok, _} = Contacts.delete_relationship(relationship)

    for version <- [:v30, :v40] do
      card = dav_get(contact, version)
      refute card =~ "IMPP"
      refute card =~ "RELATED"
      refute card =~ "item1."
      assert card =~ "item2.X-ABDATE:2010-06-01\r\n"
      assert card =~ "item2.X-ABLabel:_$!<Anniversary>!$_\r\n"
      contact = dav_put(contact, aid, card)

      assert Enum.map(Contacts.list_contact_fields(contact.id), & &1.value) == [
               "keep@example.test"
             ]

      assert Contacts.list_relationships(contact.id) == []
    end
  end

  test "CDV-88: relationships to archived or trashed targets survive unchanged PUT-backs", %{
    contact: contact,
    account_id: aid
  } do
    archived = contact_fixture(aid)
    {:ok, archived} = Contacts.put_dav_identity(archived, %{dav_uid: "urn:uuid:cdv88-archived"})
    trashed = contact_fixture(aid)

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Hidden;Hal;;;\r\nFN:Hal Hidden\r\nRELATED;TYPE=friend:urn:uuid:cdv88-archived\r\nRELATED;TYPE=sibling:urn:uuid:kith-contact-#{trashed.id}\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    ids = contact.id |> Contacts.list_relationships() |> Enum.map(& &1.id) |> Enum.sort()
    assert length(ids) == 2
    {:ok, _} = Contacts.archive_contact(archived)
    {:ok, _} = Contacts.soft_delete_contact(trashed)

    for version <- [:v30, :v40, :v40] do
      contact = dav_put(contact, aid, dav_get(contact, version))

      assert contact.id |> Contacts.list_relationships() |> Enum.map(& &1.id) |> Enum.sort() ==
               ids
    end

    # A PUT naming only a hidden target neither duplicates nor drops either row
    contact = dav_put(contact, aid, String.replace(body, ~r/RELATED;TYPE=sibling.*\r\n/, ""))
    assert contact.id |> Contacts.list_relationships() |> Enum.map(& &1.id) |> Enum.sort() == ids
  end

  defp dav_put(contact, aid, body) do
    {attrs, nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(body, account_id: aid)
    {:ok, contact} = Contacts.update_contact(contact, attrs)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    Kith.Repo.get!(Contacts.Contact, contact.id)
  end

  defp dav_get(contact, version) do
    contact = Kith.Repo.get!(Contacts.Contact, contact.id)

    contact
    |> Kith.DAV.VCardAdapter.contact_to_vcard(version: version)
    |> String.replace(~r/^REV:.*\r\n/m, "")
  end

  describe "touch_contact!/1" do
    test "bumps updated_at", %{contact: contact} do
      old_updated_at = contact.updated_at
      # Ensure at least 1 second passes
      Process.sleep(1100)
      updated = Contacts.touch_contact!(contact)
      assert DateTime.compare(updated.updated_at, old_updated_at) == :gt
    end
  end

  describe "list_contacts_changed_since/2" do
    test "lists contacts written after the position, hidden ones included", %{
      account_id: aid,
      contact: contact
    } do
      quiet = contact_fixture(aid)
      %{seq: seq} = Contacts.dav_sync_state(aid)
      assert [] = Contacts.list_contacts_changed_since(aid, seq)

      {:ok, _} = Contacts.soft_delete_contact(contact)
      created = contact_fixture(aid)

      ids = aid |> Contacts.list_contacts_changed_since(seq) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([contact.id, created.id])
      refute quiet.id in ids
    end
  end

  describe "replace_contact_children/3 — tags (CATEGORIES)" do
    test "creates tags from category names", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        categories: ["Family", "VIP"]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      contact = Kith.Repo.preload(contact, [:tags], force: true)
      tag_names = Enum.map(contact.tags, & &1.name) |> Enum.sort()
      assert tag_names == ["Family", "VIP"]
    end

    test "replaces existing tags on subsequent call", %{contact: contact, account_id: aid} do
      nested1 = %{emails: [], phones: [], urls: [], addresses: [], categories: ["OldTag"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested1)

      nested2 = %{emails: [], phones: [], urls: [], addresses: [], categories: ["NewTag"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested2)

      contact = Kith.Repo.preload(contact, [:tags], force: true)
      tag_names = Enum.map(contact.tags, & &1.name)
      assert tag_names == ["NewTag"]
    end

    test "reuses existing tag by name", %{contact: contact, account_id: aid} do
      {:ok, _tag} = Contacts.create_tag(aid, %{"name" => "Friends"})

      nested = %{emails: [], phones: [], urls: [], addresses: [], categories: ["Friends"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      # Should not create a duplicate
      all_tags = Contacts.list_tags(aid)
      friends_tags = Enum.filter(all_tags, &(&1.name == "Friends"))
      assert length(friends_tags) == 1
    end

    test "handles empty categories list", %{contact: contact, account_id: aid} do
      nested = %{emails: [], phones: [], urls: [], addresses: [], categories: []}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end
  end

  describe "replace_contact_children/3 — relationships (RELATED)" do
    test "creates relationships from related entries", %{contact: contact, account_id: aid} do
      other = contact_fixture(aid, %{first_name: "Bob"})

      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        related: [%{value: "kith-contact-#{other.id}", type: "Friend"}]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      rels = Contacts.list_relationships(contact.id)
      assert length(rels) >= 1
    end

    test "skips relationships where related contact does not exist",
         %{contact: contact, account_id: aid} do
      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        related: [%{value: "kith-contact-999999", type: "Friend"}]
      }

      # Should not crash
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end
  end
end
