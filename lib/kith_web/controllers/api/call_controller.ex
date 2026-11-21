defmodule KithWeb.API.CallController do
  @moduledoc """
  REST API controller for phone calls logged against a contact.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "calls"

  alias Kith.{Activities, Contacts, Policy, Repo}
  alias Kith.Activities.Call
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List calls for a contact ─────────────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Call
        |> TenantScope.scope_to_account(account_id)
        |> where([c], c.contact_id == ^contact_id)

      {calls, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(calls, &call_json/1), meta))
    end
  end

  # ── Show call ────────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    case Call |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil -> {:error, :not_found}
      call -> json(conn, %{data: call_json(call)})
    end
  end

  # ── Create call ──────────────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "call" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :call),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, call} <- Activities.create_call(contact, attrs) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/calls/#{call.id}")
      |> json(%{data: call_json(call)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'call' key in request body."}
  end

  # ── Update call ──────────────────────────────────────────────────────

  def update(conn, %{"id" => id, "call" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :call),
         call when not is_nil(call) <-
           Call |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- Activities.update_call(call, attrs) do
      json(conn, %{data: call_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'call' key in request body."}
  end

  # ── Delete call ──────────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :call),
         call when not is_nil(call) <-
           Call |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _call} <- Activities.delete_call(call) do
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

  defp call_json(call) do
    %{
      id: call.id,
      contact_id: call.contact_id,
      duration_mins: call.duration_mins,
      occurred_at: call.occurred_at,
      notes: call.notes,
      emotion_id: call.emotion_id,
      inserted_at: call.inserted_at,
      updated_at: call.updated_at
    }
  end
end
