defmodule KithWeb.API.LifeEventController do
  @moduledoc """
  REST API controller for contact life events.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "life_events"

  alias Kith.Activities.LifeEvent
  alias Kith.{Contacts, Policy, Repo}
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List life events for a contact ───────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        LifeEvent
        |> TenantScope.scope_to_account(account_id)
        |> where([le], le.contact_id == ^contact_id)

      {life_events, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(life_events, &life_event_json/1), meta))
    end
  end

  # ── Show life event ──────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    case LifeEvent |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil -> {:error, :not_found}
      life_event -> json(conn, %{data: life_event_json(life_event)})
    end
  end

  # ── Create life event ───────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "life_event" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :life_event),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, life_event} <-
           %LifeEvent{contact_id: contact.id, account_id: account_id}
           |> LifeEvent.changeset(attrs)
           |> Repo.insert() do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/life_events/#{life_event.id}")
      |> json(%{data: life_event_json(life_event)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'life_event' key in request body."}
  end

  # ── Update life event ───────────────────────────────────────────────

  def update(conn, %{"id" => id, "life_event" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :life_event),
         life_event when not is_nil(life_event) <-
           LifeEvent |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- life_event |> LifeEvent.changeset(attrs) |> Repo.update() do
      json(conn, %{data: life_event_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'life_event' key in request body."}
  end

  # ── Delete life event ───────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :life_event),
         life_event when not is_nil(life_event) <-
           LifeEvent |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _life_event} <- Repo.delete(life_event) do
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

  defp life_event_json(life_event) do
    %{
      id: life_event.id,
      contact_id: life_event.contact_id,
      life_event_type_id: life_event.life_event_type_id,
      occurred_on: life_event.occurred_on,
      note: life_event.note,
      inserted_at: life_event.inserted_at,
      updated_at: life_event.updated_at
    }
  end
end
