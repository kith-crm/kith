defmodule Kith.MonicaApiFixtures do
  @moduledoc """
  Factory functions for building Monica API JSON response structures.
  Used in tests for the API-crawl import source.
  """

  @doc "Builds a full contact API response object with all embedded data."
  def contact_json(overrides \\ %{})
  def contact_json(overrides) when is_list(overrides), do: contact_json(Map.new(overrides))

  def contact_json(overrides) do
    id = overrides[:id] || System.unique_integer([:positive])
    uuid = overrides[:uuid] || Ecto.UUID.generate()
    first_name = overrides[:first_name] || "Contact#{id}"
    last_name = overrides[:last_name] || "Test"

    base = %{
      "id" => id,
      "uuid" => uuid,
      "object" => "contact",
      "first_name" => first_name,
      "last_name" => last_name,
      "nickname" => overrides[:nickname],
      "description" => overrides[:description],
      "gender" => overrides[:gender],
      "gender_type" => overrides[:gender_type],
      "is_starred" => overrides[:is_starred] || false,
      "is_partial" => false,
      "is_active" => Map.get(overrides, :is_active, true),
      "is_dead" => overrides[:is_dead] || false,
      "is_me" => false,
      "information" => %{
        "relationships" => overrides[:relationships] || default_relationships(),
        "dates" => %{
          "birthdate" => overrides[:birthdate],
          "deceased_date" => nil
        },
        "career" => %{
          "job" => overrides[:job],
          "company" => overrides[:company]
        },
        "avatar" => %{
          "url" => nil,
          "source" => "default",
          "default_avatar_color" => "#93521E"
        },
        "food_preferences" => nil,
        "how_you_met" => overrides[:how_you_met] || default_how_you_met()
      },
      "addresses" => overrides[:addresses] || [],
      "tags" => overrides[:tags] || [],
      "statistics" =>
        overrides[:statistics] ||
          %{
            "number_of_calls" => 0,
            "number_of_notes" => overrides[:number_of_notes] || 0,
            "number_of_activities" => 0,
            "number_of_reminders" => 0,
            "number_of_tasks" => 0,
            "number_of_gifts" => 0,
            "number_of_debts" => 0
          },
      "contactFields" => overrides[:contact_fields] || [],
      "notes" => overrides[:notes] || [],
      "account" => %{"id" => 1},
      "created_at" => "2024-01-15T10:30:00Z",
      "updated_at" => "2024-06-20T14:45:00Z"
    }

    base
  end

  @doc "Builds a paginated contacts response envelope."
  def contacts_page_json(contacts, page \\ 1, last_page \\ 1, total \\ nil) do
    total = total || length(contacts)

    %{
      "data" => contacts,
      "links" => %{
        "first" => "https://monica.test/api/contacts?page=1",
        "last" => "https://monica.test/api/contacts?page=#{last_page}",
        "prev" => if(page > 1, do: "https://monica.test/api/contacts?page=#{page - 1}"),
        "next" => if(page < last_page, do: "https://monica.test/api/contacts?page=#{page + 1}")
      },
      "meta" => %{
        "current_page" => page,
        "from" => (page - 1) * 100 + 1,
        "last_page" => last_page,
        "per_page" => 100,
        "to" => min(page * 100, total),
        "total" => total
      }
    }
  end

  @doc "Builds a photo API response object."
  def photo_json(overrides \\ %{})
  def photo_json(overrides) when is_list(overrides), do: photo_json(Map.new(overrides))

  def photo_json(overrides) do
    id = overrides[:id] || System.unique_integer([:positive])

    %{
      "id" => id,
      "uuid" => overrides[:uuid] || Ecto.UUID.generate(),
      "object" => "photo",
      "original_filename" => overrides[:original_filename] || "photo_#{id}.jpg",
      "new_filename" => "new_#{id}.jpg",
      "filesize" => overrides[:filesize] || 1024,
      "mime_type" => overrides[:mime_type] || "image/jpeg",
      "dataUrl" => overrides[:data_url],
      "link" => overrides[:link],
      "account" => %{"id" => 1},
      "contact" =>
        overrides[:contact] || contact_short_json(1, Ecto.UUID.generate(), "John", "Doe"),
      "created_at" => "2024-03-10T08:00:00Z",
      "updated_at" => "2024-03-10T08:00:00Z"
    }
  end

  @doc "Builds a paginated photos response."
  def photos_page_json(photos, page \\ 1, last_page \\ 1, total \\ nil) do
    total = total || length(photos)

    %{
      "data" => photos,
      "links" => %{
        "first" => "https://monica.test/api/photos?page=1",
        "last" => "https://monica.test/api/photos?page=#{last_page}",
        "prev" => if(page > 1, do: "https://monica.test/api/photos?page=#{page - 1}"),
        "next" => if(page < last_page, do: "https://monica.test/api/photos?page=#{page + 1}")
      },
      "meta" => %{
        "current_page" => page,
        "from" => (page - 1) * 100 + 1,
        "last_page" => last_page,
        "per_page" => 100,
        "to" => min(page * 100, total),
        "total" => total
      }
    }
  end

  @doc "Builds a note API response object."
  def note_json(overrides \\ %{})
  def note_json(overrides) when is_list(overrides), do: note_json(Map.new(overrides))

  def note_json(overrides) do
    %{
      "id" => overrides[:id] || System.unique_integer([:positive]),
      "uuid" => overrides[:uuid] || Ecto.UUID.generate(),
      "object" => "note",
      "body" => overrides[:body] || "Test note body",
      "is_favorited" => false,
      "favorited_at" => nil,
      "account" => %{"id" => 1},
      "created_at" => "2024-02-20T12:00:00Z",
      "updated_at" => "2024-02-20T12:00:00Z"
    }
  end

  @doc "Builds a paginated notes response."
  def notes_page_json(notes, page \\ 1, last_page \\ 1, total \\ nil) do
    total = total || length(notes)

    %{
      "data" => notes,
      "links" => %{
        "first" => "https://monica.test/api/contacts/1/notes?page=1",
        "last" => "https://monica.test/api/contacts/1/notes?page=#{last_page}"
      },
      "meta" => %{
        "current_page" => page,
        "last_page" => last_page,
        "per_page" => 100,
        "total" => total
      }
    }
  end

  @doc "Builds a ContactShort object."
  def contact_short_json(id, uuid, first_name, last_name) do
    %{
      "id" => id,
      "uuid" => uuid,
      "object" => "contact",
      "first_name" => first_name,
      "last_name" => last_name,
      "complete_name" => "#{first_name} #{last_name}",
      "initials" => "#{String.first(first_name)}#{String.first(last_name)}",
      "is_partial" => false
    }
  end

  @doc "Builds an address object for embedding in a contact."
  def address_json(overrides \\ %{})
  def address_json(overrides) when is_list(overrides), do: address_json(Map.new(overrides))

  def address_json(overrides) do
    %{
      "id" => overrides[:id] || System.unique_integer([:positive]),
      "uuid" => overrides[:uuid] || Ecto.UUID.generate(),
      "object" => "address",
      "name" => overrides[:name] || "Home",
      "street" => overrides[:street] || "123 Main St",
      "city" => overrides[:city] || "Springfield",
      "province" => overrides[:province] || "IL",
      "postal_code" => overrides[:postal_code] || "62701",
      "country" => overrides[:country] || %{"name" => "United States"}
    }
  end

  @doc "Builds a contact field object for embedding in a contact."
  def contact_field_json(overrides \\ %{})

  def contact_field_json(overrides) when is_list(overrides),
    do: contact_field_json(Map.new(overrides))

  def contact_field_json(overrides) do
    %{
      "id" => overrides[:id] || System.unique_integer([:positive]),
      "uuid" => overrides[:uuid] || Ecto.UUID.generate(),
      "object" => "contactfield",
      "content" => overrides[:content] || "test@example.com",
      "contact_field_type" => %{
        "id" => overrides[:type_id] || 1,
        "name" => overrides[:type_name] || "Email"
      }
    }
  end

  @doc "Builds a tag object for embedding in a contact."
  def tag_json(name) do
    %{
      "id" => System.unique_integer([:positive]),
      "object" => "tag",
      "name" => name,
      "name_slug" => String.downcase(name) |> String.replace(" ", "-")
    }
  end

  defp default_relationships do
    %{
      "love" => %{"total" => 0, "contacts" => []},
      "family" => %{"total" => 0, "contacts" => []},
      "friend" => %{"total" => 0, "contacts" => []},
      "work" => %{"total" => 0, "contacts" => []}
    }
  end

  defp default_how_you_met do
    %{
      "general_information" => nil,
      "first_met_date" => nil,
      "first_met_through_contact" => nil
    }
  end
end
