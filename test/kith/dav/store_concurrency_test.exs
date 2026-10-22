defmodule Kith.DAV.StoreConcurrencyTest do
  use Kith.DataCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Repo, DAV.Store}
  import Ecto.Query

  setup do
    account = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture().account_id end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^account)
      end)
    end)

    %{account: account}
  end

  test "a revision drawn before a token is issued but committed after is newer than that token",
       %{account: account} do
    [x, y] =
      Sandbox.unboxed_run(Repo, fn ->
        contacts = for _ <- 1..2, do: Kith.ContactsFixtures.contact_fixture(account)
        Store.ensure_rows(account)
        contacts
      end)

    parent = self()

    a =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Store.touch(account, [x.id])
            send(parent, :locked)

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000

    b =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, pid})
          Store.touch(account, [y.id])
        end)
      end)

    assert_receive {:backend, pid}, 5_000
    Sandbox.unboxed_run(Repo, fn -> wait_for_lock(pid, 250) end)
    assert Task.yield(b, 0) == nil
    token = Sandbox.unboxed_run(Repo, fn -> Store.sync_state(account).token end)
    send(a.pid, :commit)
    assert {:ok, :ok} = Task.await(a)
    assert :ok = Task.await(b)
    changed = Sandbox.unboxed_run(Repo, fn -> Store.list_changed_since(account, token) end)
    assert Enum.sort(Enum.map(changed, & &1.id)) == Enum.sort([x.id, y.id])
  end

  defp wait_for_lock(pid, tries) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid])

    cond do
      waiting ->
        :ok

      tries == 0 ->
        flunk("writer never waited on the account lock")

      true ->
        Process.sleep(20)
        wait_for_lock(pid, tries - 1)
    end
  end
end
