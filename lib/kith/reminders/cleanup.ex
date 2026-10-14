defmodule Kith.Reminders.Cleanup do
  @moduledoc """
  Deletes the account's reminders. FK CASCADE removes `reminder_instances`.

  Note: `reminder_rules` is intentionally NOT wiped — rules are account-level
  pre-notification configuration (3 defaults seeded per account, toggleable
  but not deletable per the schema) and are treated as reference data.
  """

  alias Kith.Reminders.Reminder
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {count, _} =
      Repo.delete_all(from(r in Reminder, where: r.account_id == ^account_id))

    Logger.info("[Reminders.Cleanup] wiped #{count} reminder(s) for account #{account_id}")
    :ok
  end
end
