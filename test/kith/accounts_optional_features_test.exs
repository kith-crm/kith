defmodule Kith.AccountsOptionalFeaturesTest do
  use Kith.DataCase, async: false

  import Kith.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Accounts, AuditLogs, Repo}

  test "validates keys and booleans, authorizes current roles, and audits effective changes once" do
    admin = user_fixture()
    viewer = user_fixture(%{role: "viewer"})
    account = Accounts.get_account!(admin.account_id)
    {:ok, _} = Accounts.update_account(account, %{feature_flags: %{"immich" => true}})
    assert {:error, :forbidden} = Accounts.set_optional_feature(viewer, "journal", true)
    assert {:error, :invalid_feature} = Accounts.set_optional_feature(admin, "immich", false)
    assert {:error, :invalid_feature} = Accounts.set_optional_feature(admin, "journal", "true")
    assert {:ok, _} = Accounts.set_optional_feature(admin, "journal", false)
    assert {[], _} = AuditLogs.list_audit_logs(admin.account_id)

    assert {:ok, _} = Accounts.set_optional_feature(admin, "journal", true)
    assert {:ok, _} = Accounts.set_optional_feature(admin, "journal", true)

    assert {[%{user_id: actor_id, metadata: %{"feature" => "journal", "enabled" => true}}], _} =
             AuditLogs.list_audit_logs(admin.account_id)

    assert actor_id == admin.id
    assert {:ok, account} = Accounts.set_optional_feature(admin, "journal", false)
    assert account.feature_flags == %{"immich" => true, "journal" => false}
    refute Accounts.module_enabled?(Accounts.get_account!(viewer.account_id), "journal")
  end

  test "concurrent writers using separate connections preserve both switches" do
    admin = Sandbox.unboxed_run(Repo, &user_fixture/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        admin.account_id |> Accounts.get_account!() |> Accounts.delete_account()
      end)
    end)

    tasks =
      for key <- ["journal", "calls"] do
        Task.async(fn ->
          receive do
            :start ->
              Sandbox.unboxed_run(Repo, fn -> Accounts.set_optional_feature(admin, key, true) end)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :start))
    assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks)

    account = Sandbox.unboxed_run(Repo, fn -> Accounts.get_account!(admin.account_id) end)
    assert %{"journal" => true, "calls" => true} = account.feature_flags
  end
end
