defmodule KithWeb.ContactUploads do
  @moduledoc false

  alias Kith.{Contacts, Storage}

  def save(contact, path, entry, :photo) do
    save_photo(contact, path, entry, [])
  end

  def save(contact, path, entry, :document) do
    key = Storage.generate_key(contact.account_id, "documents", entry.client_name)

    case Storage.upload(path, key) do
      {:ok, storage_key} ->
        attrs = %{
          file_name: entry.client_name,
          storage_key: storage_key,
          file_size: entry.client_size,
          content_type: entry.client_type
        }

        case Contacts.create_document(contact, attrs) do
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

  def save_photo(contact, path, entry, opts) do
    attrs = %{file_name: entry.client_name, content_type: entry.client_type}

    with {:ok, bytes} <- File.read(path),
         {:ok, {_disposition, photo}} <- Contacts.store_photo(contact, bytes, attrs, opts) do
      {:ok, photo}
    end
  end
end
