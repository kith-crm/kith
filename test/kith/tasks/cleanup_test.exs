defmodule Kith.Tasks.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Repo
  alias Kith.Tasks
  alias Kith.Tasks.{Cleanup, Task}

  import Ecto.Query
  import Kith.AccountsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      target_user: target.id,
      other_account: other.account_id,
      other_user: other.id
    }
  end

  test "wipes tasks for target account only", ctx do
    {:ok, _} = Tasks.create_task(ctx.target_account, ctx.target_user, %{"title" => "target task"})
    {:ok, _} = Tasks.create_task(ctx.other_account, ctx.other_user, %{"title" => "other task"})

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Task, ctx.target_account) == 0
    assert count_for(Task, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
