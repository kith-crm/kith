defmodule KithWeb.API.ExportController do
  @moduledoc """
  Full account JSON export.

  GET /api/export — returns inline JSON for small accounts,
                    or 202 Accepted + Oban job for large accounts (500+ contacts).
  """

  use KithWeb, :controller

  alias Kith.Contacts
  alias Kith.Exports
  alias Kith.Policy
  alias Kith.Workers.ExportWorker

  @large_export_threshold 500

  def create(conn, _params) do
    user = conn.assigns.current_api_user

    if Policy.can?(user, :read, :export) do
      account_id = user.account_id
      count = Contacts.count_contacts(account_id)

      if count >= @large_export_threshold do
        # Enqueue async export
        %{account_id: account_id, user_id: user.id}
        |> ExportWorker.new()
        |> Oban.insert()

        conn
        |> put_status(202)
        |> json(%{
          message: "Export is being prepared. You will receive an email when it's ready.",
          contact_count: count
        })
      else
        # Generate inline
        export = Exports.build_json_export(user)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="kith-export-#{Date.utc_today() |> Date.to_iso8601()}.json")
        )
        |> json(export)
      end
    else
      conn
      |> put_status(403)
      |> put_resp_content_type("application/problem+json")
      |> json(%{
        type: "about:blank",
        title: "Forbidden",
        status: 403,
        detail: "You do not have permission to export data."
      })
    end
  end
end
