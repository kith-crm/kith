defmodule Kith.VCard.ExtrasTest do
  use ExUnit.Case, async: true
  alias Kith.VCard.{Extras, Serializer}

  test "keeps X-CUSTOM and IMPP-less unknown properties verbatim, in order" do
    assert Extras.extract("BEGIN:VCARD\r\nX-CUSTOM;P=1:one\r\n two\r\nFOO:bar\r\nEND:VCARD") == [
             "X-CUSTOM;P=1:onetwo",
             "FOO:bar"
           ]
  end

  test "drops grouped properties" do
    assert Extras.extract("item1.X-CUSTOM:value\nitem2.X-ABLabel:Home") == []
  end

  test "drops mapped properties" do
    assert Extras.extract(
             "FN:Name\nEMAIL;TYPE=HOME:e@example.test\nIMPP:x\nPRODID:Kith\nX-SOCIALPROFILE:url"
           ) == []
  end

  test "serializer emits extras before END:VCARD for both versions" do
    for version <- [:v30, :v40] do
      assert Serializer.serialize(contact(), version: version, include_uid: true) =~
               "X-CUSTOM:one\r\nEND:VCARD\r\n"
    end
  end

  test "RELATED emits the canonical UUID URN" do
    uid = "b2000000-0000-4000-8000-000000000002"

    rel = %{
      id: 1,
      related_contact_id: 2,
      relationship_type: %{name: "Friend"},
      related_contact: %{dav: %{uid: uid}}
    }

    for version <- [:v30, :v40] do
      assert Serializer.serialize(Map.put(contact(), :relationships, [rel]), version: version) =~
               ";TYPE=friend:urn:uuid:#{uid}"
    end
  end

  defp contact do
    %{
      first_name: "A",
      last_name: nil,
      nickname: nil,
      birthdate: nil,
      company: nil,
      occupation: nil,
      description: nil,
      dav: %{uid: "b2000000-0000-4000-8000-000000000002", extras: ["X-CUSTOM:one"]}
    }
  end

  test "stored UUID is emitted as a URN and missing identity never derives from contact id" do
    for version <- [:v30, :v40] do
      card = Serializer.serialize(contact(), version: version, include_uid: true)
      assert card =~ "UID:urn:uuid:b2000000-0000-4000-8000-000000000002\r\n"
      refute Serializer.serialize(contact(), version: version, include_uid: false) =~ "UID"

      refute Serializer.serialize(Map.put(Map.delete(contact(), :dav), :id, 42),
               version: version,
               include_uid: true
             ) =~ "UID"
    end
  end

  test "yearless birthdays roundtrip in both versions" do
    for version <- [:v30, :v40] do
      card =
        contact()
        |> Map.merge(%{birthdate: ~D[2000-02-29], birthdate_year_unknown: true})
        |> Serializer.serialize(version: version)

      assert {:ok, [parsed]} = Kith.VCard.Parser.parse(card)
      assert parsed.birthdate == ~D[2000-02-29]
      assert parsed.birthdate_year_unknown
    end
  end
end
