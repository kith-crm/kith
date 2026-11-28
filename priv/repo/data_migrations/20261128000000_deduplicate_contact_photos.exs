defmodule Kith.Repo.Migrations.DeduplicateContactPhotos do
  use Ecto.Migration
  import Ecto.Query

  alias Kith.{Repo, Storage}
  alias Kith.Contacts.{Avatar, Contact, Photo, Write}
  alias Kith.Imports.ImportRecord

  require Logger

  # Commit each contact independently so a failed storage read can be retried.
  @disable_ddl_transaction true
  @batch_size 100

  def up do
    if Application.fetch_env!(:kith, Storage)[:backend] == :s3 do
      {:ok, _} = Application.ensure_all_started(:req)
      {:ok, _} = Application.ensure_all_started(:ex_aws_s3)
    end

    deduplicate_batch(0)
  end

  def down do
    raise "Deduplicated photo rows cannot be restored by rolling back the migration"
  end

  defp deduplicate_batch(after_id) do
    contacts =
      Repo.all(
        from p in Photo,
          where: p.contact_id > ^after_id,
          group_by: [p.contact_id, p.account_id],
          having: count(p.id) > 1,
          order_by: p.contact_id,
          limit: @batch_size,
          select: {p.contact_id, p.account_id}
      )

    case contacts do
      [] ->
        :ok

      _ ->
        Enum.each(contacts, fn {contact_id, account_id} ->
          {:ok, :ok} =
            Write.transaction(account_id, fn -> deduplicate(contact_id, account_id) end)
        end)

        {last_id, _} = List.last(contacts)
        deduplicate_batch(last_id)
    end
  end

  defp deduplicate(contact_id, account_id) do
    case Repo.get_by(Contact, id: contact_id, account_id: account_id) do
      nil ->
        :ok

      contact ->
        Repo.all(
          from p in Photo,
            where: p.contact_id == ^contact_id and p.account_id == ^account_id,
            order_by: p.id
        )
        |> Enum.reduce(%{}, &group_by_content/2)
        |> Enum.each(fn
          {_hash, [_]} -> :ok
          {hash, photos} -> consolidate(contact, hash, photos)
        end)
    end
  end

  defp group_by_content(photo, groups) do
    if Photo.pending_sync?(photo) do
      groups
    else
      case Storage.read(photo.storage_key) do
        {:ok, bytes} ->
          Map.update(groups, Avatar.hash(bytes), [photo], &[photo | &1])

        {:error, reason} when reason in [:not_found, :enoent] ->
          missing_photo(photo, groups)

        {:error, {:http_error, 404, _}} ->
          missing_photo(photo, groups)

        {:error, reason} ->
          raise "Could not read original for photo #{photo.id}: #{inspect(reason)}"
      end
    end
  end

  defp missing_photo(photo, groups) do
    Logger.warning("Skipping photo #{photo.id} because its original is missing")
    groups
  end

  defp consolidate(contact, hash, photos) do
    survivor =
      Enum.min_by(photos, fn photo ->
        {not Avatar.selected?(contact, photo), photo.id}
      end)

    duplicates = Enum.reject(photos, &(&1.id == survivor.id))
    {:ok, bytes} = Storage.read(survivor.storage_key)

    Enum.each(duplicates, fn photo ->
      unless Storage.read(photo.storage_key) == {:ok, bytes} do
        raise "Could not verify photo #{photo.id} against original #{survivor.id}"
      end
    end)

    ids = Enum.map(duplicates, & &1.id)
    account_id = contact.account_id

    Repo.update_all(
      from(r in ImportRecord,
        where:
          r.account_id == ^account_id and r.local_entity_type == "photo" and
            r.local_entity_id in ^ids
      ),
      set: [local_entity_id: survivor.id]
    )

    # Keep the storage objects so existing links and other references stay valid.
    Repo.delete_all(from p in Photo, where: p.account_id == ^account_id and p.id in ^ids)

    hash_owner? =
      Repo.exists?(
        from p in Photo,
          where:
            p.contact_id == ^contact.id and p.account_id == ^account_id and
              p.id != ^survivor.id and p.content_hash == ^hash
      )

    survivor
    |> Ecto.Changeset.change(
      content_hash: if(hash_owner?, do: survivor.content_hash, else: hash),
      is_private: Enum.any?(photos, & &1.is_private)
    )
    |> Repo.update!()
  end
end
