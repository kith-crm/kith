defmodule Kith.DAV.DocumentTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts
  alias Kith.Contacts.{ContactField, ContactFieldType}
  alias Kith.DAV.{AddressObject, ContactDav, Document, Store, VCardAdapter}
  alias Kith.VCard.Document, as: VCardDocument

  setup do
    account = user_fixture().account_id

    contact =
      contact_fixture(account, %{
        first_name: "Jane",
        last_name: "Doe",
        description: "private description"
      })

    Store.ensure_rows(account)
    %{contact: load(contact), account: account}
  end

  test "conflicting client-only source indexes reject document acceptance atomically", %{
    contact: contact,
    account: account
  } do
    before = Repo.get!(ContactDav, contact.id)

    for version <- ["3.0", "4.0"] do
      raw =
        card([
          "FN:Changed",
          "NOTE;PID=1.1:client-only identity",
          "CLIENTPIDMAP:1;https://example.org/one",
          "CLIENTPIDMAP:1;https://example.org/two"
        ])
        |> String.replace("VERSION:4.0", "VERSION:" <> version)

      assert {:error, :ambiguous_property_identity} =
               Store.transaction(account, fn ->
                 assert {:ok, changed} =
                          Contacts.update_contact(contact, %{first_name: "Changed"})

                 Document.accept(load(changed), raw)
               end)

      assert Repo.get!(Kith.Contacts.Contact, contact.id).first_name == contact.first_name
      assert Repo.get!(ContactDav, contact.id) == before
    end
  end

  test "client occurrence identities survive source renumbering and conversion round trips", %{
    contact: contact
  } do
    for version <- ["3.0", "4.0"] do
      raw =
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "NOTE;PID=1.1:first note",
          "NOTE;PID=2.1:second note",
          "CLIENTPIDMAP:1;HTTPS://EXAMPLE.COM/%7eUser"
        ])
        |> String.replace("VERSION:4.0", "VERSION:" <> version)

      accepted = Document.accept(contact, raw)
      with_document = put_document(contact, accepted)

      renamed =
        raw
        |> String.replace("PID=1.1:first note", "PID=2.7:second note")
        |> String.replace("PID=2.1:second note", "PID=1.7:changed note")
        |> String.replace(
          "CLIENTPIDMAP:1;HTTPS://EXAMPLE.COM/%7eUser",
          "CLIENTPIDMAP:7;https://example.com/~User"
        )

      rebound = Document.accept(with_document, renamed)

      notes = fn document ->
        document["properties"]
        |> Enum.filter(&(&1["property"]["normalized_name"] == "NOTE"))
      end

      [first, second] = notes.(accepted)
      [second_after, first_after] = notes.(rebound)
      assert second_after["id"] == second["id"]
      assert first_after["id"] == first["id"]

      converted =
        with_document
        |> put_document(rebound)
        |> Document.render(version: if(version == "3.0", do: :v40, else: :v30))

      round_trip = with_document |> put_document(rebound) |> Document.accept(converted)
      assert Enum.map(notes.(round_trip), & &1["id"]) == [second["id"], first["id"]]
    end
  end

  test "DAV decoding cannot map NOTE, gender, IMPP or social extensions into native fields" do
    raw =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "NOTE:client note",
        "GENDER:F",
        "IMPP:xmpp:client@example.org",
        "X-SOCIALPROFILE:https://private.example"
      ])

    assert {attrs, nested} = VCardAdapter.vcard_to_attrs(raw, strip_nils: false)
    refute Map.has_key?(attrs, "description")
    refute Map.has_key?(attrs, "gender_id")
    assert nested.urls == []
    refute Map.has_key?(nested, :impp)
    assert nested.dav_document == raw
  end

  test "trusted native fields appear while custom protocol/label impostors do not", %{
    contact: contact,
    account: account
  } do
    trusted = trusted_type()

    custom =
      Repo.insert!(%ContactFieldType{
        account_id: account,
        name: "Email clone",
        protocol: "mailto",
        vcard_label: "EMAIL"
      })

    insert_field(contact, trusted.id, "shared@example.org")
    insert_field(contact, custom.id, "private@example.org")
    rendered = contact |> load() |> Document.render()
    assert rendered =~ "shared@example.org"
    refute rendered =~ "private@example.org"
    refute rendered =~ "private description"
  end

  test "trusted built-in phone subtype labels are projected without changing native metadata", %{
    contact: contact
  } do
    for {key, expected} <- [{"mobile", "CELL"}, {"work_phone", "WORK"}, {"fax", "FAX"}] do
      type =
        Repo.one!(
          from(t in ContactFieldType, where: is_nil(t.account_id) and t.system_key == ^key)
        )

      native = insert_field(contact, type.id, "+12025550" <> Integer.to_string(type.id))
      native |> Ecto.Changeset.change(label: nil) |> Repo.update!()
      rendered = contact |> load() |> Document.render(version: :v40)
      assert rendered =~ "TEL;TYPE=#{expected}:#{native.value}"
      assert Repo.get!(ContactField, native.id).label == nil
    end
  end

  test "client-only values and grouped mapped parameters survive native edits", %{
    contact: contact
  } do
    field = insert_field(contact, trusted_type().id, "shared@example.org")
    contact = load(contact)

    raw =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;Dr.;Jr.",
        "item1.EMAIL;TYPE=home;X-CUSTOM=\"a:b;c\":shared@example.org",
        "item1.X-ABLabel:Client label",
        "NOTE:client note",
        "GENDER:F",
        "X-UNKNOWN;X-P=one;X-P=two:value"
      ])

    accepted = Document.accept(contact, raw)
    contact = put_document(contact, accepted)
    first = Document.render(contact, version: :v40)
    assert first =~ "NOTE:client note"
    assert first =~ "GENDER:F"
    assert first =~ "N:Doe;Jane;;Dr.;Jr."
    assert first =~ "item1.EMAIL;TYPE=home;X-CUSTOM=\"a:b;c\":shared@example.org"
    assert {:ok, _} = Repo.update(Ecto.Changeset.change(field, value: "updated@example.org"))
    updated = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert updated =~ "item1.EMAIL;TYPE=home;X-CUSTOM=\"a:b;c\":updated@example.org"
    assert updated =~ "NOTE:client note"
    assert updated =~ "item1.X-ABLabel:Client label"
  end

  test "unchanged document preserves multiplicity and binding identities", %{contact: contact} do
    type = trusted_type()
    one = insert_field(contact, type.id, "same@example.org")
    two = insert_field(contact, type.id, "same@example.org")
    contact = load(contact)

    raw =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "EMAIL;PID=1.1:same@example.org",
        "EMAIL;PID=2.1:same@example.org",
        "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111"
      ])

    accepted = Document.accept(contact, raw)

    bindings =
      accepted["properties"]
      |> Enum.filter(&(&1["property"]["normalized_name"] == "EMAIL"))
      |> Enum.map(& &1["binding"])

    assert Enum.sort(bindings) == Enum.sort(["field:#{one.id}:EMAIL", "field:#{two.id}:EMAIL"])
    assert rendered = contact |> put_document(accepted) |> Document.render(version: :v40)
    assert {:ok, doc} = VCardDocument.parse(rendered)
    assert length(VCardDocument.properties(doc, "EMAIL")) == 2
    assert rendered =~ "PID=1.1"
    assert rendered =~ "PID=2.1"
  end

  test "capture and fingerprints are independent of private edits and storage availability", %{
    contact: contact
  } do
    unavailable = %{contact | avatar: "private/missing-key"}
    captured = Document.capture(unavailable)
    assert fingerprint = unavailable |> put_document(captured) |> Document.fingerprint()

    changed = %{
      unavailable
      | description: "different private description",
        aliases: ["secret"],
        updated_at: DateTime.utc_now()
    }

    assert changed
           |> put_document(Document.capture(put_document(changed, captured)))
           |> Document.fingerprint() == fingerprint

    assert_raise Kith.DAV.RepresentationError, fn ->
      unavailable |> put_document(captured) |> Document.render()
    end
  end

  test "cross-version parameters retain caret literals and impossible v3 encodings fail explicitly",
       %{contact: contact} do
    v3 =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Doe\r\nN:Doe;Jane;;;\r\nX-UNKNOWN;X-LITERAL=a^nb:value\r\nEND:VCARD\r\n"

    accepted = Document.accept(contact, v3)
    converted = contact |> put_document(accepted) |> Document.render(version: :v40)
    assert converted =~ "X-LITERAL=a^^nb"
    assert {:ok, doc} = VCardDocument.parse(converted)
    assert hd(hd(VCardDocument.properties(doc, "X-UNKNOWN")).parameters).values == ["a^nb"]

    impossible =
      Document.accept(
        contact,
        card(["FN:Jane Doe", "N:Doe;Jane;;;", "X-UNKNOWN;X-LABEL=a^'b:value"])
      )

    assert_raise Kith.DAV.ConversionError, fn ->
      contact |> put_document(impossible) |> Document.render(version: :v30)
    end
  end

  test "unchanged GET/PUT retains internal document occurrence IDs", %{contact: contact} do
    raw =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "NOTE;PID=1.1:client note",
        "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111"
      ])

    accepted = Document.accept(contact, raw)
    contact = put_document(contact, accepted)
    rendered = Document.render(contact, version: :v40)
    repeated = Document.accept(contact, rendered)

    assert Enum.map(accepted["properties"], & &1["id"]) ==
             Enum.map(repeated["properties"], & &1["id"])
  end

  test "legacy selected originals are never served before processed-asset backfill", %{
    contact: contact
  } do
    key = Kith.Storage.generate_key(contact.account_id, "photos", "legacy-original.jpg")
    binary = Image.new!(24, 24, color: :red) |> Image.write!(:memory, suffix: ".jpg")
    assert {:ok, _} = Kith.Storage.upload_binary(binary, key)
    on_exit(fn -> Kith.Storage.delete(key) end)
    legacy = %{contact | avatar: key}
    captured = Document.capture(legacy)
    assert is_map(captured)

    assert_raise Kith.DAV.RepresentationError, fn ->
      Document.render(put_document(legacy, captured))
    end
  end

  test "v4 relationship converts to v3 companions and back without changing revision", %{
    contact: contact
  } do
    target = contact_fixture(contact.account_id, %{first_name: "Related", last_name: "Person"})

    type =
      Repo.one!(
        from(t in Kith.Contacts.RelationshipType,
          where: is_nil(t.account_id) and t.system_key == "friend"
        )
      )

    native = relationship_fixture(contact, target, type.id)
    contact = load(contact)
    v4 = Document.render(contact, version: :v40)
    put_card(contact, v4)
    before = Repo.get!(ContactDav, contact.id)
    v3 = contact |> load() |> Document.render(version: :v30) |> String.replace("\r\n ", "")
    assert v3 =~ "X-KITH-RELATED;TYPE=friend:"
    assert v3 =~ "X-ABRELATEDNAMES:Related Person"
    assert v3 =~ "X-ABLabel:_$!<Friend>!$_"
    put_card(contact, v3)
    assert Repo.get!(ContactDav, contact.id).revision == before.revision
    assert Repo.get!(Kith.Contacts.Relationship, native.id).relationship_type_id == type.id
    refute contact |> load() |> Document.render(version: :v40) =~ "X-ABRELATEDNAMES:"
  end

  defp put_card(contact, raw) do
    dav = Repo.get!(ContactDav, contact.id)
    conn = Plug.Test.conn(:put, "/dav/addressbooks/default/" <> dav.resource_name, raw)
    conn = Plug.Conn.assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    assert %{status: 204} = AddressObject.put(conn, dav.resource_name, raw)
  end

  test "repeated scalar properties retain client alternatives while native owns its primary", %{
    contact: contact
  } do
    contact = %{contact | occupation: "Primary title"}

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "TITLE;LANGUAGE=fr:Alternative title",
          "TITLE;LANGUAGE=en:Primary title"
        ])
      )

    rendered = contact |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "TITLE;LANGUAGE=fr:Alternative title"
    assert rendered =~ "TITLE;LANGUAGE=en:Primary title"
    edited = %{contact | occupation: "Changed primary"}
    rendered = edited |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "TITLE;LANGUAGE=fr:Alternative title"
    assert rendered =~ "TITLE;LANGUAGE=en:Changed primary"
  end

  test "hidden native relationships keep dormant metadata across PUT and restore", %{
    contact: contact
  } do
    target = contact_fixture(contact.account_id, %{first_name: "Dormant", last_name: "Person"})

    type =
      Repo.one!(
        from(t in Kith.Contacts.RelationshipType,
          where: is_nil(t.account_id) and t.system_key == "friend"
        )
      )

    native = relationship_fixture(contact, target, type.id)
    target = load(target)
    uri = Kith.DAV.UID.urn(target.dav.uid)

    put_card(
      contact,
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "clientgroup.RELATED;TYPE=friend;X-CLIENT=retained:" <> uri
      ])
    )

    {:ok, _} = Contacts.archive_contact(target)
    hidden = contact |> load() |> Document.render(version: :v40)
    refute hidden =~ uri
    refute hidden =~ "Dormant Person"
    refute hidden =~ "clientgroup"
    put_card(contact, hidden)
    assert Repo.get!(Kith.Contacts.Relationship, native.id)
    {:ok, _} = Contacts.unarchive_contact(Repo.reload!(target))
    restored = contact |> load() |> Document.render(version: :v40) |> String.replace("\r\n ", "")
    assert restored =~ "clientgroup.RELATED;TYPE=friend;X-CLIENT=retained:" <> uri
  end

  test "malformed cross-account child and tag associations never enter the shared view", %{
    contact: contact
  } do
    foreign = user_fixture().account_id
    type = trusted_type()

    Repo.insert!(%ContactField{
      account_id: foreign,
      contact_id: contact.id,
      contact_field_type_id: type.id,
      value: "foreign-secret@example.org"
    })

    Repo.insert!(%Kith.Contacts.Address{
      account_id: foreign,
      contact_id: contact.id,
      line1: "Foreign secret street"
    })

    tag = Repo.insert!(%Kith.Contacts.Tag{account_id: foreign, name: "Foreign secret tag"})
    Repo.insert_all("contact_tags", [%{contact_id: contact.id, tag_id: tag.id}])
    rendered = contact |> load() |> Document.render(version: :v40)
    refute rendered =~ "foreign-secret@example.org"
    refute rendered =~ "Foreign secret street"
    refute rendered =~ "Foreign secret tag"
  end

  test "native label changes retain unowned TYPE tokens and grouped client parameters", %{
    contact: contact
  } do
    field = insert_field(contact, trusted_type().id, "shared@example.org")
    contact = load(contact)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "item1.EMAIL;TYPE=home,internet;TYPE=voice;X-CLIENT=retained:shared@example.org",
          "item1.X-ABLabel:Client label"
        ])
      )

    field |> Ecto.Changeset.change(label: "work") |> Repo.update!()
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert {:ok, parsed} = VCardDocument.parse(rendered)
    [email] = VCardDocument.properties(parsed, "EMAIL")

    types =
      email.parameters
      |> Enum.filter(&(&1.normalized_name == "TYPE"))
      |> Enum.flat_map(& &1.values)
      |> Enum.map(&String.downcase/1)

    assert Enum.sort(types) == ["internet", "voice", "work"]
    assert email.group == "item1"
    assert rendered =~ "X-CLIENT=retained"
    assert rendered =~ "item1.X-ABLabel:Client label"
  end

  test "deleting a grouped shared owner removes its companions without touching other groups", %{
    contact: contact
  } do
    email = insert_field(contact, trusted_type().id, "shared@example.org")
    phone_type = Kith.DAV.FieldRegistry.canonical_type!(:phones)
    phone = insert_field(contact, phone_type.id, "+12025550123")
    contact = load(contact)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "item1.TEL;TYPE=home:+12025550123",
          "item1.X-ABLabel:Mobile label",
          "item1.X-CLIENT:independent same group",
          "item2.EMAIL;TYPE=home:shared@example.org",
          "item2.X-ABLabel:Home label",
          "client.X-UNKNOWN:independent"
        ])
      )

    Repo.delete!(phone)
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    refute rendered =~ "Mobile label"
    assert rendered =~ "Home label"
    assert rendered =~ "item1.X-CLIENT:independent same group"
    assert rendered =~ "client.X-UNKNOWN:independent"
    assert Repo.get!(ContactField, email.id)
  end

  test "a grouped companion survives until its last shared owner is removed", %{contact: contact} do
    one = insert_field(contact, trusted_type().id, "one@example.org")
    two = insert_field(contact, trusted_type().id, "two@example.org")
    contact = load(contact)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "item1.EMAIL:one@example.org",
          "item1.EMAIL:two@example.org",
          "item1.X-ABLabel:Shared group label"
        ])
      )

    Repo.delete!(one)
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "Shared group label"
    Repo.delete!(two)
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    refute rendered =~ "Shared group label"
  end

  test "PID bindings stay attached when changed values collide and properties reorder", %{
    contact: contact
  } do
    type = trusted_type()
    one = insert_field(contact, type.id, "one@example.org")
    two = insert_field(contact, type.id, "two@example.org")
    contact = load(contact)
    source = "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111"

    prior =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "EMAIL;PID=1.1:one@example.org",
          "EMAIL;PID=2.1:two@example.org",
          source
        ])
      )

    one |> Ecto.Changeset.change(value: "two@example.org") |> Repo.update!()
    contact = contact |> load() |> put_document(prior)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "EMAIL;PID=2.1:two@example.org",
          "EMAIL;PID=1.1:two@example.org",
          source
        ])
      )

    bindings =
      accepted["properties"]
      |> Enum.filter(&(&1["property"]["normalized_name"] == "EMAIL"))
      |> Enum.map(& &1["binding"])

    assert bindings == ["field:#{two.id}:EMAIL", "field:#{one.id}:EMAIL"]

    Repo.get!(ContactField, one.id)
    |> Ecto.Changeset.change(value: "changed@example.org")
    |> Repo.update!()

    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "EMAIL;PID=1.1:changed@example.org"
    assert rendered =~ "EMAIL;PID=2.1:two@example.org"
  end

  test "repeated CATEGORIES own membership subsets and native edits cannot resurrect tags", %{
    contact: contact
  } do
    input =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "item1.CATEGORIES;LANGUAGE=en:Alpha,Beta",
        "item2.CATEGORIES;X-CLIENT=retained:Beta,Gamma"
      ])

    put_card(contact, input)
    contact = load(contact)
    assert Enum.sort(Enum.map(contact.tags, & &1.name)) == ["Alpha", "Beta", "Gamma"]
    before = Repo.get!(ContactDav, contact.id).revision

    for version <- [:v30, :v40] do
      rendered = contact |> load() |> Document.render(version: version)
      put_card(contact, rendered)
    end

    assert Repo.get!(ContactDav, contact.id).revision == before
    beta = Enum.find(contact.tags, &(&1.name == "Beta"))
    gamma = Enum.find(contact.tags, &(&1.name == "Gamma"))
    {:ok, renamed} = Contacts.rename_tag(beta, "Renamed")
    renamed_card = contact |> load() |> Document.render(version: :v40)
    assert renamed_card =~ "item1.CATEGORIES;LANGUAGE=en:Alpha,Renamed"
    assert renamed_card =~ "item2.CATEGORIES;X-CLIENT=retained:Renamed,Gamma"
    Contacts.untag_contact(contact, gamma)
    Contacts.untag_contact(contact, renamed)
    removed = contact |> load() |> Document.render(version: :v40)
    assert removed =~ "item1.CATEGORIES;LANGUAGE=en:Alpha"
    refute removed =~ "item2.CATEGORIES"
    put_card(contact, removed)
    assert contact |> load() |> Map.get(:tags) |> Enum.map(& &1.name) == ["Alpha"]
  end

  test "repeated category decoding preserves escaped commas and all occurrences" do
    {_attrs, nested} =
      VCardAdapter.vcard_to_attrs(
        card(["FN:Jane Doe", "CATEGORIES:Alpha,Team\\,Close", "CATEGORIES:Beta,Alpha"])
      )

    assert nested.categories == ["Alpha", "Team,Close", "Beta"]
  end

  test "clearing a native scalar removes mapped alternatives before an unchanged roundtrip", %{
    contact: contact
  } do
    put_card(
      contact,
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "TITLE;LANGUAGE=fr:Alternative",
        "TITLE;LANGUAGE=en:Primary"
      ])
    )

    assert Repo.reload!(contact).occupation == "Primary"
    {:ok, _} = Contacts.update_contact(contact, %{occupation: nil})
    rendered = contact |> load() |> Document.render(version: :v40)
    refute rendered =~ "TITLE"
    put_card(contact, rendered)
    assert Repo.reload!(contact).occupation == nil
  end

  test "compact persistence roundtrips client syntax bindings and unknown internal entry metadata",
       %{contact: contact} do
    field = insert_field(contact, trusted_type().id, "shared@example.org")
    contact = load(contact)

    document =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "item1.EMAIL;TYPE=home,internet;X-P=\"a:b;c\":shared@example.org",
          "item1.X-ABLabel:Client label",
          "NOTE;X-P=one;X-P=two:Client note"
        ])
      )

    [first | rest] = document["properties"]

    document = %{
      document
      | "properties" => [Map.put(first, "future_metadata", %{"opaque" => [1, 2, 3]}) | rest]
    }

    packed = Document.pack(document)
    assert packed["schema_version"] == 2
    assert is_list(hd(packed["properties"]))
    assert Document.unpack(packed) == document
    assert byte_size(Jason.encode!(packed)) < byte_size(Jason.encode!(document))
    assert field.id

    assert Document.render(put_document(contact, packed), version: :v40) ==
             Document.render(put_document(contact, document), version: :v40)
  end

  test "compatible TYPE subsets bind reordered equal values before value-only fallback", %{
    contact: contact
  } do
    type = trusted_type()
    home = insert_field(contact, type.id, "same@example.org")
    work = insert_field(contact, type.id, "same@example.org")
    work |> Ecto.Changeset.change(label: "work") |> Repo.update!()
    contact = load(contact)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "work.EMAIL;TYPE=\"work,voice\";X-MARK=work:same@example.org",
          "home.EMAIL;TYPE=home,internet;X-MARK=home:same@example.org"
        ])
      )

    home |> Ecto.Changeset.change(value: "changed@example.org") |> Repo.update!()
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "home.EMAIL;TYPE=home,internet;X-MARK=home:changed@example.org"
    assert rendered =~ "work.EMAIL;TYPE=\"work,voice\";X-MARK=work:same@example.org"
  end

  test "untyped duplicate values prefer the untyped native row before a typed sibling", %{
    contact: contact
  } do
    type = trusted_type()
    home = insert_field(contact, type.id, "same@example.org")
    generic = insert_field(contact, type.id, "same@example.org")
    generic |> Ecto.Changeset.change(label: nil) |> Repo.update!()
    contact = load(contact)

    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "EMAIL;X-MARK=generic:same@example.org",
          "EMAIL;TYPE=home;X-MARK=home:same@example.org"
        ])
      )

    home |> Ecto.Changeset.change(value: "changed@example.org") |> Repo.update!()
    rendered = contact |> load() |> put_document(accepted) |> Document.render(version: :v40)
    assert rendered =~ "EMAIL;X-MARK=generic:same@example.org"
    assert rendered =~ "EMAIL;TYPE=home;X-MARK=home:changed@example.org"
  end

  test "TEL URI scheme casing roundtrips without duplication and native edits keep URI syntax", %{
    contact: contact
  } do
    for scheme <- ["tel:", "TEL:"] do
      put_card(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "TEL;VALUE=uri;X-CLIENT=retained:" <> scheme <> "+12025550123"
        ])
      )

      [field] = Contacts.list_contact_fields(contact.id)
      rendered = contact |> load() |> Document.render(version: :v40)
      put_card(contact, rendered)
      assert [same] = Contacts.list_contact_fields(contact.id)
      assert same.id == field.id
      assert {:ok, _} = Contacts.update_contact_field(same, %{value: "+12025550124"})
      edited = contact |> load() |> Document.render(version: :v40)
      assert edited =~ "TEL;VALUE=uri;X-CLIENT=retained:tel:+12025550124"
    end
  end

  test "unresolved URI references publish visibility changes without creating native edges", %{
    contact: contact
  } do
    uid = Ecto.UUID.generate()
    uri = Kith.DAV.UID.urn(uid)
    put_card(contact, card(["FN:Jane Doe", "N:Doe;Jane;;;", "RELATED;TYPE=friend:" <> uri]))
    path = uid <> ".vcf"

    body = card(["UID:" <> uri, "FN:Target", "N:;Target;;;"])

    conn = Plug.Test.conn(:put, "/dav/addressbooks/default/" <> path, body)
    conn = Plug.Conn.assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    assert %{status: 201} = AddressObject.put(conn, path, body)
    target = Store.get_by_uid(contact.account_id, uid)
    before = Repo.get!(ContactDav, contact.id)
    assert Contacts.list_relationships(contact.id) == []
    assert contact |> load() |> Document.render(version: :v40) =~ uri
    {:ok, _} = Contacts.archive_contact(target)
    refute contact |> load() |> Document.render(version: :v40) =~ uri
    assert Repo.get!(ContactDav, contact.id).revision > before.revision
    {:ok, _} = Contacts.unarchive_contact(Repo.reload!(target))
    assert contact |> load() |> Document.render(version: :v40) =~ uri
    assert Contacts.list_relationships(contact.id) == []
  end

  test "related UUID URI aliases bind once while UUID-looking text stays client-only", %{
    contact: contact
  } do
    target = contact_fixture(contact.account_id, %{first_name: "Target"})
    target = load(target)
    uri = Kith.DAV.UID.urn(target.dav.uid)

    input =
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "RELATED;VALUE=text;TYPE=friend:" <> uri,
        "RELATED;TYPE=friend:" <> String.upcase(uri)
      ])

    put_card(contact, input)
    rendered = contact |> load() |> Document.render(version: :v40)
    assert {:ok, parsed} = VCardDocument.parse(rendered)
    related = VCardDocument.properties(parsed, "RELATED")
    assert length(related) == 2

    uri_property =
      Enum.find(related, fn property ->
        not Enum.any?(
          property.parameters,
          &(&1.normalized_name == "VALUE" and &1.values == ["text"])
        )
      end)

    assert uri_property.value == uri
    refute rendered =~ String.upcase(uri)
    assert length(Contacts.list_relationships(contact.id)) == 1
    {:ok, _} = Contacts.archive_contact(target)
    hidden = contact |> load() |> Document.render(version: :v40) |> String.replace("\r\n ", "")
    assert hidden =~ "RELATED;VALUE=text;TYPE=friend:" <> uri
    refute hidden =~ String.upcase(uri)
  end

  test "bare related UUIDs emit one canonical native URI while keeping client parameters", %{
    contact: contact
  } do
    target = contact_fixture(contact.account_id) |> load()

    put_card(
      contact,
      card([
        "FN:Jane Doe",
        "N:Doe;Jane;;;",
        "RELATED;TYPE=friend;X-CLIENT=retained:" <> target.dav.uid
      ])
    )

    rendered = contact |> load() |> Document.render(version: :v40)
    assert {:ok, document} = VCardDocument.parse(rendered)
    assert [property] = VCardDocument.properties(document, "RELATED")
    assert property.value == Kith.DAV.UID.urn(target.dav.uid)

    assert Enum.any?(
             property.parameters,
             &(&1.normalized_name == "X-CLIENT" and &1.values == ["retained"])
           )

    assert length(Contacts.list_relationships(contact.id)) == 1
  end

  test "native TEL URI extension edits unescape structural text and unsafe values remain escaped TEXT",
       %{contact: contact} do
    put_card(
      contact,
      card(["FN:Jane Doe", "N:Doe;Jane;;;", "TEL;VALUE=uri;X-CLIENT=retained:tel:+12025550123"])
    )

    [field] = Contacts.list_contact_fields(contact.id)
    field |> Ecto.Changeset.change(value: "+12025550123;ext=456") |> Repo.update!()
    rendered = contact |> load() |> Document.render(version: :v40)
    assert rendered =~ "TEL;VALUE=uri;X-CLIENT=retained:tel:+12025550123;ext=456"
    refute rendered =~ "tel:+12025550123\\;ext"

    Repo.get!(ContactField, field.id)
    |> Ecto.Changeset.change(value: "not a phone\nUID:client text")
    |> Repo.update!()

    rendered = contact |> load() |> Document.render(version: :v40)
    assert {:ok, document} = VCardDocument.parse(rendered)
    assert [phone] = VCardDocument.properties(document, "TEL")
    assert Enum.any?(phone.parameters, &(&1.normalized_name == "VALUE" and &1.values == ["text"]))
    assert phone.value == "not a phone\\nUID:client text"
    assert length(VCardDocument.properties(document, "UID")) == 1
  end

  test "both-view fingerprints follow native EMAIL TEL and ADR changes across source versions", %{
    contact: contact
  } do
    for source <- ["3.0", "4.0"] do
      raw =
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "item1.eMaIl;TYPE=home;X-P=\"a:b;c\":shared@example.org",
          "item2.TEL;VALUE=uri;TYPE=work:tel:+12025550123",
          "item3.ADR;TYPE=work;X-P=kept:Box;Floor;Before Street;City;Region;123;Country"
        ])
        |> String.replace("VERSION:4.0", "VERSION:" <> source)

      put_card(contact, raw)
      current = load(contact)
      before = Document.fingerprint(current)
      pair_before = wire_pair(current)

      email =
        Enum.find(
          current.contact_fields,
          &(Kith.DAV.FieldRegistry.kind(&1.contact_field_type) == :emails)
        )

      phone =
        Enum.find(
          current.contact_fields,
          &(Kith.DAV.FieldRegistry.kind(&1.contact_field_type) == :phones)
        )

      assert {:ok, _} = Contacts.update_contact_field(email, %{value: "changed@example.org"})
      assert {:ok, _} = Contacts.update_contact_field(phone, %{value: "+12025550124"})
      assert {:ok, _} = Contacts.update_address(hd(current.addresses), %{line1: "After Street"})
      edited = load(contact)
      pair_after = wire_pair(edited)
      refute pair_after == pair_before
      refute Document.fingerprint(edited) == before

      assert Enum.all?(
               Tuple.to_list(pair_after),
               &(&1 =~ "changed@example.org" and &1 =~ "After Street")
             )

      assert {:ok, _} =
               Contacts.update_contact(contact, %{description: "private sentinel", favorite: true})

      private_edit = load(contact)
      assert Document.fingerprint(private_edit) == Document.fingerprint(edited)
      assert wire_pair(private_edit) == pair_after
    end
  end

  defp wire_pair(contact) do
    [v3, v4] =
      Enum.map([:v30, :v40], fn version ->
        contact
        |> Document.render(version: version)
        |> String.replace("\r\n ", "")
        |> then(&Regex.replace(~r/^REV:[^\r\n]*/m, &1, "REV:__KITH_REV__"))
      end)

    {v3, v4}
  end

  test "remote PHOTO remains client-only and no network request is needed", %{contact: contact} do
    accepted =
      Document.accept(
        contact,
        card([
          "FN:Jane Doe",
          "N:Doe;Jane;;;",
          "PHOTO;VALUE=uri:https://example.invalid/avatar.jpg"
        ])
      )

    assert contact |> put_document(accepted) |> Document.render(version: :v40) =~
             "https://example.invalid/avatar.jpg"
  end

  defp load(contact), do: Repo.preload(contact, Contacts.dav_preloads(), force: true)

  defp put_document(contact, document),
    do: %{contact | dav: Map.put(contact.dav, :document, document)}

  defp trusted_type do
    Repo.one(from(t in ContactFieldType, where: is_nil(t.account_id) and t.system_key == "email")) ||
      Repo.insert!(%ContactFieldType{
        name: "Email",
        protocol: "mailto:",
        vcard_label: "EMAIL",
        system_key: "email"
      })
  end

  defp insert_field(contact, type, value),
    do:
      Repo.insert!(%ContactField{
        account_id: contact.account_id,
        contact_id: contact.id,
        contact_field_type_id: type,
        value: value,
        label: "home"
      })

  defp card(lines),
    do: Enum.join(["BEGIN:VCARD", "VERSION:4.0" | lines] ++ ["END:VCARD", ""], "\r\n")
end
