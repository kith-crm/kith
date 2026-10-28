defmodule Kith.DAV.ContactDavTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.DAV.{ContactDav, SyncFloor}

  setup do
    %{account_id: user_fixture().account_id}
  end

  test "identity_changeset rejects a second row with the same uid in the account", ctx do
    insert_dav(ctx.account_id, "b1000000-0000-4000-8000-000000000001", "first.vcf")

    assert {:error, cs} =
             insert_dav(ctx.account_id, "b1000000-0000-4000-8000-000000000001", "second.vcf")

    assert "has already been taken" in errors_on(cs).uid
  end

  test "same uid in another account is allowed", ctx do
    assert {:ok, _} =
             insert_dav(ctx.account_id, "b1000000-0000-4000-8000-000000000001", "same.vcf")

    assert {:ok, _} =
             insert_dav(
               user_fixture().account_id,
               "b1000000-0000-4000-8000-000000000001",
               "same.vcf"
             )
  end

  test "same resource_name twice is a :resource_name error", ctx do
    insert_dav(ctx.account_id, "b2000000-0000-4000-8000-000000000002", "same.vcf")

    assert {:error, cs} =
             insert_dav(ctx.account_id, "b3000000-0000-4000-8000-000000000003", "same.vcf")

    assert "has already been taken" in errors_on(cs).resource_name
  end

  test "revision is assigned from the sequence and read back", ctx do
    assert {:ok, first} =
             insert_dav(ctx.account_id, "b2000000-0000-4000-8000-000000000002", "first.vcf")

    assert {:ok, second} =
             insert_dav(ctx.account_id, "b3000000-0000-4000-8000-000000000003", "second.vcf")

    assert is_integer(first.revision)
    assert second.revision > first.revision
    assert first.extras == []
    assert Repo.get!(ContactDav, first.contact_id).revision == first.revision
  end

  test "deleting the contact deletes its row", ctx do
    {:ok, dav} = insert_dav(ctx.account_id, "b2000000-0000-4000-8000-000000000002", "first.vcf")
    contact = Repo.get!(Kith.Contacts.Contact, dav.contact_id) |> Repo.preload(:dav)
    assert contact.dav == dav
    Repo.delete!(contact)
    refute Repo.get(ContactDav, dav.contact_id)
  end

  test "identity requires uid and resource_name", ctx do
    contact = contact_fixture(ctx.account_id)

    cs =
      ContactDav.identity_changeset(
        %ContactDav{contact_id: contact.id, account_id: ctx.account_id},
        %{}
      )

    assert %{uid: ["can't be blank"], resource_name: ["can't be blank"]} = errors_on(cs)
  end

  test "deleting an account cascades its sync floor and identities", ctx do
    {:ok, dav} = insert_dav(ctx.account_id, "b2000000-0000-4000-8000-000000000002", "first.vcf")
    Repo.insert!(%SyncFloor{account_id: ctx.account_id, revision: dav.revision})
    Repo.get!(Kith.Accounts.Account, ctx.account_id) |> Repo.delete!()
    refute Repo.get(ContactDav, dav.contact_id)
    refute Repo.get(SyncFloor, ctx.account_id)
  end

  defp insert_dav(account_id, uid, resource_name) do
    contact = contact_fixture(account_id)

    %ContactDav{contact_id: contact.id, account_id: account_id}
    |> ContactDav.identity_changeset(%{uid: uid, resource_name: resource_name})
    |> Repo.insert()
  end
end
