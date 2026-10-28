defmodule Kith.DAV.StoreTest do
  use Kith.DataCase, async: true
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  alias Kith.DAV.{Store, ContactDav}

  setup do
    account = user_fixture().account_id
    x = contact_fixture(account)
    y = contact_fixture(account, %{is_archived: true})
    z = contact_fixture(account, %{deleted_at: DateTime.utc_now(:second)})
    %{account: account, contacts: [x, y, z]}
  end

  test "ensure_rows creates one row per contact, uid is a UUID, resource_name is uid.vcf", c do
    assert :ok = Store.ensure_rows(c.account)

    for contact <- c.contacts do
      dav = Repo.get!(ContactDav, contact.id)
      assert {:ok, _} = Ecto.UUID.cast(dav.uid)
      assert dav.resource_name == dav.uid <> ".vcf"
    end
  end

  test "ensure_rows is idempotent and keeps existing rows", c do
    Store.ensure_rows(c.account)
    before = Repo.all(ContactDav)
    Store.ensure_rows(c.account)
    assert Repo.all(ContactDav) == before
  end

  test "touch raises revision of only the given contacts", c do
    Store.ensure_rows(c.account)
    [x, y, _] = c.contacts
    before = Repo.get!(ContactDav, x.id).revision
    other = Repo.get!(ContactDav, y.id)
    assert :ok = Store.touch(c.account, [x.id])
    assert Repo.get!(ContactDav, x.id).revision > before
    assert Repo.get!(ContactDav, y.id) == other
    assert :ok = Store.touch(c.account, [])
  end

  test "touch accepts a query of contact ids", c do
    Store.ensure_rows(c.account)
    [x | _] = c.contacts
    before = Store.sync_state(c.account).token

    Store.touch(
      c.account,
      from(contact in Kith.Contacts.Contact, where: contact.id == ^x.id, select: contact.id)
    )

    assert Repo.get!(ContactDav, x.id).revision > before
  end

  test "sync_state token is max of revisions and floor", c do
    assert Store.sync_state(c.account) == %{token: 0, floor: 0}
    Store.ensure_rows(c.account)

    assert Store.sync_state(c.account).token ==
             Enum.max(Enum.map(Repo.all(ContactDav), & &1.revision))

    Store.record_hard_delete(c.account)
    assert %{token: n, floor: n} = Store.sync_state(c.account)
  end

  test "record_hard_delete moves floor above every existing revision", c do
    Store.ensure_rows(c.account)
    before = Store.sync_state(c.account).token
    assert :ok = Store.record_hard_delete(c.account)
    assert Store.sync_state(c.account).floor > before
  end

  test "list_changed_since includes trashed and archived contacts", c do
    Store.ensure_rows(c.account)

    assert MapSet.new(Enum.map(Store.list_changed_since(c.account, 0), & &1.id)) ==
             MapSet.new(Enum.map(c.contacts, & &1.id))

    assert Store.list_changed_since(c.account, Store.sync_state(c.account).token) == []
  end

  test "get_related resolves equivalent UUID forms and rejects ambiguous duplicates", c do
    Store.ensure_rows(c.account)
    [x, y | _] = c.contacts
    x = Repo.get!(ContactDav, x.id)
    assert Store.get_related(c.account, "URN:UUID:" <> String.upcase(x.uid)).id == x.contact_id
    assert Store.get_related(c.account, x.uid).id == x.contact_id

    assert {:error, _} =
             Store.put_identity(Repo.get!(ContactDav, y.id), %{uid: "urn:uuid:" <> x.uid})

    assert Store.get_related(c.account, "not-a-uuid") == nil
  end

  test "ensure_rows and floors are isolated and later touches overtake the floor", c do
    other = user_fixture().account_id
    foreign = contact_fixture(other)
    Store.ensure_rows(c.account)
    refute Repo.get(ContactDav, foreign.id)
    assert Store.sync_state(other) == %{token: 0, floor: 0}
    Store.record_hard_delete(c.account)
    floor = Store.sync_state(c.account).floor
    Store.record_hard_delete(c.account)
    assert Store.sync_state(c.account).floor > floor
    floor = Store.sync_state(c.account).floor
    Store.ensure_rows(other)
    foreign_dav = Repo.get!(ContactDav, foreign.id)
    foreign_state = Store.sync_state(other)
    [x | _] = c.contacts
    Store.touch(c.account, from(contact in Kith.Contacts.Contact, select: contact.id))
    assert Store.sync_state(c.account).token > floor
    assert Store.sync_state(c.account).floor == floor
    assert Store.sync_state(other) == foreign_state
    assert Repo.get!(ContactDav, foreign.id) == foreign_dav
    assert Repo.get!(ContactDav, x.id).revision > floor
  end

  test "identity conflicts return changesets and hidden contacts keep their lookups", c do
    Store.ensure_rows(c.account)
    [x, y, z] = Enum.map(c.contacts, &Repo.preload(&1, :dav))
    assert {:error, changeset} = Store.put_identity(y.dav, %{uid: x.dav.uid})
    assert errors_on(changeset).uid == ["has already been taken"]
    assert {:error, changeset} = Store.put_identity(y.dav, %{resource_name: x.dav.resource_name})
    assert errors_on(changeset).resource_name == ["has already been taken"]

    for contact <- [y, z] do
      assert Store.get_by_resource_name(c.account, contact.dav.resource_name).id == contact.id
      assert Store.get_by_uid(c.account, contact.dav.uid).id == contact.id
    end

    assert Store.get_by_resource_names(c.account, []) == %{}
    {:ok, dav} = Store.put_identity(x.dav, %{resource_name: "a b.vcf"})
    assert Store.href(%{x | dav: dav}) == "/dav/addressbooks/default/a%20b.vcf"
    Repo.delete!(z)
    assert {:ok, nil} = Repo.transaction(fn -> Store.lock(z) end)
  end

  test "lookups, mutations and locks respect account and load identities", c do
    Store.ensure_rows(c.account)
    [x | _] = c.contacts
    dav = Repo.get!(ContactDav, x.id)
    other = user_fixture().account_id
    Store.touch(other, [x.id])
    assert Repo.get!(ContactDav, x.id) == dav
    assert Store.get_by_uid(other, dav.uid) == nil
    assert Store.get_by_resource_name(other, dav.resource_name) == nil
    assert Store.get_by_resource_names(other, [dav.resource_name]) == %{}
    assert Store.list_changed_since(other, 0) == []
    assert Store.get_related(other, dav.uid) == nil
    assert Store.get_by_uid(c.account, dav.uid).dav == dav

    assert Store.get_by_resource_names(c.account, [dav.resource_name])[dav.resource_name].id ==
             x.id

    assert {:ok, locked} = Repo.transaction(fn -> Store.lock(x) end)
    assert locked.dav == dav
    assert Store.lock(%{x | account_id: other}) == nil
    assert {:ok, updated} = Store.put_extras(dav, ["X-TEST:yes"])
    assert updated.extras == ["X-TEST:yes"]
    assert Store.href(locked) == "/dav/addressbooks/default/" <> dav.resource_name
  end
end
