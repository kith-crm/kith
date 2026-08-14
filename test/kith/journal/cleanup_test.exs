defmodule Kith.Journal.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Journal
  alias Kith.Journal.{Cleanup, Entry}
  alias Kith.Repo

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

  test "wipes journal entries for target account only", ctx do
    {:ok, _} =
      Journal.create_entry(ctx.target_account, ctx.target_user, %{
        "content" => "target",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _} =
      Journal.create_entry(ctx.other_account, ctx.other_user, %{
        "content" => "other",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Entry, ctx.target_account) == 0
    assert count_for(Entry, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
