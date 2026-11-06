defmodule Kith.Contacts.ContactTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts.Contact

  test "native contacts still require a nonblank given or family name" do
    for attrs <- [%{}, %{first_name: " ", last_name: " "}] do
      changeset = Contact.create_changeset(%Contact{}, Map.put(attrs, :account_id, 1))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :first_name)
    end

    assert Contact.update_changeset(%Contact{first_name: "", last_name: "Doe"}, %{favorite: true}).valid?

    contact = %Contact{first_name: "Jane", last_name: "Doe"}
    changeset = Contact.update_changeset(contact, %{first_name: nil, last_name: nil})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :first_name)
  end

  describe "schema" do
    test "has first-met and middle_name fields" do
      fields = Contact.__schema__(:fields)
      assert :middle_name in fields
      assert :first_met_at in fields
      assert :first_met_year_unknown in fields
      assert :first_met_where in fields
      assert :first_met_through_id in fields
      assert :first_met_additional_info in fields
      assert :birthdate_year_unknown in fields
    end

    test "has first_met_through association" do
      assocs = Contact.__schema__(:associations)
      assert :first_met_through in assocs
    end
  end

  describe "create_changeset/2" do
    test "casts all first-met fields and middle_name" do
      attrs = %{
        first_name: "Jane",
        account_id: 1,
        middle_name: "Marie",
        first_met_at: ~D[2020-06-15],
        first_met_year_unknown: true,
        first_met_where: "College",
        first_met_through_id: 42,
        first_met_additional_info: "Met at orientation",
        birthdate_year_unknown: false
      }

      changeset = Contact.create_changeset(%Contact{}, attrs)
      assert changeset.changes[:middle_name] == "Marie"
      assert changeset.changes[:first_met_at] == ~D[2020-06-15]
      assert changeset.changes[:first_met_year_unknown] == true
      assert changeset.changes[:first_met_where] == "College"
      assert changeset.changes[:first_met_through_id] == 42
      assert changeset.changes[:first_met_additional_info] == "Met at orientation"
    end

    test "all first-met fields are optional" do
      changeset = Contact.create_changeset(%Contact{}, %{first_name: "Jane", account_id: 1})
      assert changeset.valid?
    end
  end

  describe "compute_display_name/1 (via create_changeset)" do
    test "includes middle name between first and last" do
      changeset =
        Contact.create_changeset(%Contact{}, %{
          first_name: "Jane",
          middle_name: "Marie",
          last_name: "Doe",
          account_id: 1
        })

      assert Ecto.Changeset.get_field(changeset, :display_name) == "Jane Marie Doe"
    end

    test "works with middle name but no last name" do
      changeset =
        Contact.create_changeset(%Contact{}, %{
          first_name: "Jane",
          middle_name: "Marie",
          account_id: 1
        })

      assert Ecto.Changeset.get_field(changeset, :display_name) == "Jane Marie"
    end

    test "works without middle name (backwards compatible)" do
      changeset =
        Contact.create_changeset(%Contact{}, %{
          first_name: "Jane",
          last_name: "Doe",
          account_id: 1
        })

      assert Ecto.Changeset.get_field(changeset, :display_name) == "Jane Doe"
    end

    test "skips nil and empty middle name" do
      changeset =
        Contact.create_changeset(%Contact{}, %{
          first_name: "Jane",
          middle_name: "",
          last_name: "Doe",
          account_id: 1
        })

      assert Ecto.Changeset.get_field(changeset, :display_name) == "Jane Doe"
    end
  end
end
