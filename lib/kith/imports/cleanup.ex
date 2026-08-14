defmodule Kith.Imports.Cleanup do
  @moduledoc """
  Wipes all import history for a single account.

  Deletes `import_records` first then `imports`. Both tables are scoped by
  `account_id` directly. Called by `Kith.Workers.AccountResetWorker`.
  """

  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {records, _} =
      Repo.delete_all(from(r in ImportRecord, where: r.account_id == ^account_id))

    {imports, _} =
      Repo.delete_all(from(i in Import, where: i.account_id == ^account_id))

    Logger.info(
      "[Imports.Cleanup] wiped #{records} record(s) + #{imports} import(s) for account #{account_id}"
    )

    :ok
  end
end
