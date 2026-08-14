defmodule Kith.Contacts.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts.{Cleanup, Contact, Tag}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    %{
      target_account: target.account_id,
      other_account: other.account_id
    }
  end

  test "hard-deletes contacts + tags for target account; leaves other account untouched", ctx do
    contact_fixture(ctx.target_account)
    contact_fixture(ctx.target_account)
    contact_fixture(ctx.other_account)

    Repo.insert!(%Tag{account_id: ctx.target_account, name: "target-tag"})
    Repo.insert!(%Tag{account_id: ctx.other_account, name: "other-tag"})

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Contact, ctx.target_account) == 0
    assert count_for(Tag, ctx.target_account) == 0

    assert count_for(Contact, ctx.other_account) == 1
    assert count_for(Tag, ctx.other_account) == 1
  end

  test "ignores soft-deleted vs not — hard-deletes both", ctx do
    active = contact_fixture(ctx.target_account)
    soft = contact_fixture(ctx.target_account)

    soft
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    refute Repo.get(Contact, active.id)
    refute Repo.get(Contact, soft.id)
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
