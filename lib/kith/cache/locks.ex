defmodule Kith.Cache.Locks do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def with_lock(key, operation) do
    case acquire(key) do
      {:ok, server} ->
        try do
          {:ok, operation.(server)}
        after
          # An operation may outlive this server. Never release its replacement's lock.
          GenServer.cast(server, {:release, key, self()})
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp acquire(key) do
    GenServer.call(__MODULE__, {:acquire, key}, :infinity)
  catch
    :exit, reason -> {:error, {:lock_exit, reason}}
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, key}, from, locks) do
    case Map.fetch(locks, key) do
      :error ->
        {:noreply, grant(locks, key, from, :queue.new())}

      {:ok, {owner, monitor, waiting}} ->
        {:noreply, Map.put(locks, key, {owner, monitor, :queue.in(from, waiting)})}
    end
  end

  @impl true
  def handle_cast({:release, key, owner}, locks) do
    case Map.get(locks, key) do
      {^owner, monitor, waiting} ->
        Process.demonitor(monitor, [:flush])
        {:noreply, advance(locks, key, waiting)}

      _ ->
        {:noreply, locks}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, locks) do
    case Enum.find(locks, fn {_key, {_owner, ref, _waiting}} -> ref == monitor end) do
      {key, {_owner, ^monitor, waiting}} -> {:noreply, advance(locks, key, waiting)}
      nil -> {:noreply, locks}
    end
  end

  defp advance(locks, key, waiting) do
    case :queue.out(waiting) do
      {{:value, from}, rest} -> grant(locks, key, from, rest)
      {:empty, _} -> Map.delete(locks, key)
    end
  end

  defp grant(locks, key, {owner, _tag} = from, waiting) do
    # Monitoring the granted owner also releases a slot for a queued caller
    # that died while waiting. Provider callbacks stay in their caller process.
    monitor = Process.monitor(owner)
    GenServer.reply(from, {:ok, self()})
    Map.put(locks, key, {owner, monitor, waiting})
  end
end
