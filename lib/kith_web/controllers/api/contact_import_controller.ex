defmodule KithWeb.API.ContactImportController do
  @moduledoc """
  API endpoint for importing contacts from vCard files.

  POST /api/contacts/import — accepts a .vcf file upload (multipart form)
  """

  use KithWeb, :controller

  alias Kith.AuditLogs
  alias Kith.Contacts
  alias Kith.Policy
  alias Kith.VCard.Parser
  alias Kith.Workers.ImportWorker

  @max_file_size 10 * 1024 * 1024

  def create(conn, %{"file" => upload}) do
    user = conn.assigns.current_api_user

    if Policy.can?(user, :create, :import) do
      do_create_import(conn, user, upload)
    else
      conn
      |> put_status(403)
      |> put_resp_content_type("application/problem+json")
      |> json(%{
        type: "about:blank",
        title: "Forbidden",
        status: 403,
        detail: "You do not have permission to import contacts."
      })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> put_resp_content_type("application/problem+json")
    |> json(%{
      type: "about:blank",
      title: "Bad Request",
      status: 400,
      detail: "Missing file upload. Send a .vcf file as multipart form data with key 'file'."
    })
  end

  defp do_create_import(conn, user, upload) do
    with :ok <- validate_file_size(upload),
         {:ok, data} <- read_upload(upload),
         {:ok, parsed_contacts} <- Parser.parse(data, per_card: true) do
      dispatch_import(conn, user, data, parsed_contacts)
    else
      {:error, :file_too_large} ->
        problem_json(conn, 413, "Payload Too Large", "File size exceeds the 10MB limit.")

      {:error, reason} when is_binary(reason) ->
        problem_json(conn, 422, "Unprocessable Entity", reason)
    end
  end

  defp dispatch_import(conn, user, data, parsed_contacts) when length(parsed_contacts) > 100 do
    %{account_id: user.account_id, user_id: user.id, file_data: data}
    |> ImportWorker.new()
    |> Oban.insert()

    AuditLogs.log_event(user.account_id, user, :data_imported,
      metadata: %{format: "vcf", count: length(parsed_contacts), async: true}
    )

    conn
    |> put_status(202)
    |> json(%{
      message:
        "Import is being processed. This may take a few minutes for #{length(parsed_contacts)} contacts.",
      total: length(parsed_contacts)
    })
  end

  defp dispatch_import(conn, user, _data, parsed_contacts) do
    results = import_contacts_sync(user.account_id, parsed_contacts)

    AuditLogs.log_event(user.account_id, user, :data_imported,
      metadata: %{
        format: "vcf",
        imported: results.imported,
        skipped: results.skipped,
        async: false
      }
    )

    conn |> put_status(200) |> json(results)
  end

  defp problem_json(conn, status, title, detail) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/problem+json")
    |> json(%{type: "about:blank", title: title, status: status, detail: detail})
  end

  defp validate_file_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_file_size -> :ok
      {:ok, _} -> {:error, :file_too_large}
      {:error, _} -> {:error, "Could not read uploaded file."}
    end
  end

  defp read_upload(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "Could not read uploaded file."}
    end
  end

  @doc false
  def import_contacts_sync(account_id, parsed_contacts) do
    results =
      parsed_contacts
      |> Enum.with_index(1)
      |> Enum.reduce(%{imported: 0, skipped: 0, skipped_duplicates: 0, errors: []}, fn {parsed,
                                                                                        idx},
                                                                                       acc ->
        try do
          if Contacts.contact_exists?(account_id, parsed) do
            %{acc | skipped: acc.skipped + 1, skipped_duplicates: acc.skipped_duplicates + 1}
          else
            case Contacts.import_contact(account_id, parsed) do
              {:ok, _contact} ->
                %{acc | imported: acc.imported + 1}

              {:error, reason} ->
                error_msg = "Entry #{idx}: #{inspect(reason)}"
                %{acc | skipped: acc.skipped + 1, errors: acc.errors ++ [error_msg]}
            end
          end
        rescue
          e ->
            error_msg = "Entry #{idx}: #{Exception.message(e)}"
            %{acc | skipped: acc.skipped + 1, errors: acc.errors ++ [error_msg]}
        end
      end)

    message =
      if results.skipped_duplicates > 0 do
        "#{results.skipped_duplicates} contacts skipped — already exist. Use the merge feature to combine duplicates."
      else
        nil
      end

    Map.put(results, :duplicate_message, message)
  end
end
