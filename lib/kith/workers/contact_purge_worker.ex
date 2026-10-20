defmodule Kith.Workers.ContactPurgeWorker do
  @moduledoc """
  Nightly cron job (3 AM UTC) that permanently hard-deletes contacts
  whose `deleted_at` timestamp is older than 30 days.

  - Batches at 500 to avoid long-running transactions
  - Each contact deletion is its own transaction
  - Reminders and their instances go with the contact (FK cascade); a
    queued reminder email whose instance is gone discards itself
  - Creates audit log entries with contact name snapshot (survives deletion)
  - Idempotent: safe to run multiple times
  """

  use Oban.Worker, queue: :purge

  require Logger

  alias Kith.Contacts.Contact
  alias Kith.Repo

  import Ecto.Query

  @batch_size 500
  @purge_after_days 30

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@purge_after_days * 86_400, :second)

    contacts =
      from(c in Contact,
        where: not is_nil(c.deleted_at),
        where: c.deleted_at < ^cutoff,
        limit: ^@batch_size,
        preload: []
      )
      |> Repo.all()

    purged =
      Enum.count(contacts, fn contact ->
        try do
          purge_contact(contact)
          true
        rescue
          e ->
            Logger.error(
              "ContactPurgeWorker failed for contact #{contact.id}: #{Exception.message(e)}"
            )

            false
        end
      end)

    if purged > 0 do
      Logger.info("ContactPurgeWorker purged #{purged} contacts")
    end

    :ok
  end

  defp purge_contact(contact) do
    # Create audit log entry synchronously (we're already in an Oban job, no need to double-enqueue).
    # Must insert before deletion since the contact will be cascade-deleted.
    Kith.AuditLogs.create_audit_log(contact.account_id, %{
      user_id: nil,
      user_name: "system",
      event: "contact_purged",
      contact_id: contact.id,
      contact_name: contact.display_name || contact.first_name,
      metadata: %{reason: "Contact permanently purged after 30-day trash window."}
    })

    # Hard-delete (CASCADE removes all sub-entities)
    Repo.delete!(contact)
  end
end
