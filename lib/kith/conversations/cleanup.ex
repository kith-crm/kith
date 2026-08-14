defmodule Kith.Conversations.Cleanup do
  @moduledoc """
  Wipes all conversations for a single account. FK CASCADE removes the
  associated `messages` rows.
  """

  alias Kith.Conversations.Conversation
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(c in Conversation, where: c.account_id == ^account_id))

    Logger.info(
      "[Conversations.Cleanup] wiped #{count} conversation(s) for account #{account_id}"
    )

    :ok
  end
end
