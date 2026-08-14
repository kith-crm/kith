defmodule Kith.Journal.Cleanup do
  @moduledoc """
  Wipes all journal entries for a single account.
  """

  alias Kith.Journal.Entry
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(e in Entry, where: e.account_id == ^account_id))

    Logger.info("[Journal.Cleanup] wiped #{count} journal entr(ies) for account #{account_id}")
    :ok
  end
end
