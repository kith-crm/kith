defmodule Kith.Workers.ImportApiKeySweepLockTest do
  # Separate connections are needed to exercise the import lock.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Imports, Repo}
  alias Kith.Imports.Import
  alias Kith.Workers.{ImportApiKeySweepWorker, MonicaPhotoSyncWorker}

  test "cleanup waits for a concurrently inserted follow-up to become visible" do
    import =
      unboxed(fn ->
        user = user_fixture()

        import =
          import_fixture(user.account_id, user.id, %{
            source: "monica_api",
            api_key_encrypted: "test-key"
          })

        expired = DateTime.add(DateTime.utc_now(:second), -1, :hour)

        Repo.update_all(from(i in Import, where: i.id == ^import.id),
          set: [api_key_cleanup_eligible_at: expired]
        )

        import
      end)

    args = %{"import_id" => import.id}

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(j in Oban.Job, where: j.args == ^args))
        Repo.delete_all(from(a in Kith.Accounts.Account, where: a.id == ^import.account_id))
      end)
    end)

    parent = self()

    enqueue =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transact(fn ->
            assert {:ok, _} = Imports.enqueue_monica_followup(MonicaPhotoSyncWorker, args)
            send(parent, :followup_inserted)

            receive do
              :commit -> {:ok, :committed}
            after
              5_000 -> raise "follow-up transaction was not released"
            end
          end)
        end)
      end)

    try do
      assert_receive :followup_inserted, 5_000

      error =
        assert_raise Postgrex.Error, fn ->
          unboxed(fn ->
            Repo.transact(fn ->
              Repo.query!("SET LOCAL lock_timeout = '200ms'")
              {:ok, perform_job(ImportApiKeySweepWorker, args)}
            end)
          end)
        end

      assert error.postgres.code == :lock_not_available
    after
      send(enqueue.pid, :commit)
    end

    assert {:ok, :committed} = Task.await(enqueue)

    unboxed(fn ->
      assert {:snooze, _} = perform_job(ImportApiKeySweepWorker, args)
      assert Imports.get_import!(import.id).api_key_encrypted == "test-key"
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
