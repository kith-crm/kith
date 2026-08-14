defmodule Kith.Imports.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Imports
  alias Kith.Imports.{Cleanup, Import, ImportRecord}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

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

  test "wipes imports + import_records for target account; leaves other account untouched", ctx do
    target_import =
      import_fixture(ctx.target_account, ctx.target_user, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    other_import =
      import_fixture(ctx.other_account, ctx.other_user, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    {:ok, _} = Imports.record_imported_entity(target_import, "contact", "1", "contact", 999)
    {:ok, _} = Imports.record_imported_entity(other_import, "contact", "1", "contact", 999)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Import, ctx.target_account) == 0
    assert count_for(ImportRecord, ctx.target_account) == 0

    # Control account untouched
    assert count_for(Import, ctx.other_account) == 1
    assert count_for(ImportRecord, ctx.other_account) == 1
  end

  test "is idempotent on an account with no import data", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
