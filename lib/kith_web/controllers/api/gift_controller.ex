defmodule KithWeb.API.GiftController do
  @moduledoc """
  REST API controller for contact gifts.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "gifts"

  alias Kith.{Contacts, Gifts, Policy, Repo}
  alias Kith.Contacts.Gift
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List gifts for a contact ───────────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Gift
        |> TenantScope.scope_to_account(account_id)
        |> where([g], g.contact_id == ^contact_id)
        |> where([g], g.is_private == false or g.creator_id == ^user_id)

      {gifts, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(gifts, &gift_json/1), meta))
    end
  end

  # ── Show gift ──────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    case Gift |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil ->
        {:error, :not_found}

      %Gift{is_private: true, creator_id: creator_id} when creator_id != user_id ->
        {:error, :not_found}

      gift ->
        json(conn, %{data: gift_json(gift)})
    end
  end

  # ── Create gift ────────────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "gift" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :gift),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, gift} <-
           Gifts.create_gift(account_id, user.id, Map.put(attrs, "contact_id", contact.id)) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/gifts/#{gift.id}")
      |> json(%{data: gift_json(gift)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'gift' key in request body."}
  end

  # ── Update gift ────────────────────────────────────────────────────

  def update(conn, %{"id" => id, "gift" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :gift),
         gift when not is_nil(gift) <-
           Gift |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- Gifts.update_gift(gift, attrs) do
      json(conn, %{data: gift_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'gift' key in request body."}
  end

  # ── Delete gift ────────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :gift),
         gift when not is_nil(gift) <-
           Gift |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _gift} <- Repo.delete(gift) do
      send_resp(conn, 204, "")
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp fetch_contact(account_id, contact_id) do
    case Contacts.get_contact(account_id, contact_id) do
      nil -> {:error, :not_found}
      contact -> {:ok, contact}
    end
  end

  defp gift_json(gift) do
    %{
      id: gift.id,
      contact_id: gift.contact_id,
      name: gift.name,
      description: gift.description,
      occasion: gift.occasion,
      date: gift.date,
      amount: gift.amount,
      direction: gift.direction,
      status: gift.status,
      purchase_url: gift.purchase_url,
      currency_id: gift.currency_id,
      is_private: gift.is_private,
      creator_id: gift.creator_id,
      inserted_at: gift.inserted_at,
      updated_at: gift.updated_at
    }
  end
end
