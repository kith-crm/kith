defmodule KithWeb.API.ActivityTypeCategoryController do
  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "activities"

  alias Kith.{Contacts, Policy}
  alias Kith.Contacts.ActivityTypeCategory

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  def index(conn, _params) do
    account_id = conn.assigns.current_scope.account.id

    categories =
      ActivityTypeCategory
      |> where([a], is_nil(a.account_id) or a.account_id == ^account_id)
      |> order_by([a], asc: a.position)
      |> Kith.Repo.all()

    json(conn, %{data: Enum.map(categories, &category_json/1)})
  end

  def create(conn, %{"activity_type_category" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :manage, :account) do
      true ->
        case Contacts.create_activity_type_category(account_id, attrs) do
          {:ok, cat} -> conn |> put_status(201) |> json(%{data: category_json(cat)})
          {:error, cs} -> {:error, cs}
        end

      false ->
        {:error, :forbidden}
    end
  end

  def update(conn, %{"id" => id, "activity_type_category" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    case Policy.can?(user, :manage, :account) do
      true ->
        cat = Contacts.get_activity_type_category!(account_id, String.to_integer(id))

        case Contacts.update_activity_type_category(cat, attrs) do
          {:ok, updated} -> json(conn, %{data: category_json(updated)})
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
        cat = Contacts.get_activity_type_category!(account_id, String.to_integer(id))

        case Contacts.delete_activity_type_category(cat) do
          {:ok, _} -> send_resp(conn, 204, "")
          {:error, cs} -> {:error, cs}
        end

      false ->
        {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp category_json(%ActivityTypeCategory{} = c) do
    %{
      id: c.id,
      name: c.name,
      icon: c.icon,
      position: c.position,
      is_custom: not is_nil(c.account_id)
    }
  end
end
