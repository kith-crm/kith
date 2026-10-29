defmodule Kith.Contacts.Cleanup do
  @moduledoc """
  Hard-deletes all contacts (and CASCADE sub-entities) and account-scoped
  tags for a single account.

  Sub-entities cleared via FK CASCADE: addresses, contact_fields, photos
  (rows), documents (rows), notes, debts, gifts, pets, emotions,
  relationships, calls, life_events, duplicate_candidates, immich_candidates.

  The entire wipe holds the account write lock in one transaction. It deletes
  every same-account contact before publication and advances the sync floor
  once, without initializing documents that are about to be deleted. A native
  writer racing the wipe is serialized before or after it.

  For file cleanup, callers MUST run `Kith.Storage.AccountCleanup` before this
  module inside the SAME `Store.transaction/2`, so keys are enumerated before
  cascades and physical deletion waits for the outer commit. This module alone
  atomically removes database rows; it does not delete physical storage objects.

  Tags are wiped here (not in a separate module) because they share the
  contacts axis-of-change and have no other purpose.
  """

  alias Kith.Contacts.{Contact, Tag}
  alias Kith.DAV.Store
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @batch_size 200

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    {:ok, {contacts_deleted, tags_deleted}} =
      Store.transaction(account_id, fn ->
        Store.record_hard_delete(account_id)
        contacts_deleted = delete_contacts_in_batches(account_id, 0)
        {tags_deleted, _} = Repo.delete_all(from(t in Tag, where: t.account_id == ^account_id))
        {contacts_deleted, tags_deleted}
      end)

    Logger.info(
      "[Contacts.Cleanup] hard-deleted #{contacts_deleted} contact(s) + " <>
        "#{tags_deleted} tag(s) for account #{account_id}"
    )

    :ok
  end

  defp delete_contacts_in_batches(account_id, acc) do
    ids =
      Repo.all(
        from(c in Contact,
          where: c.account_id == ^account_id,
          select: c.id,
          limit: @batch_size
        )
      )

    case ids do
      [] ->
        acc

      _ ->
        {deleted, _} =
          Repo.delete_all(from(c in Contact, where: c.account_id == ^account_id and c.id in ^ids))

        delete_contacts_in_batches(account_id, acc + deleted)
    end
  end
end
