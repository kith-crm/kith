defmodule Kith.Workers.AccountResetWorker do
  @moduledoc """
  Resets a single account's data by orchestrating per-domain cleanup modules.

  Wipes everything the account owns except reference data (genders,
  relationship_types, contact_field_types, etc.) and account_invitations.
  Operations are scoped to the target account; no other account is affected.

  Each `@cleaners` module exposes `wipe_for_account(account_id) :: :ok`.
  Order is load-bearing — see `docs/superpowers/specs/2026-05-15-account-reset-completeness-design.md`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:account_id]]

  alias Kith.{
    Activities,
    AuditLogs,
    Contacts,
    Conversations,
    Imports,
    Journal,
    Reminders,
    Storage,
    Tasks
  }

  require Logger

  @cleaners [
    Imports.JobCancellation,
    Storage.AccountCleanup,
    Contacts.Cleanup,
    Imports.Cleanup,
    Conversations.Cleanup,
    Reminders.Cleanup,
    Tasks.Cleanup,
    Journal.Cleanup,
    Activities.Cleanup,
    AuditLogs.Cleanup
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Logger.metadata(account_id: account_id, worker: "AccountReset")
    Logger.info("[AccountReset] starting reset for account #{account_id}")
    write_initiated_audit_log(account_id)

    Enum.each(@cleaners, fn cleaner ->
      Logger.info("[AccountReset] running #{inspect(cleaner)}")
      :ok = cleaner.wipe_for_account(account_id)
    end)

    Logger.info("[AccountReset] completed reset for account #{account_id}")
    :ok
  end

  defp write_initiated_audit_log(account_id) do
    AuditLogs.create_audit_log(account_id, %{
      user_id: nil,
      user_name: "system",
      event: "account_data_reset",
      metadata: %{reason: "Account data reset initiated"}
    })
  end
end
