defmodule Kith.Imports.Sources.VCardTest do
  use Kith.DataCase, async: true

  import Ecto.Query

  alias Kith.Imports.Sources.VCard, as: VCardSource

  describe "name/0" do
    test "returns source name" do
      assert VCardSource.name() == "vCard"
    end
  end

  describe "file_types/0" do
    test "returns accepted file types" do
      assert VCardSource.file_types() == [".vcf"]
    end
  end

  describe "supports_api?/0" do
    test "returns false" do
      refute VCardSource.supports_api?()
    end
  end

  describe "validate_file/1" do
    test "validates a proper vCard file" do
      data = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Doe\r\nEND:VCARD\r\n"
      assert {:ok, _} = VCardSource.validate_file(data)
    end

    test "rejects invalid data" do
      assert {:error, _} = VCardSource.validate_file("not a vcard")
    end
  end

  describe "parse_summary/1" do
    test "returns contact count" do
      data =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:3.0\r\nN:Smith;John;;;\r\nFN:John Smith\r\nEND:VCARD\r\n"

      assert {:ok, %{contacts: 2}} = VCardSource.parse_summary(data)
    end
  end

  describe "import hardening" do
    setup do
      user = Kith.AccountsFixtures.user_fixture()
      %{account_id: user.account_id, user_id: user.id}
    end

    test "a 256-character first name is a changeset error, not a Postgres error", %{
      account_id: id
    } do
      assert {:error, %Ecto.Changeset{}} =
               Kith.Contacts.create_contact(id, %{first_name: String.duplicate("a", 256)})
    end

    test "blank fields are skipped and invalid fields roll back the contact", %{
      account_id: id,
      user_id: user_id
    } do
      %Kith.Contacts.ContactFieldType{}
      |> Ecto.Changeset.change(%{name: "Email", protocol: "mailto:", account_id: id})
      |> Kith.Repo.insert!()

      card = fn email ->
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:;Imported;;;\r\nFN:Imported\r\nEMAIL:" <>
          email <> "\r\nEND:VCARD\r\n"
      end

      assert {:ok, %{contacts: 1}} = VCardSource.import(id, user_id, card.(""), [])
      assert Kith.Repo.aggregate(Kith.Contacts.ContactField, :count) == 0

      assert {:ok, %{contacts: 0, error_count: 1}} =
               VCardSource.import(id, user_id, card.(String.duplicate("a", 256)), [])

      assert Kith.Contacts.count_contacts(id) == 1
    end

    test "varchar limits count Unicode codepoints", %{account_id: id} do
      assert {:ok, _} =
               Kith.Contacts.create_contact(id, %{first_name: String.duplicate("é", 255)})

      assert {:error, %Ecto.Changeset{}} =
               Kith.Contacts.create_contact(id, %{first_name: String.duplicate("é", 128)})

      for module <- [Kith.Contacts.Address, Kith.Contacts.ContactField] do
        attrs =
          if module == Kith.Contacts.Address,
            do: %{city: String.duplicate("a", 256)},
            else: %{value: String.duplicate("a", 256)}

        refute module.changeset(struct(module), attrs).valid?
      end
    end

    test "one non-UTF-8 card does not reject the rest of the import",
         %{account_id: account_id, user_id: user_id} do
      card = fn name ->
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};Enc;;;\r\nFN:Enc #{name}\r\nEND:VCARD\r\n"
      end

      # The middle card is Latin-1 ("Zoë" with a bare 0xEB byte).
      data = card.("Zoë") <> card.(<<"Zo", 0xEB>>) <> card.("Ünal")

      assert {:ok, %{contacts: 3}} = VCardSource.parse_summary(data)

      assert {:ok, %{contacts: 2, error_count: 1, errors: [error]}} =
               VCardSource.import(account_id, user_id, data, [])

      assert error =~ "Contact 2"
      assert error =~ "UTF-8"

      names =
        Kith.Contacts.Contact
        |> where([c], c.account_id == ^account_id)
        |> select([c], c.last_name)
        |> Kith.Repo.all()

      assert Enum.sort(names) == ["Zoë", "Ünal"]
    end

    test "a year-less BDAY imports as year unknown", %{account_id: id, user_id: user_id} do
      data =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Yearless;Ann;;;\r\nFN:Ann Yearless\r\nBDAY:--0615\r\nEND:VCARD\r\n"

      assert {:ok, %{contacts: 1}} = VCardSource.import(id, user_id, data, [])
      contact = Kith.Repo.get_by!(Kith.Contacts.Contact, account_id: id)
      assert contact.birthdate_year_unknown
      assert contact.birthdate == ~D[2000-06-15]
    end
  end
end
