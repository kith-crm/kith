defmodule Kith.ContactsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Kith.Contacts` context.
  """

  alias Kith.Repo
  alias Kith.Contacts

  def contact_fixture(account_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        first_name: "Jane",
        last_name: "Doe#{System.unique_integer([:positive])}",
        display_name: "Jane Doe#{System.unique_integer([:positive])}"
      })

    {:ok, contact} = Contacts.create_contact(account_id, attrs)
    contact
  end

  def note_fixture(contact, user_id, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{"body" => "<p>Test note</p>"})
    {:ok, note} = Contacts.create_note(contact, user_id, attrs)
    note
  end

  def address_fixture(contact, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "label" => "Home",
        "line1" => "123 Main St",
        "city" => "Springfield",
        "province" => "IL",
        "postal_code" => "62701",
        "country" => "US"
      })

    {:ok, address} = Contacts.create_address(contact, attrs)
    address
  end

  def contact_field_fixture(contact, contact_field_type_id, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Enum.into(%{
        "value" => "test@example.com",
        "contact_field_type_id" => contact_field_type_id
      })

    {:ok, field} = Contacts.create_contact_field(contact, attrs)
    field
  end

  def relationship_fixture(contact, related_contact, relationship_type_id) do
    {:ok, rel} =
      Contacts.create_relationship(contact, %{
        "related_contact_id" => related_contact.id,
        "relationship_type_id" => relationship_type_id
      })

    rel
  end

  def photo_fixture(contact, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "file_name" => "photo.jpg",
        "storage_key" =>
          "contacts/#{contact.id}/photos/#{System.unique_integer([:positive])}.jpg",
        "file_size" => 12345,
        "content_type" => "image/jpeg"
      })

    {:ok, photo} = Contacts.create_photo(contact, attrs)
    photo
  end

  def document_fixture(contact, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "file_name" => "doc.pdf",
        "storage_key" => "contacts/#{contact.id}/docs/#{System.unique_integer([:positive])}.pdf",
        "file_size" => 54321,
        "content_type" => "application/pdf"
      })

    {:ok, doc} = Contacts.create_document(contact, attrs)
    doc
  end

  @doc "Seed global reference data needed by tests."
  def seed_reference_data! do
    now = DateTime.utc_now(:second)

    # Emotions
    Repo.insert_all(
      "emotions",
      [
        %{name: "Happy", account_id: nil, position: 0, inserted_at: now, updated_at: now},
        %{name: "Sad", account_id: nil, position: 1, inserted_at: now, updated_at: now}
      ],
      on_conflict: :nothing
    )

    # Life event types
    Repo.insert_all(
      "life_event_types",
      [
        %{
          name: "New job",
          icon: "briefcase",
          category: "Career",
          account_id: nil,
          position: 0,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "Marriage",
          icon: "heart",
          category: "Family",
          account_id: nil,
          position: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    # Contact field types
    Repo.insert_all(
      "contact_field_types",
      [
        %{
          name: "Email",
          system_key: "email",
          protocol: "mailto:",
          icon: "mail",
          vcard_label: "EMAIL",
          account_id: nil,
          position: 0,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "Phone",
          system_key: "phone",
          protocol: "tel:",
          icon: "phone",
          vcard_label: "TEL",
          account_id: nil,
          position: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    # Relationship types
    Repo.insert_all(
      "relationship_types",
      [
        %{
          name: "Friend",
          system_key: "friend",
          reverse_name: "Friend",
          is_bidirectional: true,
          account_id: nil,
          position: 0,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "Parent",
          system_key: "parent",
          reverse_name: "Child",
          is_bidirectional: false,
          account_id: nil,
          position: 1,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    # Call directions
    Repo.insert_all(
      "call_directions",
      [
        %{name: "Inbound", position: 0, inserted_at: now, updated_at: now},
        %{name: "Outbound", position: 1, inserted_at: now, updated_at: now}
      ],
      on_conflict: :nothing,
      conflict_target: [:name]
    )

    :ok
  end
end
