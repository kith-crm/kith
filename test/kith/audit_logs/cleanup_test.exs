defmodule Kith.AuditLogs.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.AuditLogs
  alias Kith.AuditLogs.{AuditLog, Cleanup}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      other_account: other.account_id
    }
  end

  test "wipes audit logs for target account only", ctx do
    {:ok, _} =
      AuditLogs.create_audit_log(ctx.target_account, %{
        user_id: nil,
        user_name: "system",
        event: "account_data_reset",
        metadata: %{}
      })

    {:ok, _} =
      AuditLogs.create_audit_log(ctx.other_account, %{
        user_id: nil,
        user_name: "system",
        event: "account_data_reset",
        metadata: %{}
      })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(AuditLog, ctx.target_account) == 0
    assert count_for(AuditLog, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
