defmodule Kith.DAV.TouchCoverageTest do
  use Kith.DataCase, async: true
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  alias Kith.Contacts
  alias Kith.DAV.{Store, ContactDav}

  setup do
    user = user_fixture()
    account = user.account_id
    a = contact_fixture(account)
    b = contact_fixture(account)
    {:ok, gender} = Contacts.create_gender(account, %{name: "Custom"})

    {:ok, rt} =
      Contacts.create_relationship_type(account, %{name: "Friend", reverse_name: "Friend"})

    {:ok, cft} =
      Contacts.create_contact_field_type(account, %{
        name: "Email",
        protocol: "mailto",
        vcard_label: "EMAIL"
      })

    {:ok, a} = Contacts.update_contact(a, %{gender_id: gender.id})
    address = address_fixture(a)
    field = contact_field_fixture(a, cft.id)
    {:ok, tag} = Contacts.create_tag(account, %{name: "Tag"})
    Contacts.tag_contact(a, tag)
    relationship = relationship_fixture(b, a, rt.id)
    photo = photo_fixture(a)
    Store.ensure_rows(account)

    %{
      user: user,
      account: account,
      a: a,
      b: b,
      gender: gender,
      rt: rt,
      cft: cft,
      address: address,
      field: field,
      tag: tag,
      relationship: relationship,
      photo: photo
    }
  end

  for {label, operation, expected} <- [
        {"update_contact", :update_contact, :both},
        {"soft_delete_contact", :soft_delete_contact, :a},
        {"restore_contact", :restore_contact, :a},
        {"archive_contact", :archive_contact, :a},
        {"unarchive_contact", :unarchive_contact, :a},
        {"create_address", :create_address, :a},
        {"update_address", :update_address, :a},
        {"delete_address", :delete_address, :a},
        {"create_contact_field", :create_contact_field, :a},
        {"update_contact_field", :update_contact_field, :a},
        {"delete_contact_field", :delete_contact_field, :a},
        {"tag_contact", :tag_contact, :a},
        {"untag_contact", :untag_contact, :a},
        {"create_relationship", :create_relationship, :a},
        {"delete_relationship", :delete_relationship, :b},
        {"create_photo", :create_photo, :a},
        {"delete_photo", :delete_photo, :a},
        {"set_avatar", :set_avatar, :a},
        {"clear_avatar", :clear_avatar, :a},
        {"update_tag", :update_tag, :a},
        {"rename_tag", :rename_tag, :a},
        {"delete_tag", :delete_tag, :a},
        {"delete_tag_with_removal", :delete_tag_with_removal, :a},
        {"merge_tags", :merge_tags, :a},
        {"update_gender", :update_gender, :a},
        {"delete_gender refuses in-use records", :delete_gender, :none},
        {"update_relationship_type", :update_relationship_type, :b},
        {"delete_relationship_type refuses in-use records", :delete_relationship_type, :none},
        {"update_contact_field_type", :update_contact_field_type, :a},
        {"delete_contact_field_type refuses in-use records", :delete_contact_field_type, :none},
        {"DisplayNameRecomputeWorker touches recomputed contacts", :display_worker, :both},
        {"failed update leaves revisions unchanged", :failed_update, :none}
      ] do
    test "#{label} touches exactly affected contacts", c do
      before = revisions(c)
      run_operation(unquote(operation), c)

      expected =
        case unquote(expected) do
          :a -> [c.a.id]
          :b -> [c.b.id]
          :both -> [c.a.id, c.b.id]
          :none -> []
        end

      for {id, revision} <- revisions(c) do
        if id in expected, do: assert(revision > before[id]), else: assert(revision == before[id])
      end
    end
  end

  defp revisions(c), do: Map.new([c.a, c.b], &{&1.id, Repo.get!(ContactDav, &1.id).revision})

  defp run_operation(:update_contact, c),
    do: Contacts.update_contact(c.a, %{first_name: "Renamed"})

  defp run_operation(op, c)
       when op in [
              :soft_delete_contact,
              :restore_contact,
              :archive_contact,
              :unarchive_contact,
              :clear_avatar
            ],
       do: apply(Contacts, op, [c.a])

  defp run_operation(:create_address, c), do: address_fixture(c.a)

  defp run_operation(:update_address, c),
    do: Contacts.update_address(c.address, %{city: "New city"})

  defp run_operation(:delete_address, c), do: Contacts.delete_address(c.address)
  defp run_operation(:create_contact_field, c), do: contact_field_fixture(c.a, c.cft.id)

  defp run_operation(:update_contact_field, c),
    do: Contacts.update_contact_field(c.field, %{value: "new@example.com"})

  defp run_operation(:delete_contact_field, c), do: Contacts.delete_contact_field(c.field)

  defp run_operation(:tag_contact, c) do
    {:ok, tag} = Contacts.create_tag(c.account, %{name: "New"})
    Contacts.tag_contact(c.a, tag)
  end

  defp run_operation(:untag_contact, c), do: Contacts.untag_contact(c.a, c.tag)
  defp run_operation(:create_relationship, c), do: relationship_fixture(c.a, c.b, c.rt.id)
  defp run_operation(:delete_relationship, c), do: Contacts.delete_relationship(c.relationship)
  defp run_operation(:create_photo, c), do: photo_fixture(c.a)
  defp run_operation(:delete_photo, c), do: Contacts.delete_photo(c.photo)
  defp run_operation(:set_avatar, c), do: Contacts.set_avatar(c.a, c.photo)
  defp run_operation(:rename_tag, c), do: Contacts.rename_tag(c.tag, "Renamed")
  defp run_operation(:update_tag, c), do: Contacts.update_tag(c.tag, %{name: "New"})

  defp run_operation(op, c) when op in [:delete_tag, :delete_tag_with_removal],
    do: apply(Contacts, op, [c.tag])

  defp run_operation(:merge_tags, c) do
    {:ok, target} = Contacts.create_tag(c.account, %{name: "Target"})
    Contacts.merge_tags(c.account, c.tag, target)
  end

  defp run_operation(:update_gender, c), do: Contacts.update_gender(c.gender, %{name: "New"})

  defp run_operation(:delete_gender, c),
    do: assert({:error, :in_use} = Contacts.delete_gender(c.gender))

  defp run_operation(:update_relationship_type, c),
    do: Contacts.update_relationship_type(c.rt, %{name: "New"})

  defp run_operation(:delete_relationship_type, c),
    do: assert({:error, :in_use} = Contacts.delete_relationship_type(c.rt))

  defp run_operation(:update_contact_field_type, c),
    do: Contacts.update_contact_field_type(c.cft, %{name: "New"})

  defp run_operation(:delete_contact_field_type, c),
    do: assert({:error, :in_use} = Contacts.delete_contact_field_type(c.cft))

  defp run_operation(:display_worker, c),
    do:
      Kith.Workers.DisplayNameRecomputeWorker.perform(%Oban.Job{
        args: %{"account_id" => c.account, "display_name_format" => "last_first"}
      })

  defp run_operation(:failed_update, c),
    do: assert({:error, _} = Contacts.update_contact(c.a, %{first_name: "", last_name: ""}))

  for operation <- [:hard_delete_contact, :empty_trash, :purge] do
    test "#{operation} moves floor atomically with removal", c do
      old = DateTime.add(DateTime.utc_now(:second), -40 * 86_400, :second)
      a = c.a |> Ecto.Changeset.change(deleted_at: old) |> Repo.update!()
      before = Store.sync_state(c.account)
      owner_before = Repo.get!(ContactDav, c.b.id).revision
      card_before = Kith.DAV.VCardAdapter.contact_to_vcard(c.b)

      case unquote(operation) do
        :hard_delete_contact -> assert {:ok, _} = Contacts.hard_delete_contact(a)
        :empty_trash -> assert {:ok, 1} = Contacts.empty_trash(c.account)
        :purge -> assert :ok = Kith.Workers.ContactPurgeWorker.perform(%Oban.Job{})
      end

      assert Repo.get(ContactDav, a.id) == nil
      assert Store.sync_state(c.account).floor > before.token
      assert Repo.get!(ContactDav, c.b.id).revision > owner_before
      assert Kith.DAV.VCardAdapter.contact_to_vcard(c.b) != card_before
      assert Contacts.list_relationships(c.b.id) == []
    end
  end

  test "public tag rename appears in incremental sync and isolates other contacts and accounts",
       c do
    other = contact_fixture(user_fixture().account_id)
    Store.ensure_rows(other.account_id)
    foreign = Repo.get!(ContactDav, other.id)
    before = Store.sync_state(c.account).token
    assert {:ok, renamed} = Contacts.rename_tag(c.tag, "Renamed")
    assert renamed.name == "Renamed"
    assert Enum.map(Store.list_changed_since(c.account, before), & &1.id) == [c.a.id]
    assert Repo.get!(ContactDav, other.id) == foreign
  end

  test "merge_contacts touches survivor and loser", c do
    before = revisions(c)
    assert {:ok, _} = Contacts.merge_contacts(c.a.id, c.b.id)
    for {id, revision} <- revisions(c), do: assert(revision > before[id])
  end

  test "PhoneRenormalizeWorker touches contacts whose phone changed", c do
    {:ok, phone_type} =
      Contacts.create_contact_field_type(c.account, %{
        name: "Phone",
        protocol: "tel",
        vcard_label: "TEL"
      })

    {:ok, _} =
      Contacts.create_contact_field(
        c.a,
        %{contact_field_type_id: phone_type.id, value: "(202) 555-0123"},
        normalize: false
      )

    before = revisions(c)

    assert :ok =
             Kith.Workers.PhoneRenormalizeWorker.perform(%Oban.Job{
               args: %{"account_id" => c.account}
             })

    assert Repo.get!(ContactDav, c.a.id).revision > before[c.a.id]
    assert Repo.get!(ContactDav, c.b.id).revision == before[c.b.id]
  end

  test "POST /api/contacts/:id/contact_fields touches the contact", c do
    {token, _} = Kith.Accounts.generate_api_token(c.user)
    before = revisions(c)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

    conn =
      Phoenix.ConnTest.dispatch(
        conn,
        KithWeb.Endpoint,
        :post,
        "/api/contacts/#{c.a.id}/contact_fields",
        %{"contact_field" => %{"contact_field_type_id" => c.cft.id, "value" => "api@example.com"}}
      )

    assert conn.status == 201
    assert Repo.get!(ContactDav, c.a.id).revision > before[c.a.id]
    assert Repo.get!(ContactDav, c.b.id).revision == before[c.b.id]
  end

  test "hard-delete rollback restores row and floor", c do
    before = Store.sync_state(c.account)
    before_revisions = revisions(c)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = Contacts.hard_delete_contact(c.a)
               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(ContactDav, c.a.id)
    assert Store.sync_state(c.account) == before
    assert revisions(c) == before_revisions
    assert Repo.get!(Kith.Contacts.Relationship, c.relationship.id)
  end

  test "successful unused reference deletions leave unrelated contacts unchanged", c do
    before = revisions(c)
    {:ok, gender} = Contacts.create_gender(c.account, %{name: "Unused"})

    {:ok, rt} =
      Contacts.create_relationship_type(c.account, %{name: "Unused", reverse_name: "Unused"})

    {:ok, cft} = Contacts.create_contact_field_type(c.account, %{name: "Unused"})
    assert {:ok, _} = Contacts.delete_gender(gender)
    assert {:ok, _} = Contacts.delete_relationship_type(rt)
    assert {:ok, _} = Contacts.delete_contact_field_type(cft)
    assert revisions(c) == before
  end

  test "unchanged name does not touch incoming relationship owners", c do
    before = revisions(c)
    assert {:ok, _} = Contacts.update_contact(c.a, %{first_name: c.a.first_name})
    assert Repo.get!(ContactDav, c.a.id).revision > before[c.a.id]
    assert Repo.get!(ContactDav, c.b.id).revision == before[c.b.id]
  end

  test "merge touches incoming loser owners and leaves unrelated contacts unchanged", c do
    owner = contact_fixture(c.account)
    control = contact_fixture(c.account)
    relationship_fixture(owner, c.b, c.rt.id)
    Store.ensure_rows(c.account)
    before_owner = Repo.get!(ContactDav, owner.id).revision
    before_control = Repo.get!(ContactDav, control.id).revision
    assert {:ok, _} = Contacts.merge_contacts(c.a.id, c.b.id)
    assert Repo.get!(ContactDav, owner.id).revision > before_owner
    assert Repo.get!(ContactDav, control.id).revision == before_control
  end

  test "merge name resolution touches incoming survivor owners", c do
    owner = contact_fixture(c.account)
    relationship_fixture(owner, c.a, c.rt.id)
    {:ok, loser} = Contacts.update_contact(c.b, %{first_name: "Resolved name"})
    Store.ensure_rows(c.account)
    before = Repo.get!(ContactDav, owner.id).revision

    assert {:ok, survivor} =
             Contacts.merge_contacts(c.a.id, loser.id, %{"first_name" => "non_survivor"})

    assert survivor.first_name == "Resolved name"
    assert Repo.get!(ContactDav, owner.id).revision > before
  end
end
