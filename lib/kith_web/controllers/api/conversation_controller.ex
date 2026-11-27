defmodule KithWeb.API.ConversationController do
  @moduledoc """
  REST API controller for contact conversations.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "conversations"

  alias Kith.{Contacts, Conversations, Policy, Repo}
  alias Kith.Conversations.Conversation
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List conversations for a contact ───────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Conversation
        |> TenantScope.scope_to_account(account_id)
        |> where([c], c.contact_id == ^contact_id)
        |> where([c], c.is_private == false or c.creator_id == ^user_id)

      {conversations, meta} = Pagination.paginate(query, params)

      json(
        conn,
        Pagination.paginated_response(Enum.map(conversations, &conversation_json/1), meta)
      )
    end
  end

  # ── Show conversation ──────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    case Conversation |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil ->
        {:error, :not_found}

      %Conversation{is_private: true, creator_id: creator_id} when creator_id != user_id ->
        {:error, :not_found}

      conversation ->
        json(conn, %{data: conversation_json(conversation)})
    end
  end

  # ── Create conversation ────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "conversation" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :conversation),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, conversation} <-
           Conversations.create_conversation(
             account_id,
             user.id,
             Map.put(attrs, "contact_id", contact.id)
           ) do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/conversations/#{conversation.id}")
      |> json(%{data: conversation_json(conversation)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'conversation' key in request body."}
  end

  # ── Update conversation ────────────────────────────────────────────

  def update(conn, %{"id" => id, "conversation" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :conversation),
         conversation when not is_nil(conversation) <-
           Conversation |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- Conversations.update_conversation(conversation, attrs) do
      json(conn, %{data: conversation_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'conversation' key in request body."}
  end

  # ── Delete conversation ────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :conversation),
         conversation when not is_nil(conversation) <-
           Conversation |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _conversation} <- Repo.delete(conversation) do
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

  defp conversation_json(conversation) do
    %{
      id: conversation.id,
      contact_id: conversation.contact_id,
      subject: conversation.subject,
      platform: conversation.platform,
      status: conversation.status,
      is_private: conversation.is_private,
      creator_id: conversation.creator_id,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end
end
