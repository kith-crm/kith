defmodule KithWeb.API.MessageController do
  @moduledoc """
  REST API controller for conversation messages.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "conversations"

  alias Kith.{Conversations, Policy}
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List messages for a conversation ───────────────────────────────

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, conversation} <- fetch_conversation(account_id, conversation_id) do
      query =
        Kith.Conversations.Message
        |> where([m], m.conversation_id == ^conversation.id)
        |> order_by([m], asc: m.sent_at)

      {messages, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(messages, &message_json/1), meta))
    end
  end

  # ── Create message ─────────────────────────────────────────────────

  def create(conn, %{"conversation_id" => conversation_id, "message" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :conversation),
         {:ok, conversation} <- fetch_conversation(account_id, conversation_id),
         {:ok, message} <- Conversations.add_message(conversation, attrs) do
      conn
      |> put_status(201)
      |> json(%{data: message_json(message)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"conversation_id" => _conversation_id}) do
    {:error, :bad_request, "Missing 'message' key in request body."}
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp fetch_conversation(account_id, conversation_id) do
    case Conversations.get_conversation(account_id, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp message_json(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      body: message.body,
      direction: message.direction,
      sent_at: message.sent_at,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end
end
