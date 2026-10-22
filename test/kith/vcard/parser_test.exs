defmodule Kith.VCard.ParserTest do
  use ExUnit.Case, async: true

  alias Kith.VCard.Parser

  @sample_vcard_30 """
  BEGIN:VCARD
  VERSION:3.0
  FN:Alice Smith
  N:Smith;Alice;;;
  NICKNAME:Ali
  BDAY:1990-06-15
  ORG:Acme Corp
  TITLE:Engineer
  NOTE:A great friend
  TEL;TYPE=CELL:+1-555-0100
  TEL;TYPE=HOME:+1-555-0200
  EMAIL;TYPE=WORK:alice@example.com
  ADR;TYPE=HOME:;;123 Main St;Springfield;IL;62701;US
  URL:https://alice.dev
  END:VCARD
  """

  @sample_vcard_40 """
  BEGIN:VCARD
  VERSION:4.0
  FN:Bob Jones
  N:Jones;Bob;;;
  BDAY:19850321
  TEL;TYPE=cell;VALUE=uri:tel:+1-555-0300
  EMAIL:bob@example.com
  END:VCARD
  """

  @multi_vcard """
  BEGIN:VCARD
  VERSION:3.0
  FN:Contact One
  N:One;Contact;;;
  END:VCARD
  BEGIN:VCARD
  VERSION:3.0
  FN:Contact Two
  N:Two;Contact;;;
  END:VCARD
  BEGIN:VCARD
  VERSION:3.0
  FN:Contact Three
  N:Three;Contact;;;
  END:VCARD
  """

  describe "parse/1" do
    test "parses a vCard 3.0 file" do
      {:ok, [contact]} = Parser.parse(@sample_vcard_30)

      assert contact.display_name == "Alice Smith"
      assert contact.first_name == "Alice"
      assert contact.last_name == "Smith"
      assert contact.nickname == "Ali"
      assert contact.birthdate == ~D[1990-06-15]
      assert contact.company == "Acme Corp"
      assert contact.occupation == "Engineer"
      assert contact.description == "A great friend"

      assert length(contact.phones) == 2
      assert Enum.any?(contact.phones, &(&1.value == "+1-555-0100" && &1.label == "Cell"))
      assert Enum.any?(contact.phones, &(&1.value == "+1-555-0200" && &1.label == "Home"))

      assert length(contact.emails) == 1
      assert hd(contact.emails).value == "alice@example.com"
      assert hd(contact.emails).label == "Work"

      assert length(contact.addresses) == 1
      addr = hd(contact.addresses)
      assert addr.line1 == "123 Main St"
      assert addr.city == "Springfield"
      assert addr.province == "IL"
      assert addr.postal_code == "62701"
      assert addr.country == "US"

      assert length(contact.urls) == 1
      assert hd(contact.urls).value == "https://alice.dev"
    end

    test "parses a vCard 4.0 with compact birthday" do
      {:ok, [contact]} = Parser.parse(@sample_vcard_40)

      assert contact.display_name == "Bob Jones"
      assert contact.first_name == "Bob"
      assert contact.last_name == "Jones"
      assert contact.birthdate == ~D[1985-03-21]
    end

    test "parses multiple vCards from a single file" do
      {:ok, contacts} = Parser.parse(@multi_vcard)

      assert length(contacts) == 3
      assert Enum.at(contacts, 0).display_name == "Contact One"
      assert Enum.at(contacts, 1).display_name == "Contact Two"
      assert Enum.at(contacts, 2).display_name == "Contact Three"
    end

    test "handles CRLF line endings" do
      vcard = String.replace(@sample_vcard_30, "\n", "\r\n")
      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.display_name == "Alice Smith"
    end

    test "handles line folding (continuation lines)" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Very Long
       Name Here
      N:Here;Very Long Name;;;
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      # RFC 2425: fold indicator (newline + leading space) removed, joining the lines
      assert contact.display_name == "Very LongName Here"
    end

    test "returns error for completely invalid data" do
      {:ok, contacts} = Parser.parse("this is not a vcard at all")
      assert contacts == []
    end

    test "handles empty file" do
      {:ok, contacts} = Parser.parse("")
      assert contacts == []
    end
  end

  describe "parse/1 — extended properties" do
    test "parses middle name from N property (RFC 2426 §3.1.2)" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Marie Doe
      N:Doe;Jane;Marie;;
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.middle_name == "Marie"
    end

    test "parses N without middle name as nil" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.middle_name == nil
    end

    test "parses CATEGORIES as list (RFC 2426 §3.6.1)" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      CATEGORIES:Family,Friends,VIP
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.categories == ["Family", "Friends", "VIP"]
    end

    test "parses single CATEGORIES value" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      CATEGORIES:Family
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.categories == ["Family"]
    end

    test "parses GENDER sex component (RFC 6350 §6.2.7)" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      GENDER:F
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.gender == "F"
      assert contact.gender_text == nil
    end

    test "parses GENDER with sex and text components" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Alex Smith
      N:Smith;Alex;;;
      GENDER:O;Non-binary
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.gender == "O"
      assert contact.gender_text == "Non-binary"
    end

    test "parses X-GENDER extension for vCard 3.0" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      X-GENDER:Female
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.gender_text == "Female"
    end

    test "parses RELATED with TYPE parameter (RFC 6350 §6.6.6)" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      RELATED;TYPE=spouse:urn:uuid:kith-contact-42
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert length(contact.related) == 1
      assert hd(contact.related).value == "urn:uuid:kith-contact-42"
      assert hd(contact.related).type == "Spouse"
    end

    test "parses multiple RELATED properties" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      RELATED;TYPE=spouse:urn:uuid:kith-contact-42
      RELATED;TYPE=friend:urn:uuid:kith-contact-99
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert length(contact.related) == 2
    end

    test "parses IMPP into separate list (RFC 6350 §6.4.3)" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      IMPP:xmpp:jane@chat.example.com
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert length(contact.impp) == 1
      assert hd(contact.impp).value == "xmpp:jane@chat.example.com"
      assert contact.urls == []
    end

    test "parses REV timestamp (RFC 2426 §3.6.4)" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      REV:2026-03-29T12:00:00Z
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.rev == "2026-03-29T12:00:00Z"
    end

    test "parses PHOTO with ENCODING=b and TYPE (RFC 2426 §3.1.4)" do
      b64 = Base.encode64("fake-jpeg-data")

      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      PHOTO;ENCODING=b;TYPE=JPEG:#{b64}
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo != nil
      assert contact.photo.content_type == "image/jpeg"
      assert contact.photo.encoding == :base64
      assert contact.photo.data == b64
    end

    test "parses PHOTO with data URI (RFC 6350 §6.2.4)" do
      b64 = Base.encode64("fake-png-data")

      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      PHOTO:data:image/png;base64,#{b64}
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo != nil
      assert contact.photo.content_type == "image/png"
      assert contact.photo.data == b64
    end

    test "parses PHOTO with URI reference" do
      vcard = """
      BEGIN:VCARD
      VERSION:4.0
      FN:Jane Doe
      N:Doe;Jane;;;
      PHOTO:https://example.com/photo.jpg
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo != nil
      assert contact.photo.url == "https://example.com/photo.jpg"
    end

    test "handles missing PHOTO gracefully" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      FN:Jane Doe
      N:Doe;Jane;;;
      END:VCARD
      """

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo == nil
    end

    test "parses CATEGORIES with escaped commas (RFC 2426 §3.6.1)" do
      vcard =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nN:Test;;;;\r\nCATEGORIES:Music\\,Art,Sports\r\nEND:VCARD\r\n"

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.categories == ["Music,Art", "Sports"]
    end

    test "rejects dangerous PHOTO content types (SVG XSS)" do
      b64 = Base.encode64("fake")

      vcard =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nN:Test;;;;\r\nPHOTO;ENCODING=b;TYPE=svg+xml:#{b64}\r\nEND:VCARD\r\n"

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo.content_type == "image/jpeg"
    end

    test "parses GENDER:O without text component" do
      vcard = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Alex\r\nN:Alex;;;;\r\nGENDER:O\r\nEND:VCARD\r\n"

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.gender == "O"
      assert contact.gender_text == nil
    end

    test "parses PHOTO with ENCODING=BASE64 uppercase (compatibility)" do
      b64 = Base.encode64("fake-jpeg-data")

      vcard =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nN:Test;;;;\r\nPHOTO;ENCODING=BASE64;TYPE=JPEG:#{b64}\r\nEND:VCARD\r\n"

      {:ok, [contact]} = Parser.parse(vcard)
      assert contact.photo != nil
      assert contact.photo.content_type == "image/jpeg"
      assert contact.photo.encoding == :base64
    end
  end

  describe "unescape/1" do
    test "unescapes semicolons" do
      assert Parser.unescape("a\\;b") == "a;b"
    end

    test "unescapes commas" do
      assert Parser.unescape("a\\,b") == "a,b"
    end

    test "unescapes newlines" do
      assert Parser.unescape("a\\nb") == "a\nb"
      assert Parser.unescape("a\\Nb") == "a\nb"
    end

    test "unescapes backslashes" do
      assert Parser.unescape("a\\\\b") == "a\\b"
    end

    test "returns nil for nil" do
      assert Parser.unescape(nil) == nil
    end
  end

  describe "roundtrip" do
    test "serialize then parse produces equivalent data" do
      alias Kith.VCard.Serializer

      original = %{
        display_name: "Roundtrip Test",
        first_name: "Roundtrip",
        last_name: "Test",
        nickname: "RT",
        birthdate: ~D[2000-01-15],
        company: "Test Co",
        occupation: "Tester",
        description: "Testing roundtrip",
        addresses: [
          %{
            label: "Work",
            line1: "456 Oak Ave",
            line2: nil,
            city: "Portland",
            province: "OR",
            postal_code: "97201",
            country: "US"
          }
        ],
        contact_fields: [
          %{
            value: "rt@test.com",
            label: "Home",
            contact_field_type: %{protocol: "mailto", vcard_label: "EMAIL"}
          },
          %{
            value: "+1-555-9999",
            label: nil,
            contact_field_type: %{protocol: "tel", vcard_label: "TEL"}
          }
        ],
        gender: nil
      }

      vcard = Serializer.serialize(original)
      {:ok, [parsed]} = Parser.parse(vcard)

      assert parsed.first_name == "Roundtrip"
      assert parsed.last_name == "Test"
      assert parsed.nickname == "RT"
      assert parsed.birthdate == ~D[2000-01-15]
      assert parsed.company == "Test Co"
      assert parsed.occupation == "Tester"
      assert parsed.description == "Testing roundtrip"
      assert hd(parsed.emails).value == "rt@test.com"
      assert hd(parsed.phones).value == "+1-555-9999"
      assert hd(parsed.addresses).city == "Portland"
    end
  end

  test "escaping is decoded once and escaped structure delimiters stay in components" do
    assert Parser.unescape(~S(literal \\n)) == ~S(literal \n)

    body =
      "BEGIN:VCARD\nVERSION:4.0\n" <>
        ~S(N:Family\;Last;Given\;First;Middle\,Name;Dr;Jr) <>
        "\n" <>
        ~S(ADR;TYPE=HOME:;Suite\;2;Street\;3;City\,Town;Region;Zip;Country) <>
        "\n" <>
        ~S(CATEGORIES:Ends\\,Next) <> "\nEND:VCARD\n"

    assert {:ok, [parsed]} = Parser.parse(body)
    assert parsed.last_name == "Family;Last"
    assert parsed.first_name == "Given;First"
    assert parsed.middle_name == "Middle,Name"
    assert hd(parsed.addresses).line2 == "Suite;2"
    assert hd(parsed.addresses).line1 == "Street;3"
    assert hd(parsed.addresses).country == "Country"
    assert parsed.categories == ["Ends\\", "Next"]
  end

  test "quoted parameter values may contain separators" do
    data =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Q\r\nTEL;TYPE=\"work,voice\":+15550007777\r\nADR;TYPE=home;LABEL=\"a;b:c\":;;1 Main St;Town;;;\r\nEMAIL;X-NOTE=\"x:y\";TYPE=home:q@example.test\r\nEND:VCARD\r\n"

    assert {:ok, [parsed]} = Parser.parse(data)
    assert [%{value: "+15550007777", label: "Work"}] = parsed.phones
    assert [%{label: "Home", line1: "1 Main St", city: "Town"}] = parsed.addresses
    assert [%{value: "q@example.test", label: "Home"}] = parsed.emails
  end

  test "an embedded AGENT vCard does not end the card" do
    data =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Agent Card\r\nAGENT:BEGIN:VCARD\\nFN:Agent\\nEND:VCARD\r\nNOTE:after the agent\r\nEMAIL:after@example.test\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:3.0\r\nFN:Second\r\nEND:VCARD\r\n"

    assert {:ok, [parsed, second]} = Parser.parse(data)
    assert parsed.description == "after the agent"
    assert [%{value: "after@example.test"}] = parsed.emails

    assert second.display_name == "Second"
  end

  describe "card delimiters tolerate a BOM, trailing blanks and any line ending" do
    test "a BOM-prefixed two-card file keeps both cards" do
      data =
        "\uFEFFBEGIN:VCARD\r\nVERSION:3.0\r\nFN:First\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:3.0\r\nFN:Second\r\nEND:VCARD\r\n"

      assert {:ok, [a, b]} = Parser.parse(data)
      assert {a.display_name, b.display_name} == {"First", "Second"}
    end

    test "trailing spaces and tabs on BEGIN and END do not merge cards" do
      data =
        "BEGIN:VCARD \r\nVERSION:3.0\r\nFN:A\r\nEND:VCARD \r\nBEGIN:VCARD\t\r\nVERSION:3.0\r\nFN:B\r\nEND:VCARD\t\r\n"

      assert {:ok, [a, b]} = Parser.parse(data)
      assert {a.display_name, b.display_name} == {"A", "B"}
    end

    test "CRLF, LF and lone CR line endings, mixed" do
      data = "BEGIN:VCARD\rVERSION:3.0\nFN:Mixed\r\nEMAIL:m@example.test\rEND:VCARD\n"
      assert {:ok, [card]} = Parser.parse(data)
      assert card.display_name == "Mixed"
      assert [%{value: "m@example.test"}] = card.emails
    end

    test "an escaped AGENT vCard still does not end the card" do
      data =
        "\uFEFFBEGIN:VCARD\r\nVERSION:3.0\r\nFN:Agent Card\r\nAGENT:BEGIN:VCARD\\nEND:VCARD\r\nNOTE:after\r\nEND:VCARD \r\n"

      assert {:ok, [card]} = Parser.parse(data)
      assert card.description == "after"
    end
  end

  describe "scaling" do
    # Counts BEAM reductions of the calling process rather than wall-clock time,
    # so the guard is deterministic under load (no scheduler or CI noise).
    defp parse_reductions(line_fun, n) do
      card =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Big\r\n" <>
          Enum.map_join(1..n, "\r\n", line_fun) <> "\r\nEND:VCARD\r\n"

      {:reductions, before} = Process.info(self(), :reductions)
      assert {:ok, [_]} = Parser.parse(card)
      {:reductions, after_} = Process.info(self(), :reductions)
      after_ - before
    end

    # Appending with `list ++ [x]` makes a card of n lines O(n^2): 4x the lines
    # cost ~16x the work. Linear parsing stays near 4x; 9x leaves a wide margin.
    for {name, line} <- [
          {"unknown properties", "X-PERF-@N@:value @N@"},
          {"EMAIL lines", "EMAIL:e@N@@example.test"},
          {"TEL lines", "TEL;TYPE=CELL:+1555@N@"}
        ] do
      test "parsing #{name} is linear in the number of lines" do
        template = unquote(line)
        line_fun = &String.replace(template, "@N@", to_string(&1))

        small = max(parse_reductions(line_fun, 5_000), 1)
        large = parse_reductions(line_fun, 20_000)

        assert large < small * 9,
               "5000 lines: #{small} reductions, 20000 lines: #{large} (#{Float.round(large / small, 1)}x)"
      end
    end
  end

  describe "per-card encoding" do
    test "a file with one non-UTF-8 card: strict parse refuses it, per_card isolates the card" do
      card = fn name ->
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};A;;;\r\nFN:A #{name}\r\nEND:VCARD\r\n"
      end

      data = card.("One") <> card.(<<"Zo", 0xEB>>) <> card.("Three")

      # DAV keeps the strict whole-body check.
      assert Parser.parse(data) == {:error, "Invalid UTF-8"}

      assert {:ok, [%{last_name: "One"}, {:error, "Invalid UTF-8"}, %{last_name: "Three"}]} =
               Parser.parse(data, per_card: true)

      # A fold that splits a code point is still repaired per card.
      folded =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nN:" <>
          <<0xC3>> <> "\r\n " <> <<0xBC>> <> "nal;A;;;\r\nFN:A\r\nEND:VCARD\r\n"

      assert {:ok, [%{last_name: "ünal"}, {:error, "Invalid UTF-8"}]} =
               Parser.parse(folded <> card.(<<0xFF>>), per_card: true)
    end
  end

  test "yearless birthdays use a leap-safe date and an explicit flag" do
    for line <- ["BDAY:--0229", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-02-29", "X-KITH-BDAY:--0229"] do
      assert {:ok, [parsed]} = Parser.parse("BEGIN:VCARD\n#{line}\nEND:VCARD")
      assert parsed.birthdate == ~D[2000-02-29]
      assert parsed.birthdate_year_unknown
    end
  end

  test "telephone URIs, preference-only emails and social profiles map to native fields" do
    assert {:ok, [parsed]} =
             Parser.parse(
               "BEGIN:VCARD\nN:Family;;;;\nTEL;VALUE=uri:tel:+123\nEMAIL;TYPE=PREF:a@example.test\nX-TWITTER:https://example.test/a\nX-INSTAGRAM:https://example.test/b\nX-SOCIALPROFILE;TYPE=work:https://example.test/c\nEND:VCARD"
             )

    assert parsed.first_name == nil
    assert parsed.last_name == "Family"
    assert parsed.phones == [%{value: "+123", label: nil}]
    assert parsed.emails == [%{value: "a@example.test", label: nil}]
    assert Enum.map(parsed.urls, & &1.label) == ["Twitter", "Instagram", "Work"]
  end

  for property <- ["BDAY", "X-KITH-BDAY"], value <- ["--02-29", "--0229"] do
    test "#{property} accepts yearless birthday #{value}" do
      assert {:ok, [parsed]} =
               Parser.parse("BEGIN:VCARD\n#{unquote(property)}:#{unquote(value)}\nEND:VCARD")

      assert parsed.birthdate == ~D[2000-02-29]
      assert parsed.birthdate_year_unknown
    end
  end
end
