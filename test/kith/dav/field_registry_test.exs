defmodule Kith.DAV.FieldRegistryTest do
  # The missing-destination case deletes a trusted global row inside its
  # sandbox transaction; run serially to avoid blocking other FK readers.
  use Kith.DataCase, async: false
  import Kith.AccountsFixtures
  alias Kith.Contacts.{ContactFieldType, RelationshipType}
  alias Kith.DAV.FieldRegistry

  test "only audited global keys classify shared kinds" do
    for {key, expected} <- [
          {"email", :emails},
          {"phone", :phones},
          {"mobile", :phones},
          {"work_phone", :phones},
          {"fax", :phones},
          {"website", :urls}
        ] do
      assert FieldRegistry.kind(%ContactFieldType{account_id: nil, system_key: key}) == expected
      assert FieldRegistry.kind(%ContactFieldType{account_id: 1, system_key: key}) == nil
    end

    assert FieldRegistry.kind(%ContactFieldType{
             name: "Email",
             protocol: "mailto:",
             vcard_label: "EMAIL"
           }) == nil

    assert FieldRegistry.kind(%ContactFieldType{system_key: "twitter", protocol: "https://"}) ==
             nil

    assert FieldRegistry.kind(%ContactFieldType{system_key: "arbitrary"}) == nil
    assert FieldRegistry.kind(nil) == nil
  end

  test "ordinary contact-field and relationship changesets cannot assign trusted keys" do
    account_id = user_fixture().account_id

    changeset =
      ContactFieldType.changeset(%ContactFieldType{}, %{
        name: "Email",
        account_id: account_id,
        protocol: "mailto",
        system_key: "email"
      })

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :system_key)

    changeset =
      RelationshipType.changeset(%RelationshipType{}, %{
        name: "Spouse",
        reverse_name: "Spouse",
        account_id: account_id,
        system_key: "spouse"
      })

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :system_key)

    trusted = %ContactFieldType{system_key: "email", name: "Email"}

    assert ContactFieldType.changeset(trusted, %{system_key: "website"})
           |> Ecto.Changeset.get_field(:system_key) == "email"
  end

  test "canonical destinations are deterministic trusted globals" do
    for {kind, key} <- [emails: "email", phones: "phone", urls: "website"] do
      assert {:ok, type} = FieldRegistry.canonical_type(kind)
      assert type.account_id == nil
      assert type.system_key == key
      assert FieldRegistry.canonical_type!(kind).id == type.id
    end

    assert FieldRegistry.canonical_type(:impp) == {:error, :missing_shared_field_type}
  end

  test "missing trusted destination fails explicitly instead of choosing a protocol match" do
    canonical = FieldRegistry.canonical_type!(:emails)
    Repo.delete!(canonical)
    Repo.insert!(%ContactFieldType{name: "Untrusted Email", protocol: "mailto:", position: -999})
    assert FieldRegistry.canonical_type(:emails) == {:error, :missing_shared_field_type}

    assert_raise RuntimeError, ~r/Missing trusted DAV/, fn ->
      FieldRegistry.canonical_type!(:emails)
    end
  end

  test "database rejects classifying account-created contact-field types" do
    account_id = user_fixture().account_id

    assert_raise Postgrex.Error, ~r/contact_field_types_system_key_global/, fn ->
      Repo.query!(
        "INSERT INTO contact_field_types (account_id, system_key, name, position, inserted_at, updated_at) VALUES ($1, 'forged', 'Forged', 0, now(), now())",
        [account_id]
      )
    end
  end

  test "database rejects classifying account-created relationship types" do
    account_id = user_fixture().account_id

    assert_raise Postgrex.Error, ~r/relationship_types_system_key_global/, fn ->
      Repo.query!(
        "INSERT INTO relationship_types (account_id, system_key, name, reverse_name, position, is_bidirectional, inserted_at, updated_at) VALUES ($1, 'forged', 'Forged', 'Forged', 0, true, now(), now())",
        [account_id]
      )
    end
  end

  test "database enforces unique trusted keys" do
    assert_raise Postgrex.Error, ~r/contact_field_types_system_key_index/, fn ->
      Repo.query!(
        "INSERT INTO contact_field_types (system_key, name, position, inserted_at, updated_at) VALUES ('email', 'Duplicate trusted email', 0, now(), now())"
      )
    end
  end
end
