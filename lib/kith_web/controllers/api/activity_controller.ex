defmodule KithWeb.API.ActivityController do
  @moduledoc """
  REST API controller for activities.

  Activities have a many-to-many relationship with contacts via the
  `activity_contacts` join table. The index endpoint is nested under a
  contact, while create/update are flat under /api/activities.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "activities"

  alias Kith.{Activities, Contacts, Policy, Repo}
  alias Kith.Activities.Activity
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List activities for a contact ────────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Activity
        |> TenantScope.scope_to_account(account_id)
        |> join(:inner, [a], ac in "activity_contacts", on: ac.activity_id == a.id)
        |> where([_a, ac], ac.contact_id == ^contact_id)

      {activities, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(activities, &activity_json/1), meta))
    end
  end

  # ── Show activity ────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    case Activity |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil -> {:error, :not_found}
      activity -> json(conn, %{data: activity_json(activity)})
    end
  end

  # ── Create activity ──────────────────────────────────────────────────

  def create(conn, %{"activity" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :activity),
         {:ok, activity} <- Activities.create_activity(account_id, attrs) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/activities/#{activity.id}")
      |> json(%{data: activity_json(activity)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request, "Missing 'activity' key in request body."}
  end

  # ── Update activity ──────────────────────────────────────────────────

  def update(conn, %{"id" => id, "activity" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :activity),
         activity when not is_nil(activity) <-
           Activity |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- Activities.update_activity(activity, attrs) do
      json(conn, %{data: activity_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'activity' key in request body."}
  end

  # ── Delete activity ──────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :activity),
         activity when not is_nil(activity) <-
           Activity |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _activity} <- Activities.delete_activity(activity) do
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

  defp activity_json(activity) do
    %{
      id: activity.id,
      title: activity.title,
      description: activity.description,
      occurred_at: activity.occurred_at,
      inserted_at: activity.inserted_at,
      updated_at: activity.updated_at
    }
  end
end
