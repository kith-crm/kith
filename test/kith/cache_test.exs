defmodule Kith.CacheTest do
  use ExUnit.Case, async: false

  alias Kith.Cache
  alias Kith.Cache.Store

  setup do
    key = {:cache_boundary, System.unique_integer([:positive, :monotonic])}

    on_exit(fn ->
      ensure_store_started()
      Cache.delete(key)
    end)

    %{key: key}
  end

  test "misses, cached nil, successful fills and explicit invalidation", %{key: key} do
    assert :miss = Cache.get(key)
    assert :ok = Cache.put(key, nil)
    assert {:ok, nil} = Cache.get(key)
    assert {:ok, nil} = Cache.fetch(key, fn -> flunk("cached nil must be a hit") end)
    assert :ok = Cache.delete(key)
    assert {:ok, 42} = Cache.fetch(key, fn -> {:ok, 42} end)
    assert {:ok, 42} = Cache.get(key)
    assert {:ok, ttl} = Cache.ttl(key)
    assert ttl > :timer.hours(23) and ttl <= :timer.hours(24)
  end

  test "errors are not cached and callback exceptions are not swallowed", %{key: key} do
    assert {:error, :upstream} = Cache.fetch(key, fn -> {:error, :upstream} end)
    assert :miss = Cache.get(key)

    assert_raise RuntimeError, "database failure", fn ->
      Cache.fetch(key, fn -> raise "database failure" end)
    end

    assert :miss = Cache.get(key)
  end

  test "reads do not extend the configured TTL", %{key: key} do
    assert :ok = Cache.put(key, :value, ttl: 300)
    assert {:ok, initial} = Cache.ttl(key)
    Process.sleep(40)
    assert {:ok, :value} = Cache.get(key)
    assert {:ok, remaining} = Cache.ttl(key)
    assert remaining < initial
    Process.sleep(310)
    assert :miss = Cache.get(key)
  end

  test "concurrent misses perform only one expensive fill", %{key: key} do
    parent = self()

    first =
      Task.async(fn ->
        Cache.fetch(key, fn ->
          send(parent, {:fill_started, self()})
          receive do: (:continue -> {:ok, :filled})
        end)
      end)

    assert_receive {:fill_started, filling_pid}

    others =
      for _ <- 1..8,
          do:
            Task.async(fn ->
              Cache.fetch(key, fn -> flunk("concurrent misses must reuse the completed fill") end)
            end)

    send(filling_pid, :continue)
    for task <- [first | others], do: assert(Task.await(task, 5_000) == {:ok, :filled})
  end

  test "an invalidation waits for an older fill and removes its result", %{key: key} do
    parent = self()

    fill =
      Task.async(fn ->
        Cache.fetch(key, fn ->
          send(parent, {:fill_started, self()})
          receive do: (:continue -> {:ok, :old_database_value})
        end)
      end)

    assert_receive {:fill_started, filling_pid}

    deletion =
      Task.async(fn ->
        send(parent, :delete_started)
        result = Cache.delete(key)
        send(parent, :delete_finished)
        result
      end)

    assert_receive :delete_started
    refute_receive :delete_finished, 50
    send(filling_pid, :continue)
    assert {:ok, :old_database_value} = Task.await(fill)
    assert :ok = Task.await(deletion)
    assert :miss = Cache.get(key)
    assert {:ok, :new_database_value} = Cache.fetch(key, fn -> {:ok, :new_database_value} end)
  end

  test "promoting old-generation reads cannot resurrect an invalidated entry", %{key: key} do
    assert :ok = Cache.put(key, :value)
    assert :ok = Store.new_generation()

    readers =
      for _ <- 1..12,
          do:
            Task.async(fn ->
              for _ <- 1..20, do: Cache.get(key)
            end)

    assert :ok = Cache.delete(key)
    for task <- readers, do: Task.await(task, 5_000)
    assert :miss = Cache.get(key)
  end

  test "backend outages run fallback but do not hide its errors", %{key: key} do
    assert :ok = Supervisor.terminate_child(Kith.Supervisor, Store)
    assert {:error, :unavailable} = Cache.get(key)
    assert {:error, :unavailable} = Cache.put(key, :value)
    assert {:error, :unavailable} = Cache.delete(key)
    assert {:ok, :from_database} = Cache.fetch(key, fn -> {:ok, :from_database} end)

    assert_raise RuntimeError, "database failure", fn ->
      Cache.fetch(key, fn -> raise "database failure" end)
    end

    ensure_store_started()
    assert :miss = Cache.get(key)
  end

  test "fills that span a cold backend restart cannot repopulate it", %{key: key} do
    parent = self()

    fill =
      Task.async(fn ->
        Cache.fetch(key, fn ->
          send(parent, {:fill_started, self()})
          receive do: (:continue -> {:ok, :old_value})
        end)
      end)

    assert_receive {:fill_started, filling_pid}
    assert {:ok, %{cache_pid: before_restart}} = Store.info(:server)
    assert :ok = Supervisor.terminate_child(Kith.Supervisor, Store)
    ensure_store_started()
    assert {:ok, %{cache_pid: after_restart}} = Store.info(:server)
    refute before_restart == after_restart
    send(filling_pid, :continue)
    assert {:ok, :old_value} = Task.await(fill)
    assert :miss = Cache.get(key)
    assert {:ok, :new_value} = Cache.fetch(key, fn -> {:ok, :new_value} end)
  end

  test "an epoch mismatch rejects a late write racing the restart", %{key: key} do
    assert {:ok, %{cache_pid: old_identity}} = Store.info(:server)
    assert :ok = Supervisor.terminate_child(Kith.Supervisor, Store)
    ensure_store_started()
    # Simulate a restart after the fill's last identity check, before its put.
    assert :ok = Store.put(key, {:kith_cache_entry, old_identity, :stale}, ttl: 1_000)
    assert :miss = Cache.get(key)
    assert {:ok, :fresh} = Cache.fetch(key, fn -> {:ok, :fresh} end)
  end

  defp ensure_store_started do
    case Supervisor.restart_child(Kith.Supervisor, Store) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end
end
