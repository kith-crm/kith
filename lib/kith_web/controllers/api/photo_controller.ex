defmodule KithWeb.API.PhotoController do
  use KithWeb, :controller

  alias Kith.{Contacts, Policy, Storage}
  alias Kith.Contacts.Photo
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  @allowed_image_types ~w(image/jpeg image/png image/gif image/webp)

  def index(conn, %{"contact_id" => contact_id} = params) do
    account_id = conn.assigns.current_scope.account.id

    case Contacts.get_contact(account_id, contact_id) do
      nil ->
        {:error, :not_found}

      _contact ->
        query =
          Photo
          |> TenantScope.scope_to_account(account_id)
          |> where([p], p.contact_id == ^contact_id)

        {photos, meta} = Pagination.paginate(query, params)
        json(conn, Pagination.paginated_response(Enum.map(photos, &photo_json/1), meta))
    end
  end

  def create(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :photo),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, contact_id) do
      upload_photo(conn, contact, account_id, params["file"])
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  defp upload_photo(_conn, _contact, _account_id, nil) do
    {:error, :bad_request, "Missing file upload."}
  end

  defp upload_photo(conn, contact, account_id, %Plug.Upload{content_type: ct} = upload)
       when ct in @allowed_image_types do
    dest = Storage.generate_key(account_id, "photos", upload.filename)

    with {:ok, storage_key} <- Storage.upload(upload.path, dest),
         attrs = %{
           "file_name" => upload.filename,
           "file_size" => upload.path && File.stat!(upload.path).size,
           "storage_key" => storage_key,
           "content_type" => ct
         },
         {:ok, photo} <- Contacts.create_photo(contact, attrs) do
      conn |> put_status(201) |> json(%{data: photo_json(photo)})
    else
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, reason} -> {:error, :bad_request, "Upload failed: #{inspect(reason)}"}
    end
  end

  defp upload_photo(_conn, _contact, _account_id, %Plug.Upload{}) do
    {:error, :bad_request,
     "Invalid image type. Accepted: #{Enum.join(@allowed_image_types, ", ")}"}
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :delete, :photo) do
      true ->
        case Photo |> TenantScope.scope_to_account(account_id) |> Kith.Repo.get(id) do
          nil ->
            {:error, :not_found}

          photo ->
            Contacts.delete_photo(photo)
            send_resp(conn, 204, "")
        end

      false ->
        {:error, :forbidden}
    end
  end

  defp photo_json(%Photo{} = p) do
    %{id: p.id, contact_id: p.contact_id, file_name: p.file_name, inserted_at: p.inserted_at}
  end
end
