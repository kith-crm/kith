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
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Deleted;Dee;;;\r\nFN:Dee Deleted\r\nIMPP;TYPE=HOME:xmpp:dee@example.test\r\nRELATED;TYPE=friend:urn:uuid:cdv87-target\r\nitem1.TEL;TYPE=CELL:+15550009999\r\nitem1.X-ABLabel:Mobile\r\nitem2.X-ABDATE:2010-06-01\r\nitem2.X-ABLabel:_$!<Graduation>!$_\r\nEMAIL;TYPE=WORK:keep@example.test\r\nEND:VCARD\r\n"

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
      assert card =~ "item2.X-ABLabel:_$!<Graduation>!$_\r\n"
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

  test "CDV-89: quoted parameters survive GET, native edits and PUT-back", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Quoted;Quinn;;;\r\nFN:Quinn Quoted\r\nTEL;TYPE=\"work,voice\":+15550007777\r\nADR;TYPE=home;LABEL=\"a;b:c\":;;1 Main St;Town;;;\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    assert [%{label: "Work"} = tel] = Contacts.list_contact_fields(contact.id)
    card = dav_get(contact, :v40)
    assert card =~ "TEL;TYPE=\"work,voice\":+15550007777\r\n"

    assert card |> String.replace("\r\n ", "") =~
             "ADR;TYPE=home;LABEL=\"a;b:c\":;;1 Main St;Town;;;\r\n"

    {:ok, _} = Contacts.update_contact_field(tel, %{value: "+15550007778"})
    {:ok, _} = Contacts.update_contact_field(tel, %{label: "Desk; 2nd: floor, east"})

    for version <- [:v30, :v40] do
      card = dav_get(contact, version)
      assert card =~ "TEL;TYPE=\"DESK; 2ND: FLOOR, EAST\":+15550007778\r\n"
      contact = dav_put(contact, aid, card)

      assert [%{id: id, label: "Desk; 2nd: floor, east"}] =
               Contacts.list_contact_fields(contact.id)

      assert id == tel.id
      assert dav_get(contact, version) == card
    end
  end

  test "CDV-92: version-specific retained syntax is converted or dropped", %{
    contact: contact,
    account_id: aid
  } do
    v30 =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Three;Tess;;;\r\nFN:Tess Three\r\nADR;TYPE=HOME:;;1 Main St;Town;;;\r\nLABEL;TYPE=HOME:1 Main St\\nTown\\, North\r\nLABEL;TYPE=WORK:No such address\r\nAGENT:BEGIN:VCARD\\nFN:Agent\\nEND:VCARD\r\nX-CUSTOM;CHARSET=utf-8:opaque\r\nKEY;ENCODING=b;TYPE=PGP:AAEC\r\nLOGO;ENCODING=b;TYPE=PNG:AAEC\r\nMAILER:PigeonMail\r\nCLASS:PUBLIC\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, v30)
    card = dav_get(contact, :v40) |> String.replace("\r\n ", "")
    assert card =~ "ADR;TYPE=HOME;LABEL=\"1 Main St\\nTown, North\":;;1 Main St;Town;;;\r\n"
    assert card =~ "X-CUSTOM:opaque\r\n"
    assert card =~ "KEY:data:application/pgp-keys;base64,AAEC\r\n"
    assert card =~ "LOGO:data:image/png;base64,AAEC\r\n"
    refute card =~ ~r/^(LABEL|AGENT|MAILER|CLASS)[;:]|CHARSET|ENCODING/m
    three = dav_get(contact, :v30)
    assert three =~ "LABEL;TYPE=HOME:1 Main St\\nTown\\, North\r\n"
    refute three =~ "No such address"
    assert three =~ "KEY;ENCODING=b;TYPE=PGP:AAEC\r\n"

    # The 4.0 form converts back to the same 3.0 syntax
    contact = dav_put(contact, aid, card)

    assert dav_get(contact, :v30) |> String.replace("\r\n ", "") =~
             "ADR;TYPE=HOME:;;1 Main St;Town;;;\r\nLABEL;TYPE=HOME:1 Main St\\nTown\\, North\r\n"

    v40 =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Four;Fay;;;\r\nFN:Fay Four\r\nKIND:individual\r\nANNIVERSARY:20100601\r\nLANG:en\r\nCLIENTPIDMAP:1;urn:uuid:abc\r\nEMAIL;PID=1.1;TYPE=work;ALTID=1:fay@example.test\r\nKEY;VALUE=uri:https://example.test/key.asc\r\nLOGO:data:image/png;base64,AAEC\r\nADR;TYPE=home;LABEL=\"1 Main St\\nTown, North\":;;1 Main St;Town;;;\r\nX-CUSTOM;VALUE=uri:https://example.test/x\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, v40)
    card = dav_get(contact, :v30) |> String.replace("\r\n ", "")
    assert card =~ "EMAIL;TYPE=work:fay@example.test\r\n"
    assert card =~ "KEY:https://example.test/key.asc\r\n"
    assert card =~ "LOGO;ENCODING=b;TYPE=PNG:AAEC\r\n"

    assert card =~
             "ADR;TYPE=home:;;1 Main St;Town;;;\r\nLABEL;TYPE=home:1 Main St\\nTown\\, North\r\n"

    assert card =~ "X-CUSTOM:https://example.test/x\r\n"

    refute card =~
             ~r/^(KIND|ANNIVERSARY|LANG|CLIENTPIDMAP)[;:]|;(PID|ALTID|LABEL)=|:data:|VALUE=uri/m

    four = dav_get(contact, :v40) |> String.replace("\r\n ", "")
    assert four =~ "KIND:individual\r\n"
    assert four =~ "EMAIL;PID=1.1;TYPE=work;ALTID=1:fay@example.test\r\n"
  end

  test "CDV-93: retained N prefix and suffix do not outlive a native rename", %{
    contact: contact,
    account_id: aid
  } do
    body =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Lovelace;Ada;Augusta;Countess;PhD\r\nFN:Countess Ada Augusta Lovelace PhD\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    assert dav_get(contact, :v30) =~ "N:Lovelace;Ada;Augusta;Countess;PhD\r\n"

    {:ok, contact} =
      Contacts.update_contact(contact, %{
        first_name: "Grace",
        middle_name: nil,
        last_name: "Hopper"
      })

    for version <- [:v30, :v40] do
      card = dav_get(contact, version)
      assert card =~ "N:Hopper;Grace;;;\r\n"
      assert card =~ "FN:Grace Hopper\r\n"
    end
  end

  test "CDV-94: Apple-renumbered related names are native, whatever their group", %{
    contact: contact,
    account_id: aid
  } do
    target = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(target, %{dav_uid: "urn:uuid:cdv94-target"})

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Apple;Ann;;;\r\nFN:Ann Apple\r\nRELATED;TYPE=friend:urn:uuid:cdv94-target\r\nitem1.EMAIL:ann@example.test\r\nitem1.X-ABLabel:_$!<Home>!$_\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)
    [relationship] = Contacts.list_relationships(contact.id)
    card = dav_get(contact, :v30)
    assert card =~ "item#{relationship.id}.X-ABRELATEDNAMES:"
    assert card =~ "item#{relationship.id}.X-ABLabel:_$!<Friend>!$_\r\n"

    # iOS rebuilds the card and renumbers every group item1..N
    renumbered =
      card
      |> String.replace("item1.", "item2.")
      |> String.replace("item#{relationship.id}.", "item1.")

    contact = dav_put(contact, aid, renumbered)
    again = dav_get(contact, :v30)
    assert length(Regex.scan(~r/X-ABRELATEDNAMES/, again)) == 1
    assert length(Regex.scan(~r/_\$!<Friend>!\$_/, again)) == 1
    assert again =~ "item2.X-ABLabel:_$!<Home>!$_\r\n"

    {:ok, _} = Contacts.delete_relationship(relationship)

    for version <- [:v30, :v40] do
      card = dav_get(contact, version)
      refute card =~ "X-ABRELATEDNAMES"
      refute card =~ "Friend"
      assert card =~ "item2.X-ABLabel:_$!<Home>!$_\r\n"
    end
  end

  test "CDV-96: a PUT keeps retained data its vCard version cannot express", %{
    contact: contact,
    account_id: aid
  } do
    v40 =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Cross;Cy;;;\r\nFN:Cy Cross\r\nKIND:individual\r\nANNIVERSARY:20100601\r\nEMAIL;PID=1.1;TYPE=work:cy@example.test\r\nCLIENTPIDMAP:1;urn:uuid:abc\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, v40)
    three = dav_get(contact, :v30)
    [_, group] = Regex.run(~r/^(item\d+)\.X-ABDATE:2010-06-01\r\n/m, three)
    assert three =~ "#{group}.X-ABLabel:_$!<Anniversary>!$_\r\n"
    refute three =~ ~r/KIND|ANNIVERSARY|CLIENTPIDMAP|PID=/

    # An iPhone's unchanged 3.0 PUT-back keeps what 3.0 cannot express
    contact = dav_put(contact, aid, three)
    four = dav_get(contact, :v40)

    for line <- [
          "KIND:individual",
          "ANNIVERSARY:20100601",
          "EMAIL;PID=1.1;TYPE=work:cy@example.test",
          "CLIENTPIDMAP:1;urn:uuid:abc"
        ],
        do: assert(four =~ line <> "\r\n")

    refute four =~ "X-ABDATE"
    assert dav_get(contact, :v30) == three

    # Apple can edit and delete the anniversary through X-ABDATE
    contact =
      dav_put(contact, aid, String.replace(three, "X-ABDATE:2010-06-01", "X-ABDATE:2011-07-02"))

    assert dav_get(contact, :v40) =~ "ANNIVERSARY:20110702\r\n"
    refute dav_get(contact, :v40) =~ "20100601"

    contact =
      dav_put(contact, aid, String.replace(dav_get(contact, :v30), ~r/^#{group}\..*\r\n/m, ""))

    refute dav_get(contact, :v40) =~ "ANNIVERSARY"
    assert dav_get(contact, :v40) =~ "KIND:individual\r\n"

    # A 4.0 PUT may delete 4.0 data
    contact =
      dav_put(contact, aid, String.replace(dav_get(contact, :v40), "KIND:individual\r\n", ""))

    refute dav_get(contact, :v40) =~ "KIND"

    # Symmetric: a 4.0 PUT keeps 3.0-only data
    v30 =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Three;Tia;;;\r\nFN:Tia Three\r\nAGENT:BEGIN:VCARD\\nFN:Agent\\nEND:VCARD\r\nMAILER:PigeonMail\r\nX-CUSTOM;CHARSET=utf-8:opaque\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, v30)
    three = dav_get(contact, :v30)
    contact = dav_put(contact, aid, dav_get(contact, :v40))
    assert dav_get(contact, :v30) == three
  end

  test "CDV-99: RELATED urn:uuid:<x> resolves a contact whose UID is the bare <x>, and back", %{
    contact: contact,
    account_id: aid
  } do
    bare = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(bare, %{dav_uid: "6f1c0a52-3c9e-4f7a-9b1d-2a5e8c7d0b99"})
    urn = contact_fixture(aid)

    {:ok, _} =
      Contacts.put_dav_identity(urn, %{dav_uid: "urn:uuid:0c2d4e6f-8a9b-4c1d-8e2f-3a4b5c6d7e8f"})

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Owner;Olga;;;\r\nFN:Olga Owner\r\n" <>
        "RELATED;TYPE=friend:urn:uuid:6f1c0a52-3c9e-4f7a-9b1d-2a5e8c7d0b99\r\n" <>
        "RELATED;TYPE=sibling;VALUE=text:0c2d4e6f-8a9b-4c1d-8e2f-3a4b5c6d7e8f\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)

    related =
      contact.id
      |> Contacts.list_relationships()
      |> Enum.map(& &1.related_contact_id)
      |> Enum.sort()

    assert related == Enum.sort([bare.id, urn.id])

    for version <- [:v30, :v40] do
      contact = dav_put(contact, aid, dav_get(contact, version))
      assert length(Contacts.list_relationships(contact.id)) == 2
    end
  end

  test "CDV-102: RELATED matches the urn:uuid prefix and UUID hex case-insensitively", %{
    contact: contact,
    account_id: aid
  } do
    upper = contact_fixture(aid)

    {:ok, _} =
      Contacts.put_dav_identity(upper, %{dav_uid: "urn:uuid:1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D"})

    lower = contact_fixture(aid)

    {:ok, _} =
      Contacts.put_dav_identity(lower, %{dav_uid: "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f"})

    text = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(text, %{dav_uid: "Kith-Text-Uid"})

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Case;Cy;;;\r\nFN:Cy Case\r\n" <>
        "RELATED;TYPE=friend:URN:UUID:1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d\r\n" <>
        "RELATED;TYPE=sibling:urn:uuid:9F8E7D6C-5B4A-4C3D-8E2F-1A0B9C8D7E6F\r\n" <>
        "RELATED;TYPE=parent:URN:UUID:kith-text-uid\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)

    related =
      contact.id
      |> Contacts.list_relationships()
      |> Enum.map(& &1.related_contact_id)
      |> Enum.sort()

    # a text UID keeps its exact value: only the URN scheme is case-insensitive
    assert related == Enum.sort([upper.id, lower.id])
  end

  test "CDV-110: RELATED resolves a non-ASCII text UID and a mixed-case UUID", %{
    contact: contact,
    account_id: aid
  } do
    # Postgres lower('İSTANBUL') and String.downcase('İSTANBUL') disagree, so the
    # case fold must happen in SQL on both sides.
    istanbul = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(istanbul, %{dav_uid: "İSTANBUL-uid"})
    sigma = contact_fixture(aid)
    {:ok, _} = Contacts.put_dav_identity(sigma, %{dav_uid: "ΟΔΥΣΣΕΥΣ-uid"})
    mixed = contact_fixture(aid)

    {:ok, _} =
      Contacts.put_dav_identity(mixed, %{dav_uid: "urn:uuid:AbCdEf01-2345-4678-89aB-cDeF01234567"})

    body =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nN:Fold;Fay;;;\r\nFN:Fay Fold\r\n" <>
        "RELATED;TYPE=friend;VALUE=text:İSTANBUL-uid\r\n" <>
        "RELATED;TYPE=sibling;VALUE=text:ΟΔΥΣΣΕΥΣ-uid\r\n" <>
        "RELATED;TYPE=parent:urn:uuid:abcdef01-2345-4678-89ab-cdef01234567\r\nEND:VCARD\r\n"

    contact = dav_put(contact, aid, body)

    related =
      contact.id
      |> Contacts.list_relationships()
      |> Enum.map(& &1.related_contact_id)
      |> Enum.sort()

    assert related == Enum.sort([istanbul.id, sigma.id, mixed.id])
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

  # R4 / Review Focus 4: every write of a DAV-visible child, whatever path made
  # it (LiveView components, REST API, imports, raw SQL), must move the parent
  # contact's ETag revision and its commit-ordered sync position.
  describe "CDV-97: child writes outside DAV change the ETag and sync (R4)" do
    defp dav_revision(contact_id) do
      Kith.Repo.one!(from c in "contacts", where: c.id == ^contact_id, select: c.dav_revision)
    end

    defp phone_type do
      Kith.Repo.one!(from t in Contacts.ContactFieldType, where: t.protocol == "tel:", limit: 1)
    end

    defp assert_dav_bump(contact, label, fun) do
      %{seq: seq} = Contacts.dav_sync_state(contact.account_id)
      before = dav_revision(contact.id)
      result = fun.()

      assert dav_revision(contact.id) != before, "#{label}: ETag revision unchanged"

      changed =
        contact.account_id |> Contacts.list_contacts_changed_since(seq) |> Enum.map(& &1.id)

      assert contact.id in changed, "#{label}: not reported by incremental sync"
      result
    end

    test "CDV-97: contact field create, update and delete", %{contact: contact} do
      phone = phone_type()

      {:ok, field} =
        assert_dav_bump(contact, "create", fn ->
          Contacts.create_contact_field(contact, %{
            contact_field_type_id: phone.id,
            value: "+15550100001"
          })
        end)

      {:ok, field} =
        assert_dav_bump(contact, "update", fn ->
          Contacts.update_contact_field(field, %{value: "+15550100002"})
        end)

      assert_dav_bump(contact, "delete", fn -> Contacts.delete_contact_field(field) end)
    end

    test "CDV-97: address create, update and delete", %{contact: contact} do
      {:ok, address} =
        assert_dav_bump(contact, "create", fn ->
          Contacts.create_address(contact, %{line1: "1 Main St", city: "Springfield"})
        end)

      {:ok, address} =
        assert_dav_bump(contact, "update", fn ->
          Contacts.update_address(address, %{line1: "2 Main St"})
        end)

      assert_dav_bump(contact, "delete", fn -> Contacts.delete_address(address) end)
    end

    test "CDV-97: tag and untag", %{contact: contact, account_id: aid} do
      {:ok, tag} = Contacts.create_tag(aid, %{"name" => "CDV-97 tag"})
      assert_dav_bump(contact, "tag", fn -> Contacts.tag_contact(contact, tag) end)
      assert_dav_bump(contact, "untag", fn -> Contacts.untag_contact(contact, tag) end)
    end

    test "CDV-97: relationship create and delete, and a hard delete of its target",
         %{contact: contact, account_id: aid} do
      [type | _] = Contacts.list_relationship_types(aid)
      other = contact_fixture(aid, %{first_name: "Target"})

      {:ok, rel} =
        assert_dav_bump(contact, "create", fn ->
          Contacts.create_relationship(contact, %{
            related_contact_id: other.id,
            relationship_type_id: type.id
          })
        end)

      assert_dav_bump(contact, "delete", fn -> Contacts.delete_relationship(rel) end)

      {:ok, _} =
        Contacts.create_relationship(contact, %{
          related_contact_id: other.id,
          relationship_type_id: type.id
        })

      assert_dav_bump(contact, "target purge", fn -> Contacts.hard_delete_contact(other) end)
    end

    test "CDV-97: avatar set and clear", %{contact: contact} do
      photo = photo_fixture(contact)

      {:ok, contact} =
        assert_dav_bump(contact, "set", fn -> Contacts.set_avatar(contact, photo) end)

      assert_dav_bump(contact, "clear", fn -> Contacts.clear_avatar(contact) end)
    end

    test "CDV-97: a merge reparent moves both the loser's and the survivor's ETag",
         %{contact: survivor, account_id: aid} do
      loser = contact_fixture(aid)

      {:ok, _} =
        Contacts.create_contact_field(loser, %{
          contact_field_type_id: phone_type().id,
          value: "+15550100009"
        })

      {:ok, _} = Contacts.create_address(loser, %{line1: "9 Loser Lane"})
      %{seq: seq} = Contacts.dav_sync_state(aid)
      before = {dav_revision(survivor.id), dav_revision(loser.id)}

      # The statement `Kith.Contacts.Merge.remap_excluding/5` runs for each child schema
      for schema <- [Contacts.ContactField, Contacts.Address] do
        from(r in schema, where: r.contact_id in ^[loser.id])
        |> Kith.Repo.update_all(set: [contact_id: survivor.id])
      end

      {survivor_before, loser_before} = before
      assert dav_revision(survivor.id) != survivor_before
      assert dav_revision(loser.id) != loser_before

      changed = aid |> Contacts.list_contacts_changed_since(seq) |> Enum.map(& &1.id)
      assert survivor.id in changed
      assert loser.id in changed
    end

    test "CDV-97: a raw SQL child write cannot bypass the bump", %{contact: contact} do
      phone = phone_type()

      assert_dav_bump(contact, "raw insert", fn ->
        Kith.Repo.query!(
          "INSERT INTO contact_fields (contact_id, account_id, contact_field_type_id, value, inserted_at, updated_at) VALUES ($1, $2, $3, '+15550100003', now(), now())",
          [contact.id, contact.account_id, phone.id]
        )
      end)
    end
  end

  describe "CDV-98: renaming a record a card shows by name changes the card's ETag and sync" do
    test "CDV-98: tag rename", %{contact: contact, account_id: aid} do
      {:ok, tag} = Contacts.create_tag(aid, %{"name" => "Before"})
      Contacts.tag_contact(contact, tag)
      quiet = contact_fixture(aid)

      assert_dav_bump(contact, "tag rename", fn ->
        {:ok, _} = Contacts.update_tag(tag, %{"name" => "After"})
      end)

      # A change the card does not show (the colour) and untagged contacts stay quiet.
      %{seq: seq} = Contacts.dav_sync_state(aid)

      {:ok, _} =
        Contacts.update_tag(Kith.Repo.get!(Contacts.Tag, tag.id), %{"color" => "#000000"})

      assert [] == Contacts.list_contacts_changed_since(aid, seq)

      {:ok, _} = Contacts.update_tag(Kith.Repo.get!(Contacts.Tag, tag.id), %{"name" => "Again"})
      changed = aid |> Contacts.list_contacts_changed_since(seq) |> Enum.map(& &1.id)
      assert contact.id in changed
      refute quiet.id in changed
    end

    test "CDV-98: gender rename", %{contact: contact, account_id: aid} do
      {:ok, gender} = Contacts.create_gender(aid, %{name: "Custom"})
      {:ok, contact} = Contacts.update_contact(contact, %{gender_id: gender.id})

      assert_dav_bump(contact, "gender rename", fn ->
        {:ok, _} = Contacts.update_gender(gender, %{name: "Renamed"})
      end)
    end

    test "CDV-98: contact field type protocol and vCard label changes",
         %{contact: contact, account_id: aid} do
      {:ok, type} = Contacts.create_contact_field_type(aid, %{name: "Pager"})

      {:ok, _} =
        Contacts.create_contact_field(contact, %{contact_field_type_id: type.id, value: "12345"})

      type =
        assert_dav_bump(contact, "protocol", fn ->
          {:ok, type} = Contacts.update_contact_field_type(type, %{protocol: "tel"})
          type
        end)

      assert_dav_bump(contact, "vcard_label", fn ->
        {:ok, _} = Contacts.update_contact_field_type(type, %{vcard_label: "X-PAGER"})
      end)
    end

    test "CDV-98: relationship type rename", %{contact: contact, account_id: aid} do
      {:ok, type} =
        Contacts.create_relationship_type(aid, %{name: "Mentor", reverse_name: "Mentee"})

      other = contact_fixture(aid)

      {:ok, _} =
        Contacts.create_relationship(contact, %{
          related_contact_id: other.id,
          relationship_type_id: type.id
        })

      assert_dav_bump(contact, "relationship type rename", fn ->
        {:ok, _} = Contacts.update_relationship_type(type, %{name: "Spouse"})
      end)
    end
  end

  describe "CDV-100: a change to a relationship's target changes the owner's card" do
    test "CDV-100: renaming the target, or changing its UID, bumps the owner",
         %{contact: owner, account_id: aid} do
      [type | _] = Contacts.list_relationship_types(aid)
      target = contact_fixture(aid, %{first_name: "Tess", last_name: "Target"})
      bystander = contact_fixture(aid)

      {:ok, _} =
        Contacts.create_relationship(owner, %{
          related_contact_id: target.id,
          relationship_type_id: type.id
        })

      # the target relates back, so a rename must not ping-pong between them
      {:ok, _} =
        Contacts.create_relationship(target, %{
          related_contact_id: owner.id,
          relationship_type_id: type.id
        })

      %{seq: seq} = Contacts.dav_sync_state(aid)

      target =
        assert_dav_bump(owner, "rename", fn ->
          {:ok, target} = Contacts.update_contact(target, %{first_name: "Tamsin"})
          target
        end)

      changed = aid |> Contacts.list_contacts_changed_since(seq) |> Enum.map(& &1.id)
      refute bystander.id in changed

      assert_dav_bump(owner, "uid", fn ->
        {:ok, _} = Contacts.put_dav_identity(target, %{dav_uid: "urn:uuid:cdv100-target"})
      end)

      # A write that changes nothing the owner shows leaves the owner alone.
      %{seq: seq} = Contacts.dav_sync_state(aid)

      {:ok, _} =
        Contacts.update_contact(Kith.Repo.get!(Contacts.Contact, target.id), %{favorite: true})

      refute owner.id in Enum.map(Contacts.list_contacts_changed_since(aid, seq), & &1.id)
    end
  end
end
