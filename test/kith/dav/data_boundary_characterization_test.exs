defmodule Kith.DAV.DataBoundaryCharacterizationTest do
  @moduledoc """
  Boundary regressions derived from the original implementation defects.

  These tests now assert the shared/private/client-only contract, including
  unchanged round trips that previously accumulated duplicate native fields.
  """
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts
  alias Kith.DAV.{AddressObject, ContactDav, FieldRegistry, Store, VCardAdapter}

  setup do
    account_id = user_fixture().account_id
    %{account_id: account_id, contact: contact_fixture(account_id)}
  end

  for version <- [:v30, :v40] do
    test "#{version}: custom EMAIL-labelled fields stay private across unchanged round trips",
         ctx do
      version = unquote(version)

      {:ok, custom_type} =
        Contacts.create_contact_field_type(ctx.account_id, %{
          name: "Private custom email",
          protocol: nil,
          vcard_label: "EMAIL"
        })

      original =
        contact_field_fixture(ctx.contact, custom_type.id, %{
          "value" => "private-custom@example.com"
        })

      initial_dav = Repo.get!(ContactDav, ctx.contact.id)

      for _cycle <- 1..4 do
        body =
          VCardAdapter.contact_to_vcard(Repo.reload!(ctx.contact),
            version: version,
            include_photo: false
          )

        refute body =~ original.value
        put_card(ctx.contact, body)
        assert [retained] = fields(ctx.contact)
        assert retained.id == original.id
        assert retained.contact_field_type_id == custom_type.id
        assert retained.value == original.value
      end

      assert Repo.get!(ContactDav, ctx.contact.id).revision == initial_dav.revision
    end

    test "#{version}: unchanged shared fields keep native row and subtype IDs", ctx do
      type =
        Repo.one!(
          from(t in Kith.Contacts.ContactFieldType,
            where: is_nil(t.account_id) and t.system_key == "mobile"
          )
        )

      field =
        contact_field_fixture(ctx.contact, type.id, %{
          "value" => "+12025550123",
          "label" => "Mobile"
        })

      initial_dav = Repo.get!(ContactDav, ctx.contact.id)

      for _cycle <- 1..4 do
        body =
          VCardAdapter.contact_to_vcard(Repo.reload!(ctx.contact),
            version: unquote(version),
            include_photo: false
          )

        put_card(ctx.contact, body)
        assert [retained] = fields(ctx.contact)
        assert retained.id == field.id
        assert retained.contact_field_type_id == type.id
        assert retained.label == field.label
      end

      assert Repo.get!(ContactDav, ctx.contact.id).revision == initial_dav.revision
    end
  end

  test "incoming EMAIL selects trusted canonical destination despite a lower-position private type",
       ctx do
    canonical = FieldRegistry.canonical_type!(:emails)

    {:ok, custom_type} =
      Contacts.create_contact_field_type(ctx.account_id, %{
        name: "Private protocol-matching destination",
        protocol: "mailto",
        position: -1_000_000
      })

    put_card(ctx.contact, card(["EMAIL:client@example.com"]))
    assert [field] = fields(ctx.contact)
    assert field.value == "client@example.com"
    assert field.contact_field_type_id == canonical.id
    refute field.contact_field_type_id == custom_type.id
  end

  test "client NOTE and GENDER remain independent of private native description and gender",
       ctx do
    {:ok, private_gender} =
      Contacts.create_gender(ctx.account_id, %{name: "Private gender sentinel"})

    {:ok, _client_gender} =
      Contacts.create_gender(ctx.account_id, %{name: "Client gender sentinel"})

    {:ok, contact} =
      Contacts.update_contact(ctx.contact, %{
        description: "Private description sentinel",
        gender_id: private_gender.id
      })

    input = card(["NOTE:Client note sentinel", "GENDER:O;Client gender sentinel"])

    {attrs, _children} =
      VCardAdapter.vcard_to_attrs(input, account_id: ctx.account_id, strip_nils: false)

    refute Map.has_key?(attrs, "description")
    refute Map.has_key?(attrs, "gender_id")
    put_card(contact, input)

    native = Repo.reload!(contact)
    assert native.description == "Private description sentinel"
    assert native.gender_id == private_gender.id
    body = VCardAdapter.contact_to_vcard(native, version: :v40, include_photo: false)
    assert body =~ "NOTE:Client note sentinel"
    assert body =~ "GENDER:O;Client gender sentinel"
    refute body =~ "Private description sentinel"
    refute body =~ "Private gender sentinel"

    # A later replacement removes DAV-only values while preserving native ones.
    put_card(native, card([]))
    native = Repo.reload!(native)
    assert native.description == "Private description sentinel"
    assert native.gender_id == private_gender.id
    body = VCardAdapter.contact_to_vcard(native, version: :v40, include_photo: false)
    refute body =~ "NOTE:"
    refute body =~ "GENDER:"
  end

  test "private edits preserve DAV bytes, revision and representation timestamps", ctx do
    {:ok, contact} =
      Contacts.update_contact(ctx.contact, %{description: "Private description before"})

    before_card = VCardAdapter.contact_to_vcard(contact, include_photo: false)
    before_dav = Repo.get!(ContactDav, contact.id)
    refute before_card =~ "Private description before"

    assert {:ok, updated} =
             Contacts.update_contact(contact, %{
               description: "Private description after",
               favorite: true,
               aliases: ["Private alias sentinel"]
             })

    assert updated.favorite
    assert updated.description == "Private description after"
    assert VCardAdapter.contact_to_vcard(updated, include_photo: false) == before_card
    after_dav = Repo.get!(ContactDav, contact.id)
    assert after_dav.revision == before_dav.revision
    assert after_dav.representation_modified_at == before_dav.representation_modified_at
    assert after_dav.document == before_dav.document
    assert after_dav.representation_fingerprint == before_dav.representation_fingerprint
  end

  test "mapped metadata and grouped client properties survive repeated full PUTs", ctx do
    mapped = "EMAIL;TYPE=work,voice;PREF=1;X-CLIENT=retained:client@example.com"
    grouped = "item1.X-CLIENT-NOTE;LANGUAGE=en:Grouped client metadata"
    ungrouped = "X-CLIENT-NOTE;LANGUAGE=en:Ungrouped client metadata"
    put_card(ctx.contact, card([mapped, grouped, ungrouped]))
    assert [original] = fields(ctx.contact)

    for _cycle <- 1..4 do
      body =
        VCardAdapter.contact_to_vcard(Repo.reload!(ctx.contact),
          version: :v40,
          include_photo: false
        )

      assert body =~ mapped
      assert body =~ grouped
      assert body =~ ungrouped
      put_card(ctx.contact, body)
      assert [retained] = fields(ctx.contact)
      assert retained.id == original.id
    end
  end

  defp put_card(contact, body) do
    Store.ensure_rows(contact.account_id)
    dav = Repo.get!(ContactDav, contact.id)
    conn = Plug.Test.conn(:put, "/dav/addressbooks/default/" <> dav.resource_name, body)
    conn = Plug.Conn.assign(conn, :current_scope, %{account: %{id: contact.account_id}})
    assert %{status: 204} = AddressObject.put(conn, dav.resource_name, body)
  end

  defp fields(contact), do: Contacts.list_contact_fields(contact.id)

  defp card(properties) do
    Enum.join(["BEGIN:VCARD", "VERSION:4.0", "FN:Jane Doe", "N:Doe;Jane;;;" | properties], "\r\n") <>
      "\r\nEND:VCARD\r\n"
  end
end
