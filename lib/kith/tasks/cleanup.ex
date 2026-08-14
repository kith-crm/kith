defmodule Kith.Tasks.Cleanup do
  @moduledoc """
  Wipes all tasks for a single account.
  """

  alias Kith.Repo
  alias Kith.Tasks.Task

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(t in Task, where: t.account_id == ^account_id))

    Logger.info("[Tasks.Cleanup] wiped #{count} task(s) for account #{account_id}")
    :ok
  end
end
