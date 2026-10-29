defmodule Kith.Storage.Local do
  @moduledoc """
  Local disk storage in an operator-configured directory (default `priv/uploads`).

  The root and its ancestors must be owned by the application/operator, and only
  this application may mutate the tree. Uploaders supply bytes, never filesystem
  entries. Every operation rejects existing symlinks in the root and key path.
  These checks are defense in depth, not an atomic openat/O_NOFOLLOW guarantee
  against another OS process replacing path components concurrently. Do not share
  this tree with an untrusted local writer; use object storage for that model.
  """

  @behaviour Kith.Storage.Backend

  @impl true
  def upload(source_path, storage_key, _opts \\ []) do
    with :ok <- Kith.Storage.validate_storage_key(storage_key),
         {:ok, binary} <- File.read(source_path) do
      upload_binary(binary, storage_key)
    end
  end

  @impl true
  def upload_binary(binary, storage_key, _opts \\ []) do
    with {:ok, dest} <- confined_path(storage_key),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, ^dest} <- confined_path(storage_key),
         :ok <- File.write(dest, binary) do
      {:ok, storage_key}
    end
  end

  @impl true
  def read(storage_key) do
    with {:ok, path} <- confined_path(storage_key), do: File.read(path)
  end

  @impl true
  def delete(storage_key) do
    with {:ok, path} <- confined_path(storage_key) do
      case File.rm(path) do
        {:error, :enoent} -> {:error, :not_found}
        result -> result
      end
    end
  end

  @impl true
  def url(storage_key) do
    with :ok <- Kith.Storage.validate_storage_key(storage_key), do: "/uploads/#{storage_key}"
  end

  @doc "Returns a validated local path, rejecting existing symlink components."
  def confined_path(storage_key) do
    with :ok <- Kith.Storage.validate_storage_key(storage_key) do
      root = upload_root()
      parts = String.split(storage_key, "/")
      paths = Enum.scan(parts, root, &Path.join(&2, &1))

      case Enum.reduce_while([root | paths], :ok, &check_component/2) do
        :ok -> {:ok, List.last(paths)}
        error -> error
      end
    end
  end

  @doc "Returns the validated filesystem path, raising for invalid keys."
  def full_path(storage_key) do
    case confined_path(storage_key) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, "invalid storage path: #{inspect(reason)}"
    end
  end

  defp check_component(path, :ok) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:halt, {:error, :invalid_path}}
      {:ok, _} -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp upload_root do
    Application.get_env(:kith, Kith.Storage, [])
    |> Keyword.get(:path, "priv/uploads")
    |> Path.expand()
  end
end
