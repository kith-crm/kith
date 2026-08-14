defmodule Kith.AuditLogs.Cleanup do
  @moduledoc """
  Wipes all audit logs for a single account. Runs LAST in the reset pipeline
  so the "account_data_reset" log written at the start of the worker lives
  until the rest of cleanup completes.
  """

  alias Kith.AuditLogs.AuditLog
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(a in AuditLog, where: a.account_id == ^account_id))

    Logger.info("[AuditLogs.Cleanup] wiped #{count} audit log(s) for account #{account_id}")
    :ok
  end
end
