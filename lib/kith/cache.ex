defmodule Kith.Cache do
  @moduledoc """
  Local cache boundary. Reads return `{:ok, value}`, `:miss`, or `{:error, reason}`;
  mutations return `:ok` or an error. `fetch/3` callbacks return an ok/error tuple,
  and only successful values are cached. Cache outages still run the callback.

  TTLs are milliseconds and default to 24 hours. Reads never renew expiration.
  All access uses a queued node-local per-key lock, including reads that can
  promote an entry between Nebulex generations. Invalidation therefore cannot be undone by
  an earlier fill or promotion. Values carry the backend's identity so a fill
  spanning a backend restart cannot expose a stale value through the
  replacement cache.
  """

  alias Kith.Cache.{Locks, Store}

  require Logger

  @default_ttl :timer.hours(24)
  @entry_tag :kith_cache_entry

  def get(key) do
    locked(key, fn ->
      with {:ok, identity} <- identity(), do: read(key, identity)
    end)
  end

  def put(key, value, opts \\ []) do
    locked(key, fn ->
      with {:ok, identity} <- identity(), do: write(key, value, identity, opts)
    end)
  end

  def delete(key) do
    result = delete_local(key)
    invalidate_peers(key)
    result
  end

  @doc false
  def delete_local(key), do: locked(key, fn -> backend(fn -> Store.delete(key) end) end)

  @doc "Returns the remaining TTL in milliseconds, without extending it."
  def ttl(key), do: locked(key, fn -> remaining_ttl(key) end)

  def fetch(key, fallback, opts \\ []) when is_function(fallback, 0) do
    locked(key, fn -> fetch_unlocked(key, fallback, opts) end)
  end

  defp remaining_ttl(key) do
    with {:ok, identity} <- identity(),
         {:ok, _value} <- read(key, identity) do
      backend(fn -> Store.ttl(key) end)
    end
  end

  defp fetch_unlocked(key, fallback, opts) do
    case identity() do
      {:ok, identity} -> read_or_load(key, fallback, identity, opts)
      {:error, _reason} -> fallback.()
    end
  end

  defp read_or_load(key, fallback, identity, opts) do
    case read(key, identity) do
      {:ok, value} -> {:ok, value}
      _miss_or_cache_error -> load(key, fallback, identity, opts)
    end
  end

  defp load(key, fallback, identity, opts) do
    case fallback.() do
      {:ok, value} = result ->
        # Keep callback errors/exceptions outside the cache error boundary.
        if identity() == {:ok, identity}, do: write(key, value, identity, opts)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp read(key, identity) do
    case backend(fn -> Store.fetch(key) end) do
      {:ok, {@entry_tag, ^identity, value}} -> {:ok, value}
      {:ok, _old_backend_entry} -> :miss
      {:error, %Nebulex.KeyError{reason: reason}} when reason in [:not_found, :expired] -> :miss
      {:error, _reason} = error -> error
    end
  end

  defp write(key, value, identity, opts) do
    backend(fn ->
      Store.put(key, {@entry_tag, identity, value}, Keyword.put_new(opts, :ttl, @default_ttl))
    end)
  end

  defp identity do
    with {:ok, %{cache_pid: pid}} when is_pid(pid) <- backend(fn -> Store.info(:server) end),
         do: {:ok, pid}
  end

  defp locked(key, operation) do
    Locks.with_lock(key, operation)
  end

  defp invalidate_peers(key) do
    # Release our local key lock before contacting peers so simultaneous
    # invalidations cannot deadlock by holding one another's locks. Each peer
    # serializes deletion against its own pending fills before acknowledging.
    {replies, unavailable} = :rpc.multicall(Node.list(), __MODULE__, :delete_local, [key], 5000)

    if unavailable != [] or Enum.any?(replies, &(&1 != :ok)) do
      Logger.warning("Cache invalidation could not reach every connected peer")
    end

    :ok
  end

  defp backend(operation) do
    operation.()
  rescue
    _error in Nebulex.CacheNotFoundError -> {:error, :unavailable}
    error in Nebulex.Error -> {:error, error}
  catch
    :exit, reason -> {:error, {:cache_exit, reason}}
  end
end
