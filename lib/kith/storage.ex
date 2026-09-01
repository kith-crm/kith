defmodule Kith.Storage do
  @moduledoc """
  Storage abstraction for file uploads (photos, documents, avatars).

  Delegates to a configured backend (`:local` or `:s3`) based on application config:

      config :kith, Kith.Storage, backend: :local | :s3

  All backends implement the `Kith.Storage.Backend` behaviour.
  """

  require Logger

  @type storage_key :: String.t()
  @type upload_opts :: keyword()

  @doc """
  Uploads a file from a local path to storage.

  The `destination_path` should follow the convention:
  `{account_id}/{type}/{uuid_filename}` where type is photos, documents, or avatars.

  Returns `{:ok, storage_key}` or `{:error, reason}`.
  """
  def upload(source_path, destination_path, opts \\ []) do
    with :ok <- validate_storage_key(destination_path) do
      backend().upload(source_path, destination_path, opts)
    end
  end

  @doc """
  Uploads raw binary data to storage.
  Returns `{:ok, storage_key}` or `{:error, reason}`.
  """
  def upload_binary(binary, destination_path, opts \\ []) when is_binary(binary) do
    with :ok <- validate_storage_key(destination_path) do
      backend().upload_binary(binary, destination_path, opts)
    end
  end

  @doc """
  Reads a file from storage by its storage key.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def read(storage_key) do
    backend().read(storage_key)
  end

  @doc """
  Deletes a file from storage by its storage key.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete(storage_key) do
    with :ok <- validate_storage_key(storage_key) do
      backend().delete(storage_key)
    end
  end

  @doc """
  Returns a URL for accessing the stored file.

  For local backend: returns `/uploads/{storage_key}` (served by authenticated controller).
  For S3 backend: returns a presigned URL with 1-hour expiry.
  """
  def url(storage_key) do
    backend().url(storage_key)
  end

  @doc """
  Returns the origin (`scheme://host[:port]`) that `url/1` serves files from,
  for inclusion in the CSP `img-src` directive. Empty string for the `:local`
  backend, which serves from the app's own origin (`'self'`).
  """
  def csp_img_src do
    case backend() do
      Kith.Storage.S3 -> Kith.Storage.S3.csp_img_src()
      _ -> ""
    end
  end

  @doc """
  Returns total storage usage in bytes for an account.
  Queries the sum of file_size across photos and documents tables.
  Results cached in Cachex with 5-minute TTL.
  """
  def usage(account_id) do
    cache_key = {:storage_usage, account_id}

    case Cachex.get(:kith_cache, cache_key) do
      {:ok, nil} ->
        total = compute_usage(account_id)
        Cachex.put(:kith_cache, cache_key, total, ttl: :timer.minutes(5))
        {:ok, total}

      {:ok, cached} ->
        {:ok, cached}
    end
  end

  @doc """
  Invalidates the cached storage usage for an account.
  Call after successful upload or delete.
  """
  def bust_usage_cache(account_id) do
    Cachex.del(:kith_cache, {:storage_usage, account_id})
  end

  @doc "Returns the configured max upload size in bytes."
  def max_upload_size_bytes do
    Application.get_env(:kith, :max_upload_size_kb, 5120) * 1024
  end

  @doc "Returns the configured max storage size in bytes. 0 means unlimited."
  def max_storage_size_bytes do
    Application.get_env(:kith, :max_storage_size_mb, 0) * 1024 * 1024
  end

  @doc """
  Checks whether an upload of `size_bytes` would exceed the account's storage limit.
  Returns `:ok` or `{:error, :storage_limit_exceeded}`.
  """
  def check_storage_limit(account_id, size_bytes) do
    max = max_storage_size_bytes()

    if max == 0 do
      :ok
    else
      {:ok, current} = usage(account_id)

      if current + size_bytes > max do
        {:error, :storage_limit_exceeded}
      else
        :ok
      end
    end
  end

  @doc "Generates a UUID-based storage key for an upload."
  def generate_key(account_id, type, original_filename)
      when type in ~w(photos documents avatars) do
    ext = Path.extname(original_filename)
    uuid = Ecto.UUID.generate()
    "#{account_id}/#{type}/#{uuid}#{ext}"
  end

  @doc "Detects MIME type from file extension."
  def content_type(filename) do
    filename |> Path.extname() |> String.downcase() |> mime_for_ext()
  end

  @mime_types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".pdf" => "application/pdf",
    ".doc" => "application/msword",
    ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".txt" => "text/plain",
    ".csv" => "text/csv"
  }

  defp mime_for_ext(ext), do: Map.get(@mime_types, ext, "application/octet-stream")

  # -- Private --

  defp backend do
    case Application.get_env(:kith, Kith.Storage, []) |> Keyword.get(:backend, :local) do
      :local -> Kith.Storage.Local
      :s3 -> Kith.Storage.S3
      other -> raise "Invalid storage backend: #{inspect(other)}. Must be :local or :s3."
    end
  end

  defp validate_storage_key(key) do
    if String.contains?(key, "..") do
      {:error, :invalid_path}
    else
      :ok
    end
  end

  defp compute_usage(account_id) do
    import Ecto.Query

    photos_sum =
      from(p in "photos",
        where: p.account_id == ^account_id,
        select: coalesce(sum(p.file_size), 0)
      )
      |> Kith.Repo.one()

    documents_sum =
      from(d in "documents",
        where: d.account_id == ^account_id,
        select: coalesce(sum(d.file_size), 0)
      )
      |> Kith.Repo.one()

    photos_sum + documents_sum
  end
end
