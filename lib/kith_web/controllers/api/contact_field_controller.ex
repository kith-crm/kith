defmodule KithWeb.API.ContactFieldController do
  @moduledoc """
  REST API controller for contact fields (email, phone, etc.).
  """

  use KithWeb, :controller

  alias Kith.{Contacts, Policy, Repo}
  alias Kith.Contacts.ContactField
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List contact fields for a contact ────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        ContactField
        |> TenantScope.scope_to_account(account_id)
        |> where([cf], cf.contact_id == ^contact_id)

      {fields, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(fields, &contact_field_json/1), meta))
    end
  end

  # ── Create contact field ─────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "contact_field" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :contact_field),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, field} <-
           Contacts.create_contact_field(contact, attrs) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/contact_fields/#{field.id}")
      |> json(%{data: contact_field_json(field)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'contact_field' key in request body."}
  end

  # ── Update contact field ─────────────────────────────────────────────

  def update(conn, %{"id" => id, "contact_field" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact_field),
         field when not is_nil(field) <-
           ContactField |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- Contacts.update_contact_field(field, attrs) do
      json(conn, %{data: contact_field_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'contact_field' key in request body."}
  end

  # ── Delete contact field ─────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :contact_field),
         field when not is_nil(field) <-
           ContactField |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _field} <- Contacts.delete_contact_field(field) do
      send_resp(conn, 204, "")
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp fetch_contact(account_id, contact_id) do
    case Contacts.get_contact(account_id, contact_id) do
      nil -> {:error, :not_found}
      contact -> {:ok, contact}
    end
  end

  defp contact_field_json(field) do
    %{
      id: field.id,
      contact_id: field.contact_id,
      contact_field_type_id: field.contact_field_type_id,
      value: field.value,
      inserted_at: field.inserted_at,
      updated_at: field.updated_at
    }
  end
end
