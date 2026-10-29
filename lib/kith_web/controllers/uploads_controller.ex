defmodule KithWeb.UploadsController do
  @moduledoc """
  Authenticated file serving controller for local storage backend.

  Verifies the requesting user belongs to the account that owns the file
  before streaming it from disk.

  Route: `GET /uploads/*path`
  Path format: `{account_id}/{type}/{filename}`
  """

  use KithWeb, :controller

  alias Kith.Storage
  alias Kith.Storage.Local

  def show(conn, %{"path" => path_parts}) do
    storage_key = Enum.join(path_parts, "/")

    with :ok <- Storage.validate_storage_key(storage_key),
         {account_id_str, _type, _filename} <- parse_storage_key(storage_key),
         :ok <- authorize(conn, account_id_str) do
      case Local.read(storage_key) do
        {:ok, bytes} ->
          conn
          |> put_resp_content_type(Storage.content_type(storage_key), nil)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_resp(200, bytes)

        {:error, :invalid_path} ->
          conn |> put_status(400) |> json(%{error: "Invalid path"})

        {:error, _reason} ->
          conn |> put_status(404) |> json(%{error: "File not found"})
      end
    else
      {:error, :invalid_path} ->
        conn |> put_status(400) |> json(%{error: "Invalid path"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})

      {:error, :bad_format} ->
        conn |> put_status(400) |> json(%{error: "Invalid storage key format"})
    end
  end

  defp parse_storage_key(key) do
    case String.split(key, "/", parts: 3) do
      [account_id, type, filename] when type in ~w(photos documents avatars) ->
        {account_id, type, filename}

      _ ->
        {:error, :bad_format}
    end
  end

  defp authorize(conn, account_id_str) do
    scope = conn.assigns[:current_scope]

    if scope && scope.account && to_string(scope.account.id) == account_id_str do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
