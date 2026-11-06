defmodule Kith.VCard.DocumentTest do
  use ExUnit.Case, async: true

  alias Kith.VCard.Document

  for {version, source_version} <- [{"3.0", :v30}, {"4.0", :v40}] do
    test "retains ordered content lines and source syntax in #{version}" do
      source =
        card(unquote(version), [
          "FN:Jane Doe",
          "N:Doe;Jane;J.;Dr.;Jr.",
          "item1.EMAIL;TYPE=home;TYPE=internet;X-Custom=\"a:b;c,d\":jane@example.com",
          "item1.X-ABLabel:Personal",
          "EMAIL;TYPE=work:jane@example.com",
          "ORG:Company;Division;Team",
          "ADR;TYPE=home:PO Box 12;Floor 2;Street;City;Region;123;Country",
          "X-UNKNOWN;X-P=one,two:raw\\;escaped\\,value",
          "X-UNKNOWN:second"
        ])

      assert {:ok, document} = Document.parse(source)
      assert document.source_version == unquote(source_version)
      assert length(document.properties) == 10
      assert [first, second] = Document.properties(document, "email")
      assert first.group == "item1"
      assert first.name == "EMAIL"
      assert first.value == "jane@example.com"
      assert Enum.map(first.parameters, & &1.normalized_name) == ["TYPE", "TYPE", "X-CUSTOM"]
      assert Enum.map(first.parameters, & &1.values) == [["home"], ["internet"], ["a:b;c,d"]]
      assert Enum.at(first.parameters, 2).raw == "X-Custom=\"a:b;c,d\""
      assert second.group == nil
      assert [_, _] = Document.properties(document, "X-UNKNOWN")
      assert {:ok, ^document} = document |> Document.serialize() |> Document.parse()
      assert unfold(Document.serialize(document)) == source
    end
  end

  test "preserves original spelling, empty values, quoted lists and parameter occurrences" do
    source =
      card("4.0", ["Fn:Name", "item-A.eMaIl;tYpE=\"work,voice\";TYPE=home,work;X-E=:x@y", "NOTE:"])

    assert {:ok, document} = Document.parse(source)
    assert [email] = Document.properties(document, "EMAIL")
    assert email.name == "eMaIl"
    assert Enum.map(email.parameters, & &1.values) == [["work,voice"], ["home", "work"], [""]]
    assert unfold(Document.serialize(document)) == source
  end

  test "decodes RFC 6868 parameter escapes in v4 while keeping raw syntax" do
    source = card("4.0", ["FN;X-LABEL=\"a^^b^nc^'d\":Name"])
    assert {:ok, document} = Document.parse(source)
    assert [property] = Document.properties(document, "FN")
    assert [parameter] = property.parameters
    assert parameter.values == ["a^b\nc\"d"]
    assert Document.serialize(document) == source
  end

  test "does not apply v4 parameter decoding to v3" do
    assert {:ok, document} = Document.parse(card("3.0", ["FN;X-LABEL=a^nb:Name"]))
    assert [property] = Document.properties(document, "FN")
    assert hd(property.parameters).values == ["a^nb"]
  end

  test "retains quotes in TEXT values without treating them as head syntax" do
    source = card("4.0", ["FN:Name", ~s(NOTE:He said "hello)])
    assert {:ok, document} = Document.parse(source)
    assert Document.serialize(document) == source
  end

  test "preserves PHOTO binary and URI syntax without interpreting or fetching it" do
    for {version, photo} <- [
          {"3.0", "PHOTO;ENCODING=b;TYPE=JPEG:/9j/AAAA"},
          {"4.0", "PHOTO;MEDIATYPE=image/jpeg:data:image/jpeg;base64,/9j/AAAA"},
          {"4.0", "PHOTO;VALUE=uri:https://example.com/photo.jpg"}
        ] do
      source = card(version, ["FN:Name", photo])
      assert {:ok, document} = Document.parse(source)
      assert unfold(Document.serialize(document)) == source
    end
  end

  test "keeps VERSION and UID validation separate from contact semantic validation" do
    source = card("4.0", ["X-UNKNOWN:anything"])
    assert {:ok, document} = Document.parse(source)
    assert Document.serialize(document) == source
  end

  test "accepts trailing envelope whitespace without trimming property values" do
    source = "BEGIN:VCARD \t\r\nVERSION:4.0\r\nFN:Name \t\r\nEND:VCARD\t \r\n"
    assert {:ok, document} = Document.parse(source)
    assert hd(Document.properties(document, "FN")).value == "Name \t"
  end

  test "normalizes line endings and unfolds space and tab continuations" do
    source = "BEGIN:VCARD\nVERSION:3.0\nFN:Some\n Name\nNOTE:A\n\tB\nEND:VCARD\n"
    assert {:ok, document} = Document.parse(source)
    assert [name] = Document.properties(document, "FN")
    assert name.value == "SomeName"
    assert [note] = Document.properties(document, "NOTE")
    assert note.value == "AB"
    assert Document.serialize(document) == card("3.0", ["FN:SomeName", "NOTE:AB"])
  end

  test "restores a UTF-8 character split by a client fold before validating encoding" do
    source =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A" <>
        <<0xC3>> <> "\r\n " <> <<0xA9>> <> "\r\nEND:VCARD\r\n"

    assert {:ok, document} = Document.parse(source)
    assert hd(Document.properties(document, "FN")).value == "Aé"
  end

  test "folds long lines by octets without splitting UTF-8 and includes continuation space" do
    source = card("4.0", ["FN:" <> String.duplicate("é", 110)])
    assert {:ok, document} = Document.parse(source)
    rendered = Document.serialize(document)
    lines = String.split(rendered, "\r\n", trim: true)
    assert Enum.all?(lines, &(byte_size(&1) <= 75 and String.valid?(&1)))
    assert Enum.any?(lines, &String.starts_with?(&1, " "))
    assert unfold(rendered) == source
    assert {:ok, ^document} = Document.parse(rendered)
  end

  test "accepts a leading UTF-8 BOM without retaining it in emitted content" do
    source = card("4.0", ["FN:Name"])
    assert {:ok, document} = Document.parse("\uFEFF" <> source)
    assert Document.serialize(document) == source
  end

  test "does not silently convert a document by changing its source version" do
    assert {:ok, document} = Document.parse(card("3.0", ["FN:Name"]))

    assert_raise ArgumentError, ~r/VERSION must match/, fn ->
      Document.serialize(%{document | source_version: :v40})
    end
  end

  test "retains a v3 VERSION appearing after other properties" do
    source = "BEGIN:VCARD\r\nFN:Jane Doe\r\nN:Doe;Jane;;;\r\nVERSION:3.0\r\nEND:VCARD\r\n"
    assert {:ok, document} = Document.parse(source)
    assert document.source_version == :v30
    assert Document.serialize(document) == source
  end

  test "decoded property semantic mapping reuses the existing import contact codec" do
    for version <- ["3.0", "4.0"] do
      source =
        card(version, [
          "FN:Jane Doe",
          "N:Doe;Jane;Middle;Dr.;Jr.",
          "ORG:Company;Team",
          "TITLE:Engineer",
          "EMAIL;TYPE=home,voice:jane@example.org",
          "item1.ADR;TYPE=work:Box;Floor;Street;City;State;123;Country",
          "NOTE:Client\\nNote",
          "CATEGORIES:One,Two",
          "BDAY:--0714"
        ])

      assert {:ok, [expected]} = Kith.VCard.Parser.parse(source, legacy_bday: false)
      assert {:ok, document} = Document.parse(source)

      assert Kith.VCard.Parser.from_properties(document.properties, legacy_bday: false) ==
               expected
    end
  end

  test "rejects unsupported, missing, repeated or misplaced v4 versions" do
    for source <- [
          card("2.1", ["FN:Name"]),
          "BEGIN:VCARD\r\nFN:Name\r\nEND:VCARD\r\n",
          card("4.0", ["VERSION:3.0"]),
          "BEGIN:VCARD\r\nFN:Name\r\nVERSION:4.0\r\nEND:VCARD\r\n",
          "BEGIN:VCARD\r\nVERSION;X-P=1:4.0\r\nEND:VCARD\r\n",
          card("4.0", ["item1.VERSION:4.0"])
        ] do
      assert {:error, _} = Document.parse(source)
    end
  end

  test "rejects multiple cards and nested or malformed envelopes without discarding lines" do
    for source <- [
          "",
          "BEGIN:VCARD",
          card("4.0", []) <> card("3.0", []),
          card("4.0", ["BEGIN:VCARD"]),
          card("4.0", ["END:VCARD"]),
          card("4.0", ["item1.BEGIN:VCARD"]),
          "ignored\r\n" <> card("4.0", []),
          card("4.0", []) <> "ignored"
        ] do
      assert {:error, _} = Document.parse(source)
    end
  end

  test "rejects malformed content lines and quotes instead of parser fallback" do
    for line <- [
          "FN",
          "",
          ".FN:Name",
          "group.part.FN:Name",
          "F N:Name",
          "FN;X-P=\"unterminated:Name",
          "FN;X-P=un\"balanced:Name",
          "FN;X-P=ab\"cd\":Name",
          "FN;X-P=\"a\"tail:Name",
          "FN;TYPE:Name",
          "FN;=value:Name"
        ] do
      assert {:error, _} = Document.parse(card("4.0", [line]))
    end
  end

  test "rejects invalid UTF-8 and control bytes" do
    assert {:error, :invalid_utf8} = Document.parse(card("4.0", ["FN:" <> <<0xFF>>]))
    assert {:error, :invalid_control_character} = Document.parse(card("4.0", ["FN:A\0B"]))
  end

  defp card(version, lines),
    do: Enum.join(["BEGIN:VCARD", "VERSION:" <> version] ++ lines ++ ["END:VCARD", ""], "\r\n")

  defp unfold(value), do: String.replace(value, "\r\n ", "")
end
