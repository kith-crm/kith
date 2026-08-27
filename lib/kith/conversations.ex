defmodule Kith.Conversations do
  @moduledoc """
  The Conversations context — managing conversations and messages for contacts.
  """

  import Ecto.Query, warn: false
  import Kith.Scope
  alias Ecto.Multi
  alias Kith.Contacts.Contact
  alias Kith.Conversations.{Conversation, Message}
  alias Kith.Repo

  def list_conversations(account_id, contact_id) do
    Conversation
    |> scope_to_account(account_id)
    |> where([c], c.contact_id == ^contact_id)
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
    |> Repo.preload(:messages)
  end

  def get_conversation!(account_id, id) do
    Conversation
    |> scope_to_account(account_id)
    |> Repo.get!(id)
    |> Repo.preload(:messages)
  end

  def get_conversation(account_id, id) do
    Conversation
    |> scope_to_account(account_id)
    |> Repo.get(id)
  end

  def create_conversation(account_id, creator_id, attrs) do
    %Conversation{account_id: account_id, creator_id: creator_id}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation |> Conversation.changeset(attrs) |> Repo.update()
  end

  def delete_conversation(%Conversation{} = conversation), do: Repo.delete(conversation)

  def add_message(%Conversation{} = conversation, attrs) do
    Multi.new()
    |> Multi.insert(:message, fn _changes ->
      %Message{
        conversation_id: conversation.id,
        account_id: conversation.account_id
      }
      |> Message.changeset(attrs)
    end)
    |> Multi.run(:update_last_talked_to, fn repo, %{message: message} ->
      if message.direction == "sent" do
        contact = repo.get!(Contact, conversation.contact_id)

        contact
        |> Ecto.Changeset.change(last_talked_to: DateTime.utc_now() |> DateTime.truncate(:second))
        |> repo.update()
      else
        {:ok, nil}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, :message, changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def list_messages(conversation_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> order_by([m], asc: m.sent_at)
    |> Repo.all()
  end
end
