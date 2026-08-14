defmodule Kith.Activities.Cleanup do
  @moduledoc """
  Wipes all account-scoped activities for a single account. Activities have
  no contact FK so they are not cleared by `Kith.Contacts.Cleanup`'s CASCADE.
  """

  alias Kith.Activities.Activity
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(a in Activity, where: a.account_id == ^account_id))

    Logger.info("[Activities.Cleanup] wiped #{count} activit(ies) for account #{account_id}")
    :ok
  end
end
