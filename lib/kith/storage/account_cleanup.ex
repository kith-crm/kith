defmodule Kith.Storage.AccountCleanup do
  @moduledoc """
  Deletes physical storage objects (photos, documents, import upload files)
  for a single account.

  Storage failures (S3 already-deleted, network blip) are logged at `:warning`
  but never raise — they must not abort the surrounding account reset.
  Storage objects are recoverable separately (S3 lifecycle, manual sweep)
  and don't affect data integrity.

  Must run BEFORE `Kith.Contacts.Cleanup` — once contacts are hard-deleted,
  the `photos` and `documents` rows are CASCADE-deleted and we can no longer
  iterate their `storage_key` values.
  """

  alias Kith.Contacts.{Contact, Document, Photo}
  alias Kith.Imports.Import
  alias Kith.{Repo, Storage}

  import Ecto.Query
  require Logger

  @spec wipe_for_account(account_id :: integer()) :: :ok
  def wipe_for_account(account_id) do
    photo_count = delete_keys(photo_keys(account_id))
    document_count = delete_keys(document_keys(account_id))
    upload_count = delete_keys(import_upload_keys(account_id))

    Logger.info(
      "[Storage.AccountCleanup] deleted #{photo_count} photo file(s) + " <>
        "#{document_count} document file(s) + #{upload_count} import upload(s) " <>
        "for account #{account_id}"
    )

    :ok
  end

  defp photo_keys(account_id) do
    Repo.all(
      from(p in Photo,
        join: c in Contact,
        on: p.contact_id == c.id,
        where: c.account_id == ^account_id,
        select: p.storage_key
      )
    )
  end

  defp document_keys(account_id) do
    Repo.all(
      from(d in Document,
        join: c in Contact,
        on: d.contact_id == c.id,
        where: c.account_id == ^account_id,
        select: d.storage_key
      )
    )
  end

  defp import_upload_keys(account_id) do
    Repo.all(
      from(i in Import,
        where: i.account_id == ^account_id,
        where: not is_nil(i.file_storage_key),
        select: i.file_storage_key
      )
    )
  end

  defp delete_keys(keys) do
    Enum.each(keys, &safe_delete/1)
    length(keys)
  end

  defp safe_delete(nil), do: :ok

  defp safe_delete(key) do
    case Storage.delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Storage.AccountCleanup] failed to delete #{key}: #{inspect(reason)}")
        :ok
    end
  end
end
