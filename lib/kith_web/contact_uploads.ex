defmodule KithWeb.ContactUploads do
  @moduledoc false

  alias Kith.{Contacts, Storage}

  def save(contact, path, entry, kind) when kind in [:photo, :document] do
    type = if kind == :photo, do: "photos", else: "documents"
    key = Storage.generate_key(contact.account_id, type, entry.client_name)

    case Storage.upload(path, key) do
      {:ok, storage_key} ->
        attrs = %{
          file_name: entry.client_name,
          storage_key: storage_key,
          file_size: entry.client_size,
          content_type: entry.client_type
        }

        result =
          case kind do
            :photo -> Contacts.create_photo(contact, attrs)
            :document -> Contacts.create_document(contact, attrs)
          end

        case result do
          {:ok, record} ->
            {:ok, record}

          {:error, _} = error ->
            Storage.delete(storage_key)
            error
        end

      {:error, _} = error ->
        error
    end
  end
end
