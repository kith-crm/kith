defmodule Kith.VCard.SerializerTest do
  use ExUnit.Case, async: true

  alias Kith.VCard.Serializer

  describe "serialize/1" do
    test "generates valid vCard 3.0 with all fields" do
      contact = %{
        display_name: "Alice Smith",
        first_name: "Alice",
        last_name: "Smith",
        nickname: "Ali",
        birthdate: ~D[1990-06-15],
        company: "Acme Corp",
        occupation: "Engineer",
        description: "A great friend",
        addresses: [
          %{
            label: "Home",
            line1: "123 Main St",
            line2: "Apt 4",
            city: "Springfield",
            province: "IL",
            postal_code: "62701",
            country: "US"
          }
        ],
        contact_fields: [
          %{
            value: "alice@example.com",
            label: "Work",
            contact_field_type: %{protocol: "mailto", vcard_label: "EMAIL"}
          },
          %{
            value: "+1-555-0100",
            label: "Cell",
            contact_field_type: %{protocol: "tel", vcard_label: "TEL"}
          },
          %{
            value: "https://alice.dev",
            label: nil,
            contact_field_type: %{protocol: "https", vcard_label: nil}
          }
        ],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)

      assert String.contains?(vcard, "BEGIN:VCARD\r\n")
      assert String.contains?(vcard, "VERSION:3.0\r\n")
      assert String.contains?(vcard, "FN:Alice Smith\r\n")
      assert String.contains?(vcard, "N:Smith;Alice;;;\r\n")
      assert String.contains?(vcard, "NICKNAME:Ali\r\n")
      assert String.contains?(vcard, "BDAY:1990-06-15\r\n")
      assert String.contains?(vcard, "ORG:Acme Corp\r\n")
      assert String.contains?(vcard, "TITLE:Engineer\r\n")
      assert String.contains?(vcard, "NOTE:A great friend\r\n")
      assert String.contains?(vcard, "EMAIL;TYPE=WORK:alice@example.com\r\n")
      assert String.contains?(vcard, "TEL;TYPE=CELL:+1-555-0100\r\n")
      assert String.contains?(vcard, "URL:https://alice.dev\r\n")

      assert String.contains?(
               vcard,
               "ADR;TYPE=HOME:;Apt 4;123 Main St;Springfield;IL;62701;US\r\n"
             )

      assert String.contains?(vcard, "END:VCARD\r\n")
    end

    test "omits nil fields" do
      contact = %{
        display_name: "Bob",
        first_name: "Bob",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)

      assert String.contains?(vcard, "FN:Bob")
      refute String.contains?(vcard, "NICKNAME")
      refute String.contains?(vcard, "BDAY")
      refute String.contains?(vcard, "ORG")
      refute String.contains?(vcard, "TITLE")
      refute String.contains?(vcard, "NOTE")
    end

    test "escapes special characters" do
      contact = %{
        display_name: "O'Brien, Jr.",
        first_name: "O'Brien",
        last_name: "Smith; Doe",
        nickname: nil,
        birthdate: nil,
        company: "Foo, Bar & Baz",
        occupation: nil,
        description: "Line 1\nLine 2",
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)

      assert String.contains?(vcard, "N:Smith\\; Doe;O'Brien;;;\r\n")
      assert String.contains?(vcard, "ORG:Foo\\, Bar & Baz\r\n")
      assert String.contains?(vcard, "NOTE:Line 1\\nLine 2\r\n")
    end
  end

  describe "serialize_many/1" do
    test "concatenates multiple vCards" do
      contacts = [
        %{
          display_name: "Alice",
          first_name: "Alice",
          last_name: "A",
          nickname: nil,
          birthdate: nil,
          company: nil,
          occupation: nil,
          description: nil,
          addresses: [],
          contact_fields: [],
          gender: nil,
          tags: [],
          relationships: []
        },
        %{
          display_name: "Bob",
          first_name: "Bob",
          last_name: "B",
          nickname: nil,
          birthdate: nil,
          company: nil,
          occupation: nil,
          description: nil,
          addresses: [],
          contact_fields: [],
          gender: nil,
          tags: [],
          relationships: []
        }
      ]

      result = Serializer.serialize_many(contacts)
      blocks = String.split(result, "BEGIN:VCARD") |> Enum.reject(&(&1 == ""))
      assert length(blocks) == 2
    end
  end

  describe "escape/1" do
    test "escapes semicolons" do
      assert Serializer.escape("a;b") == "a\\;b"
    end

    test "escapes commas" do
      assert Serializer.escape("a,b") == "a\\,b"
    end

    test "escapes newlines" do
      assert Serializer.escape("a\nb") == "a\\nb"
      assert Serializer.escape("a\r\nb") == "a\\nb"
    end

    test "escapes backslashes" do
      assert Serializer.escape("a\\b") == "a\\\\b"
    end

    test "returns empty string for nil" do
      assert Serializer.escape(nil) == ""
    end
  end

  describe "serialize/2 — vCard 3.0 extended properties" do
    test "includes middle name in N property (RFC 2426 §3.1.2)" do
      contact = %{
        display_name: "Alice Marie Smith",
        first_name: "Alice",
        last_name: "Smith",
        middle_name: "Marie",
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "N:Smith;Alice;Marie;;\r\n")
    end

    test "includes REV with updated_at timestamp (RFC 2426 §3.6.4)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: [],
        updated_at: ~U[2026-03-29 12:00:00Z]
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "REV:2026-03-29T12:00:00Z\r\n")
    end

    test "includes X-GENDER when gender is set (vCard 3.0)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: %{name: "Female"},
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "X-GENDER:Female\r\n")
      refute String.contains?(vcard, "\r\nGENDER:F")
    end

    test "includes CATEGORIES from tags (RFC 2426 §3.6.1)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [%{name: "Family"}, %{name: "VIP"}],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "CATEGORIES:Family,VIP\r\n")
    end

    test "escapes commas in CATEGORIES tag names (RFC 2426 §3.6.1)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        middle_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [%{name: "Music, Art"}, %{name: "VIP"}],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "CATEGORIES:Music\\, Art,VIP\r\n")
    end

    test "omits CATEGORIES when tags is empty" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      refute String.contains?(vcard, "CATEGORIES")
    end

    test "omits X-GENDER when gender is nil" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      refute String.contains?(vcard, "GENDER")
      refute String.contains?(vcard, "X-GENDER")
    end

    test "omits REV when updated_at is missing" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      refute String.contains?(vcard, "REV:")
    end

    test "includes PHOTO with ENCODING=b when avatar_data is set (RFC 2426 §3.1.4)" do
      photo_binary = "fake-jpeg-data"

      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: [],
        avatar_data: %{binary: photo_binary, content_type: "image/jpeg"}
      }

      vcard = Serializer.serialize(contact)
      b64 = Base.encode64(photo_binary)
      assert String.contains?(vcard, "PHOTO;ENCODING=b;TYPE=JPEG:#{b64}")
    end

    test "omits PHOTO when no avatar_data" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact)
      refute String.contains?(vcard, "PHOTO")
    end

    test "includes X-ABRELATEDNAMES for relationships in v3.0" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: [
          %{
            id: 1,
            related_contact_id: 42,
            related_contact: %{display_name: "Bob Smith", first_name: "Bob", last_name: "Smith"},
            relationship_type: %{name: "Spouse"}
          }
        ]
      }

      vcard = Serializer.serialize(contact)
      assert String.contains?(vcard, "X-ABRELATEDNAMES:Bob Smith")
      assert String.contains?(vcard, "X-ABLabel:_$!<Spouse>!$_")
    end
  end

  describe "serialize/2 — vCard 4.0" do
    test "outputs VERSION:4.0 (RFC 6350)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact, version: :v40)
      assert String.contains?(vcard, "VERSION:4.0\r\n")
      refute String.contains?(vcard, "VERSION:3.0")
    end

    test "includes GENDER with sex component (RFC 6350 §6.2.7)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: %{name: "Male"},
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact, version: :v40)
      assert String.contains?(vcard, "GENDER:M\r\n")
      refute String.contains?(vcard, "X-GENDER")
    end

    test "includes GENDER with sex and text for non-standard genders" do
      contact = %{
        display_name: "Alex",
        first_name: "Alex",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: %{name: "Non-binary"},
        tags: [],
        relationships: []
      }

      vcard = Serializer.serialize(contact, version: :v40)
      assert String.contains?(vcard, "GENDER:O;Non-binary\r\n")
    end

    test "includes RELATED with TYPE parameter (RFC 6350 §6.6.6)" do
      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: [
          %{
            id: 1,
            related_contact_id: 42,
            related_contact: %{display_name: "Bob", first_name: "Bob", last_name: nil},
            relationship_type: %{name: "Friend"}
          }
        ]
      }

      vcard = Serializer.serialize(contact, version: :v40)
      assert String.contains?(vcard, "RELATED;TYPE=friend:urn:uuid:kith-contact-42\r\n")
      refute String.contains?(vcard, "X-ABRELATEDNAMES")
    end

    test "includes PHOTO with data URI (RFC 6350 §6.2.4)" do
      photo_binary = "fake-png-data"

      contact = %{
        display_name: "Alice",
        first_name: "Alice",
        last_name: nil,
        nickname: nil,
        birthdate: nil,
        company: nil,
        occupation: nil,
        description: nil,
        addresses: [],
        contact_fields: [],
        gender: nil,
        tags: [],
        relationships: [],
        avatar_data: %{binary: photo_binary, content_type: "image/png"}
      }

      vcard = Serializer.serialize(contact, version: :v40)
      b64 = Base.encode64(photo_binary)
      assert String.contains?(vcard, "PHOTO:data:image/png;base64,#{b64}")
      refute String.contains?(vcard, "ENCODING=b")
    end
  end

  test "CDV-76: folded output never splits a UTF-8 sequence" do
    contact = %{
      first_name: "小明😀 مرحبا",
      last_name: "王",
      nickname: nil,
      birthdate: nil,
      company: nil,
      occupation: nil,
      description: String.duplicate("漢字😀مرحباשלום", 20)
    }

    card = Serializer.serialize(contact)
    assert String.valid?(card)

    for line <- String.split(card, "\r\n") do
      assert byte_size(line) <= 75
      assert String.valid?(line)
    end
  end
end
