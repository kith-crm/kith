defmodule Kith.Contacts.Avatar do
  @moduledoc "Creates cached avatar renditions while retaining original timeline photos."
  import Ecto.Query
  alias Kith.Contacts.{AvatarAsset, AvatarProcessor, Contact, Photo}
  alias Kith.DAV.Store
  alias Kith.{Repo, Storage}
  require Logger

  @staged_key {__MODULE__, :staged_files}

  @doc "Wrap the outer write transaction to compensate staged files on rollback."
  def with_cleanup(fun) do
    if Process.get(@staged_key) do
      fun.()
    else
      Process.put(@staged_key, %{created: [], retired: []})

      try do
        result = fun.()
        files = Process.get(@staged_key)

        if match?({:ok, _}, result) do
          Enum.each(files.retired, &delete_unreferenced/1)
        else
          Enum.each(files.created, &delete_created/1)
        end

        result
      rescue
        error ->
          Enum.each(Process.get(@staged_key).created, &delete_created/1)
          reraise error, __STACKTRACE__
      after
        Process.delete(@staged_key)
      end
    end
  end

  def stage_created(key), do: stage(:created, key)
  def stage_retired(nil), do: :ok
  def stage_retired(key), do: stage(:retired, key)

  defp stage(kind, key) do
    case Process.get(@staged_key) do
      nil -> :ok
      files -> Process.put(@staged_key, Map.update!(files, kind, &[key | &1]))
    end

    :ok
  end

  def selected?(%Contact{avatar: key}, %Photo{} = photo),
    do: not is_nil(key) and key in [photo.storage_key, photo.avatar_storage_key]

  def set(%Contact{} = contact, %Photo{} = photo, opts \\ []) do
    if photo.account_id == contact.account_id and photo.contact_id == contact.id do
      with_cleanup(fn -> set_from_source(contact, photo, opts) end)
    else
      {:error, :invalid_photo}
    end
  end

  defp set_from_source(contact, photo, opts) do
    with {:ok, crop} <- normalize_crop(Keyword.get(opts, :crop)),
         {:ok, original} <- Storage.read(photo.storage_key) do
      Store.transaction(contact.account_id, fn -> set_locked(contact, photo, original, crop) end)
    end
  end

  defp set_locked(contact, photo, original, crop) do
    # The account lock precedes both row locks and the revision update.
    contact = Store.lock(contact) || Repo.rollback(:not_found)
    photo = lock_photo(contact, photo.id) || Repo.rollback(:not_found)
    rendition = rendition!(photo, original, crop, AvatarProcessor.signature(original, crop))

    if contact.avatar == rendition do
      contact
    else
      updated = contact |> Ecto.Changeset.change(avatar: rendition) |> Repo.update!()
      Store.touch(contact.account_id, [contact.id])
      Storage.bust_usage_cache(contact.account_id)
      updated
    end
  end

  defp lock_photo(contact, id) do
    Repo.one(
      from p in Photo,
        where:
          p.id == ^id and p.contact_id == ^contact.id and p.account_id == ^contact.account_id,
        lock: "FOR UPDATE"
    )
  end

  defp normalize_crop(nil), do: {:ok, nil}

  defp normalize_crop(crop) when is_map(crop) do
    Enum.reduce_while([:x, :y, :width, :height], {:ok, %{}}, fn key, {:ok, acc} ->
      value = Map.get(crop, key, Map.get(crop, Atom.to_string(key)))

      case crop_integer(value) do
        {:ok, number} -> {:cont, {:ok, Map.put(acc, key, number)}}
        :error -> {:halt, {:error, :invalid_crop}}
      end
    end)
  end

  defp normalize_crop(_crop), do: {:error, :invalid_crop}
  defp crop_integer(value) when is_integer(value), do: {:ok, value}

  defp crop_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp crop_integer(_value), do: :error

  defp rendition!(photo, original, crop, signature) do
    if photo.avatar_signature == signature and is_binary(photo.avatar_storage_key) and
         valid_cached_rendition?(photo) do
      {:ok, cached} = Storage.read(photo.avatar_storage_key)
      register_asset!(photo.account_id, photo.avatar_storage_key, cached)
      photo.avatar_storage_key
    else
      with {:ok, prepared} <- AvatarProcessor.prepare(original, crop),
           :ok <- check_rendition_quota(photo.account_id, byte_size(prepared.binary)),
           key = Storage.generate_key(photo.account_id, "avatars", "avatar.jpg"),
           {:ok, _} <- Storage.upload_binary(prepared.binary, key, content_type: "image/jpeg") do
        stage_created(key)
        register_asset!(photo.account_id, key, prepared.binary)
        stage_retired(photo.avatar_storage_key)

        photo
        |> Ecto.Changeset.change(
          avatar_storage_key: key,
          avatar_file_size: byte_size(prepared.binary),
          avatar_signature: signature,
          avatar_crop: crop,
          avatar_content_hash: hash(prepared.binary)
        )
        |> Repo.update!()

        key
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp valid_cached_rendition?(photo) do
    case Storage.read(photo.avatar_storage_key) do
      {:ok, bytes} -> hash(bytes) == photo.avatar_content_hash
      _ -> false
    end
  end

  defp check_rendition_quota(account_id, bytes) do
    # The original may have been inserted in this transaction after the last
    # cached usage read. Account lock is held; count those bytes before publish.
    Storage.bust_usage_cache(account_id)
    Storage.check_storage_limit(account_id, bytes, fresh: true)
  end

  @doc "True if uploaded PHOTO bytes are the selected rendition (PUT-back is a no-op)."
  def current_bytes?(%{avatar: nil}, _binary), do: false

  def current_bytes?(contact, binary) do
    from(a in AvatarAsset,
      where:
        a.account_id == ^contact.account_id and a.storage_key == ^contact.avatar and
          a.content_hash == ^hash(binary)
    )
    |> Repo.exists?()
  end

  @doc false
  def register_asset!(account_id, key, binary) do
    Repo.insert!(
      %AvatarAsset{
        storage_key: key,
        account_id: account_id,
        byte_size: byte_size(binary),
        content_hash: hash(binary)
      },
      on_conflict: :nothing
    )

    Storage.bust_usage_cache(account_id)
    :ok
  end

  def hash(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  def delete_unreferenced(nil), do: :ok

  def delete_unreferenced(key) do
    # A caller may have an outer transaction not owned by the DAV Store. Keep
    # files until that transaction has committed rather than risk broken refs.
    if not Repo.in_transaction?() and not referenced?(key), do: safe_delete(key)
    :ok
  end

  defp delete_created(key) do
    if not referenced?(key), do: safe_delete(key)
  rescue
    # An enclosing database transaction may still be aborted. Keep the file
    # rather than deleting an object whose committed references we cannot read.
    _ -> :ok
  end

  defp referenced?(key) do
    Repo.exists?(from c in Contact, where: c.avatar == ^key) or
      Repo.exists?(from p in Photo, where: p.storage_key == ^key or p.avatar_storage_key == ^key)
  end

  defp forget_asset(key) do
    Repo.delete_all(from a in AvatarAsset, where: a.storage_key == ^key)
    :ok
  end

  defp safe_delete(key) do
    case Storage.delete(key) do
      :ok -> forget_asset(key)
      {:error, reason} when reason in [:not_found, :enoent] -> forget_asset(key)
      {:error, reason} -> Logger.warning("Avatar file cleanup failed: #{inspect(reason)}")
    end
  end
end
