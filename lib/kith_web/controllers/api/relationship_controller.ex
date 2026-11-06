defmodule KithWeb.API.RelationshipController do
  @moduledoc """
  REST API controller for contact relationships.
  """

  use KithWeb, :controller

  alias Kith.{Contacts, Policy, Repo}
  alias Kith.Contacts.Relationship
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List relationships for a contact ─────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Relationship
        |> TenantScope.scope_to_account(account_id)
        |> where([r], r.contact_id == ^contact_id)

      {relationships, meta} = Pagination.paginate(query, params)

      json(
        conn,
        Pagination.paginated_response(Enum.map(relationships, &relationship_json/1), meta)
      )
    end
  end

  # ── Create relationship ──────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "relationship" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :relationship),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         :ok <- validate_related_contact(account_id, attrs),
         {:ok, relationship} <-
           Contacts.create_relationship(contact, attrs) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/relationships/#{relationship.id}")
      |> json(%{data: relationship_json(relationship)})
    else
      false ->
        {:error, :forbidden}

      {:error, :related_contact_not_found} ->
        {:error, :bad_request, "Related contact does not exist in this account."}

      {:error, %Ecto.Changeset{} = cs} ->
        if unique_constraint_violation?(cs) do
          {:error, :conflict, "This relationship already exists."}
        else
          {:error, cs}
        end
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'relationship' key in request body."}
  end

  # ── Delete relationship ──────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :relationship),
         relationship when not is_nil(relationship) <-
           Relationship |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _relationship} <- Contacts.delete_relationship(relationship) do
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

  defp validate_related_contact(account_id, %{"related_contact_id" => related_id}) do
    case Contacts.get_contact(account_id, related_id) do
      nil -> {:error, :related_contact_not_found}
      _contact -> :ok
    end
  end

  defp validate_related_contact(account_id, %{related_contact_id: related_id}) do
    validate_related_contact(account_id, %{"related_contact_id" => related_id})
  end

  defp validate_related_contact(_account_id, _attrs), do: :ok

  defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp relationship_json(relationship) do
    %{
      id: relationship.id,
      contact_id: relationship.contact_id,
      related_contact_id: relationship.related_contact_id,
      relationship_type_id: relationship.relationship_type_id,
      inserted_at: relationship.inserted_at
    }
  end
end
