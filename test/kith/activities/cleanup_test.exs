defmodule Kith.Activities.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Activities.{Activity, Cleanup}
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

  test "wipes activities for target account only", ctx do
    Repo.insert!(%Activity{
      account_id: ctx.target_account,
      title: "target activity",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%Activity{
      account_id: ctx.other_account,
      title: "other activity",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Activity, ctx.target_account) == 0
    assert count_for(Activity, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
