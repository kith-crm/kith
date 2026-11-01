defmodule KithWeb.API.ContactExportController do
  @moduledoc """
  API endpoints for exporting contacts as vCard files.

  GET /api/contacts/:id/export.vcf — single contact vCard export
  GET /api/contacts/export.vcf     — bulk export (all or by IDs)
  """

  use KithWeb, :controller

  alias Kith.Contacts
  alias Kith.DAV.Store
  alias Kith.VCard.Serializer

  @doc """
  Export a single contact as a vCard 3.0 file.

  All roles can export (read operation).
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_api_user
    account_id = user.account_id
    Store.ensure_rows(account_id)

    case Contacts.get_contact(account_id, id, preload: Contacts.export_preloads()) do
      nil ->
        conn
        |> put_status(404)
        |> put_resp_content_type("application/problem+json")
        |> json(%{
          type: "about:blank",
          title: "Not Found",
          status: 404,
          detail: "Contact not found."
        })

      contact ->
        vcard = Serializer.serialize(contact, include_uid: true)
        filename = safe_filename(contact.display_name || "contact")

        conn
        |> put_resp_content_type("text/vcard")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{filename}.vcf")
        )
        |> send_resp(200, vcard)
    end
  end

  @doc """
  Export multiple contacts as a single vCard file.

  - With `ids[]` param: export specific contacts
  - Without params: export ALL non-deleted contacts for the account

  Uses chunked transfer encoding for streaming.
  """
  def bulk(conn, params) do
    user = conn.assigns.current_api_user
    account_id = user.account_id
    Store.ensure_rows(account_id)
    ids = Map.get(params, "ids", nil)

    Kith.AuditLogs.log_event(account_id, user, :data_exported,
      metadata: %{format: "vcf", scope: if(ids, do: "selected", else: "all")}
    )

    date = Date.utc_today() |> Date.to_iso8601()

    conn =
      conn
      |> put_resp_content_type("text/vcard")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="kith-contacts-#{date}.vcf")
      )
      |> send_chunked(200)

    stream =
      if ids do
        validated_ids = Enum.map(ids, &parse_id/1) |> Enum.reject(&is_nil/1)

        Contacts.stream_contacts_by_ids(account_id, validated_ids,
          preload: Contacts.export_preloads()
        )
      else
        Contacts.stream_all_contacts(account_id, preload: Contacts.export_preloads())
      end

    {:ok, conn} =
      Kith.Repo.transaction(fn -> Enum.reduce_while(stream, conn, &chunk_contact/2) end)

    conn
  end

  defp chunk_contact(contact, conn) do
    case chunk(conn, Serializer.serialize(contact, include_uid: true)) do
      {:ok, conn} -> {:cont, conn}
      {:error, _closed} -> {:halt, conn}
    end
  end

  defp safe_filename(name) do
    name
    |> String.replace(~r/[^\w\s\-]/, "")
    |> String.trim()
    |> case do
      "" -> "contact"
      name -> name
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(_), do: nil
end
