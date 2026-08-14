defmodule Kith.Contacts.Cleanup do
  @moduledoc """
  Hard-deletes all contacts (and CASCADE sub-entities) and account-scoped
  tags for a single account.

  Sub-entities cleared via FK CASCADE: addresses, contact_fields, photos
  (rows), documents (rows), notes, debts, gifts, pets, emotions,
  relationships, calls, life_events, duplicate_candidates, immich_candidates.

  Note: `Kith.Storage.AccountCleanup` MUST run before this module so that
  photo/document storage_keys can be enumerated before their rows are wiped.

  Tags are wiped here (not in a separate module) because they share the
  contacts axis-of-change and have no other purpose.
  """

  alias Kith.Contacts.{Contact, Tag}
  alias Kith.Repo

  import Ecto.Query
  require Logger

  @batch_size 200

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    contacts_deleted = delete_contacts_in_batches(account_id, 0)

    {tags_deleted, _} =
      Repo.delete_all(from(t in Tag, where: t.account_id == ^account_id))

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
        {deleted, _} = Repo.delete_all(from(c in Contact, where: c.id in ^ids))
        delete_contacts_in_batches(account_id, acc + deleted)
    end
  end
end
