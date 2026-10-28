defmodule Kith.Workers.ImmichSyncWorkerTest do
  use Kith.DataCase, async: true

  alias Kith.Workers.ImmichSyncWorker
  alias Kith.Accounts.Account
  alias Kith.Repo

  import Kith.AccountsFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    user = user_fixture()
    account = Repo.get!(Account, user.account_id)
    %{account: account, user: user}
  end

  describe "perform/1" do
    test "skips account when immich_status is error", %{account: account} do
      {:ok, account} =
        account
        |> Account.immich_sync_changeset(%{immich_status: "error"})
        |> Repo.update()

      job = %Oban.Job{args: %{"account_id" => account.id}}
      assert :ok = ImmichSyncWorker.perform(job)
    end

    test "skips account when immich_enabled is false", %{account: account} do
      job = %Oban.Job{args: %{"account_id" => account.id}}
      assert :ok = ImmichSyncWorker.perform(job)
    end

    test "skips account when credentials are missing", %{account: account} do
      {:ok, account} =
        account
        |> Account.immich_changeset(%{immich_enabled: true})
        |> Repo.update()

      job = %Oban.Job{args: %{"account_id" => account.id}}
      assert :ok = ImmichSyncWorker.perform(job)
    end
  end

  describe "circuit breaker" do
    test "increments failure counter on sync failure", %{account: account} do
      Req.Test.expect(Kith.Immich.Client, &Req.Test.transport_error(&1, :econnrefused))

      {:ok, account} =
        account
        |> Account.immich_changeset(%{
          immich_enabled: true,
          immich_base_url: "https://immich.test",
          immich_api_key: "fake-key"
        })
        |> Repo.update()

      job = %Oban.Job{args: %{"account_id" => account.id}}
      assert {:error, :network_error} = ImmichSyncWorker.perform(job)

      reloaded = Repo.get!(Account, account.id)
      assert reloaded.immich_consecutive_failures == 1
      assert reloaded.immich_status != "error"
    end

    test "opens after three failures and makes no further request", %{account: account} do
      account
      |> Account.immich_changeset(%{
        immich_enabled: true,
        immich_base_url: "https://immich.test",
        immich_api_key: "fake-key"
      })
      |> Repo.update!()

      Req.Test.expect(Kith.Immich.Client, 3, &Req.Test.transport_error(&1, :econnrefused))
      job = %Oban.Job{args: %{"account_id" => account.id}}

      for expected <- 1..3 do
        assert {:error, :network_error} = ImmichSyncWorker.perform(job)
        assert Repo.reload!(account).immich_consecutive_failures == expected
      end

      assert Repo.reload!(account).immich_status == "error"
      assert :ok = ImmichSyncWorker.perform(job)
      assert Repo.reload!(account).immich_consecutive_failures == 3
    end

    test "a successful sync resets previous failures", %{account: account} do
      account
      |> Account.immich_changeset(%{
        immich_enabled: true,
        immich_base_url: "https://immich.test",
        immich_api_key: "fake-key"
      })
      |> Ecto.Changeset.change(immich_consecutive_failures: 2)
      |> Repo.update!()

      Req.Test.expect(Kith.Immich.Client, &Req.Test.json(&1, %{"people" => []}))
      assert :ok = ImmichSyncWorker.perform(%Oban.Job{args: %{"account_id" => account.id}})
      assert %{immich_consecutive_failures: 0, immich_status: "ok"} = Repo.reload!(account)
    end
  end
end
