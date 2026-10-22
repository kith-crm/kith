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

  describe "import/4" do
    setup do
      user = Kith.AccountsFixtures.user_fixture()
      %{account_id: user.account_id, user_id: user.id}
    end

    defp import_one(account_id, user_id, bday_line) do
      data =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Yearless;Ann;;;\r\nFN:Ann Yearless\r\n" <>
          bday_line <> "\r\nEND:VCARD\r\n"

      assert {:ok, %{contacts: 1}} = VCardSource.import(account_id, user_id, data, [])

      Kith.Contacts.Contact
      |> Kith.Repo.get_by!(account_id: account_id, last_name: "Yearless")
      |> Kith.Repo.preload([
        :addresses,
        :gender,
        :tags,
        contact_fields: :contact_field_type,
        relationships: [:relationship_type, :related_contact]
      ])
    end

    test "CDV-117: a card that is not UTF-8 is reported and the rest of the file imports",
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

    test "CDV-114: a year-less BDAY and Kith's X-KITH-BDAY import as year-unknown birthdays",
         %{account_id: account_id, user_id: user_id} do
      for line <- ["BDAY:--0615", "X-KITH-BDAY:--0615"] do
        contact = import_one(account_id, user_id, line)

        assert contact.birthdate_year_unknown, "#{line}: imported with a made-up birth year"
        assert {contact.birthdate.month, contact.birthdate.day} == {6, 15}

        # No age and no year anywhere the birthday is shown: the REST API and
        # both vCard versions give only month and day, and the import creates
        # no reminder (whose anchor would carry the placeholder year).
        assert KithWeb.API.ContactJSON.data(contact).birthdate == "--06-15"
        assert Kith.VCard.Serializer.serialize(contact, version: :v40) =~ "\r\nBDAY:--0615\r\n"
        refute Kith.VCard.Serializer.serialize(contact, version: :v40) =~ "2000"
        assert Kith.Reminders.get_birthday_reminder(contact.id, account_id) == nil

        Kith.Repo.delete!(contact)
      end
    end
  end
end
