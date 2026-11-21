defmodule KithWeb.API.LifeEventTypeController do
  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "life_events"

  alias Kith.{Contacts, Policy}
  alias Kith.Contacts.LifeEventType

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  def index(conn, _params) do
    account_id = conn.assigns.current_scope.account.id

    types =
      LifeEventType
      |> where([l], is_nil(l.account_id) or l.account_id == ^account_id)
      |> order_by([l], asc: l.position)
      |> Kith.Repo.all()

    json(conn, %{data: Enum.map(types, &type_json/1)})
  end

  def create(conn, %{"life_event_type" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :manage, :account) do
      true ->
        case Contacts.create_life_event_type(account_id, attrs) do
          {:ok, type} -> conn |> put_status(201) |> json(%{data: type_json(type)})
          {:error, cs} -> {:error, cs}
        end

      false ->
        {:error, :forbidden}
    end
  end

  def update(conn, %{"id" => id, "life_event_type" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :manage, :account) do
      true ->
        type = Contacts.get_life_event_type!(account_id, String.to_integer(id))

        case Contacts.update_life_event_type(type, attrs) do
          {:ok, updated} -> json(conn, %{data: type_json(updated)})
          {:error, cs} -> {:error, cs}
        end

      false ->
        {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :manage, :account) do
      true ->
        type = Contacts.get_life_event_type!(account_id, String.to_integer(id))

        case Contacts.delete_life_event_type(type) do
          {:ok, _} -> send_resp(conn, 204, "")
          {:error, cs} -> {:error, cs}
        end

      false ->
        {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp type_json(%LifeEventType{} = t) do
    %{
      id: t.id,
      name: t.name,
      icon: t.icon,
      category: t.category,
      position: t.position,
      is_custom: not is_nil(t.account_id)
    }
  end
end
