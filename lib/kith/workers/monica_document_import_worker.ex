defmodule Kith.Workers.MonicaDocumentImportWorker do
  @moduledoc """
  Oban worker for importing documents from Monica CRM.

  Documents are imported asynchronously after the main import completes
  because downloading binary files is time-consuming and can fail independently.

  Each job processes documents for a single contact.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Repo
  alias Kith.Storage

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "account_id" => account_id,
          "user_id" => user_id,
          "contact_id" => contact_id,
          "import_id" => import_id,
          "credential_url" => credential_url,
          "credential_api_key" => credential_api_key,
          "documents" => documents
        }
      }) do
    credential = %{url: credential_url, api_key: Imports.decrypt_credential(credential_api_key)}
    import_job = Imports.get_import!(import_id)

    Enum.each(documents, fn doc_data ->
      import_single_document(
        credential,
        account_id,
        user_id,
        contact_id,
        doc_data,
        import_job
      )
    end)

    :ok
  end

  defp import_single_document(credential, account_id, user_id, contact_id, doc_data, import_job) do
    doc_id = doc_data["id"]
    filename = doc_data["original_filename"] || "document_#{doc_id}"
    download_url = doc_data["download_url"] || doc_data["link"]

    if is_nil(download_url) do
      Logger.warning("[MonicaDocImport] No download URL for document #{doc_id}")
      :skip
    else
      case download_document(credential, download_url) do
        {:ok, binary, content_type} ->
          store_document(
            account_id,
            user_id,
            contact_id,
            binary,
            filename,
            content_type,
            doc_id,
            import_job
          )

        {:error, reason} ->
          Logger.warning(
            "[MonicaDocImport] Failed to download document #{doc_id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp download_document(credential, url) do
    headers = [{"Authorization", "Bearer #{credential.api_key}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type =
          headers
          |> Enum.find_value(fn
            {"content-type", ct} -> ct
            _ -> nil
          end) || "application/octet-stream"

        {:ok, body, content_type}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_document(
         account_id,
         _user_id,
         contact_id,
         binary,
         filename,
         content_type,
         source_id,
         import_job
       ) do
    storage_key = "documents/#{account_id}/#{contact_id}/#{Ecto.UUID.generate()}/#{filename}"

    case Storage.upload_binary(binary, storage_key) do
      {:ok, _key} ->
        contact = Repo.get!(Contacts.Contact, contact_id)

        attrs = %{
          "file_name" => filename,
          "storage_key" => storage_key,
          "file_size" => byte_size(binary),
          "content_type" => content_type
        }

        case Contacts.create_document(contact, attrs) do
          {:ok, doc} ->
            Imports.record_imported_entity(
              import_job,
              "document",
              to_string(source_id),
              "document",
              doc.id
            )

            Logger.info(
              "[MonicaDocImport] Imported document #{filename} for contact #{contact_id}"
            )

          {:error, reason} ->
            Logger.warning(
              "[MonicaDocImport] Failed to create document record: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "[MonicaDocImport] Failed to store document #{filename}: #{inspect(reason)}"
        )
    end
  end
end
