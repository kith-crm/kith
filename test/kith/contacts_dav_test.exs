defmodule Kith.ContactsDAVTest do
  @moduledoc "Unit tests for DAV-related Contacts context functions."
  use Kith.DataCase, async: true

  alias Kith.Contacts

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    account_id = user.account_id
    contact = contact_fixture(account_id)
    %{account_id: account_id, contact: contact}
  end

  test "export relationship batch has bounded query count", %{account_id: aid, contact: contact} do
    type = Kith.Repo.get_by!(Kith.Contacts.RelationshipType, system_key: "friend")
    targets = for _ <- 1..8, do: contact_fixture(aid)
    for target <- targets, do: relationship_fixture(contact, target, type.id)
    Kith.DAV.Store.ensure_rows(aid)

    query_count = fn contacts ->
      ref = make_ref()
      parent = self()
      handler = "export-queries-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:kith, :repo, :query],
        fn _, _, metadata, _ ->
          if (self() == parent or parent in Process.get(:"$callers", [])) and
               String.starts_with?(metadata.query, "SELECT"),
             do: send(parent, ref)
        end,
        nil
      )

      result = Contacts.export_relationships(contacts)
      :telemetry.detach(handler)

      count =
        Stream.repeatedly(fn ->
          receive do
            ^ref -> 1
          after
            0 -> 0
          end
        end)
        |> Enum.take_while(&(&1 == 1))
        |> Enum.sum()

      {result, count}
    end

    {single, one_count} = query_count.([contact])
    {batch, batch_count} = query_count.([contact | targets])
    assert length(single[contact.id]) == 8
    assert length(Map.keys(batch)) == 9
    assert batch_count == one_count
    assert batch_count <= 7
  end

  test "merge_tags rejects an unrelated account and foreign target without changing either book",
       %{account_id: aid, contact: contact} do
    other = user_fixture().account_id
    {:ok, source} = Contacts.create_tag(aid, %{name: "Source"})
    {:ok, target} = Contacts.create_tag(aid, %{name: "Target"})
    {:ok, foreign} = Contacts.create_tag(other, %{name: "Foreign"})
    Contacts.tag_contact(contact, source)
    Kith.DAV.Store.ensure_rows(aid)
    before = Kith.DAV.Store.sync_state(aid)

    assert {:error, :cross_account_write} = Contacts.merge_tags(other, source, target)
    assert {:error, :cross_account_write} = Contacts.merge_tags(aid, source, foreign)
    assert Kith.DAV.Store.sync_state(aid) == before
    assert [%{id: id}] = Kith.Repo.preload(contact, :tags, force: true).tags
    assert id == source.id
    assert Contacts.get_tag!(other, foreign.id)
  end

  test "tag attrs cannot create or move tags into another account", %{
    account_id: aid,
    contact: contact
  } do
    other = user_fixture().account_id

    assert {:error, :cross_account_write} =
             Contacts.create_tag(aid, %{name: "Foreign", account_id: other})

    assert Contacts.list_tags(other) == []
    {:ok, tag} = Contacts.create_tag(aid, %{name: "Owned"})
    Contacts.tag_contact(contact, tag)
    Kith.DAV.Store.ensure_rows(aid)
    state = Kith.DAV.Store.sync_state(aid)
    assert {:error, :cross_account_write} = Contacts.update_tag(tag, %{account_id: other})
    assert Contacts.get_tag!(aid, tag.id).account_id == aid
    assert Kith.DAV.Store.sync_state(aid) == state
  end

  test "merging a tag into itself preserves its associations", %{
    account_id: aid,
    contact: contact
  } do
    {:ok, tag} = Contacts.create_tag(aid, %{name: "Keep"})
    Contacts.tag_contact(contact, tag)
    Kith.DAV.Store.ensure_rows(aid)
    before = Kith.DAV.Store.sync_state(aid)
    assert {:ok, ^tag} = Contacts.merge_tags(aid, tag, tag)
    assert Contacts.get_tag!(aid, tag.id)
    assert Kith.DAV.Store.sync_state(aid) == before
    assert [%{id: id}] = Kith.Repo.preload(contact, :tags, force: true).tags
    assert id == tag.id
  end

  test "duplicate assignments and color-only tag updates keep DAV bytes and revisions", %{
    account_id: aid,
    contact: contact
  } do
    {:ok, tag} = Contacts.create_tag(aid, %{name: "Family"})
    assert {1, nil} = Contacts.tag_contact(contact, tag)
    Kith.DAV.Store.ensure_rows(aid)
    before = Kith.DAV.VCardAdapter.contact_to_vcard(contact)
    state = Kith.DAV.Store.sync_state(aid)
    assert {0, nil} = Contacts.tag_contact(contact, tag)
    assert {:ok, _} = Contacts.update_tag(tag, %{color: "#123456"})
    assert Kith.DAV.VCardAdapter.contact_to_vcard(contact) == before
    assert Kith.DAV.Store.sync_state(aid) == state
    assert {1, nil} = Contacts.untag_contact(contact, tag)
    assert {0, nil} = Contacts.untag_contact(contact, tag)
  end

  describe "replace_contact_children/3" do
    test "replaces existing children with new data", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [%{value: "old@example.com", label: "Home"}],
        phones: [],
        urls: [],
        addresses: []
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      # Replace with new data
      nested2 = %{
        emails: [%{value: "new@example.com", label: "Work"}],
        phones: [%{value: "555-1234", label: "Mobile"}],
        urls: [],
        addresses: []
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested2)

      # Verify old email is gone and new data is present
      contact = Kith.Repo.preload(contact, [contact_fields: :contact_field_type], force: true)
      values = Enum.map(contact.contact_fields, & &1.value)
      assert "new@example.com" in values
      assert "555-1234" in values
      refute "old@example.com" in values
    end

    test "handles empty lists", %{contact: contact, account_id: aid} do
      nested = %{emails: [], phones: [], urls: [], addresses: []}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end

    test "replaces children with address data", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [%{value: "addr@example.com", label: "Work"}],
        phones: [],
        urls: [],
        addresses: [
          %{
            label: "Home",
            line1: "123 Main St",
            city: "Springfield",
            province: "IL",
            postal_code: "62701",
            country: "US"
          }
        ]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      contact =
        Kith.Repo.preload(contact, [:addresses, contact_fields: :contact_field_type], force: true)

      assert length(contact.addresses) == 1
      assert hd(contact.addresses).line1 == "123 Main St"
      assert hd(contact.addresses).city == "Springfield"

      values = Enum.map(contact.contact_fields, & &1.value)
      assert "addr@example.com" in values
    end
  end

  describe "replace_contact_children/3 — tags (CATEGORIES)" do
    test "creates tags from category names", %{contact: contact, account_id: aid} do
      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        categories: ["Family", "VIP"]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      contact = Kith.Repo.preload(contact, [:tags], force: true)
      tag_names = Enum.map(contact.tags, & &1.name) |> Enum.sort()
      assert tag_names == ["Family", "VIP"]
    end

    test "replaces existing tags on subsequent call", %{contact: contact, account_id: aid} do
      nested1 = %{emails: [], phones: [], urls: [], addresses: [], categories: ["OldTag"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested1)

      nested2 = %{emails: [], phones: [], urls: [], addresses: [], categories: ["NewTag"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested2)

      contact = Kith.Repo.preload(contact, [:tags], force: true)
      tag_names = Enum.map(contact.tags, & &1.name)
      assert tag_names == ["NewTag"]
    end

    test "reuses existing tag by name", %{contact: contact, account_id: aid} do
      {:ok, _tag} = Contacts.create_tag(aid, %{"name" => "Friends"})

      nested = %{emails: [], phones: [], urls: [], addresses: [], categories: ["Friends"]}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      # Should not create a duplicate
      all_tags = Contacts.list_tags(aid)
      friends_tags = Enum.filter(all_tags, &(&1.name == "Friends"))
      assert length(friends_tags) == 1
    end

    test "handles empty categories list", %{contact: contact, account_id: aid} do
      nested = %{emails: [], phones: [], urls: [], addresses: [], categories: []}
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end
  end

  describe "replace_contact_children/3 — relationships (RELATED)" do
    test "creates relationships from related entries", %{contact: contact, account_id: aid} do
      other = contact_fixture(aid, %{first_name: "Bob"})
      Kith.DAV.Store.ensure_rows(aid)
      other = Kith.Repo.preload(other, :dav)

      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        related: [%{value: other.dav.uid, type: "Friend"}]
      }

      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)

      rels = Contacts.list_relationships(contact.id)
      assert length(rels) >= 1
    end

    test "skips relationships where related contact does not exist",
         %{contact: contact, account_id: aid} do
      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        related: [%{value: "kith-contact-999999", type: "Friend"}]
      }

      # Should not crash
      assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    end
  end

  test "unchanged phone keeps its row id and native type", %{contact: contact, account_id: aid} do
    nested = %{
      emails: [],
      phones: [%{value: "555-1234", label: "Mobile"}],
      urls: [],
      addresses: []
    }

    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    [before] = Contacts.list_contact_fields(contact.id)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    [after_write] = Contacts.list_contact_fields(contact.id)
    assert after_write.id == before.id
    assert after_write.contact_field_type_id == before.contact_field_type_id
  end

  test "RELATED to an archived contact keeps the existing relationship", %{
    contact: contact,
    account_id: aid
  } do
    other = contact_fixture(aid)
    Kith.DAV.Store.ensure_rows(aid)
    other = Kith.Repo.preload(other, :dav)

    nested = %{
      emails: [],
      phones: [],
      urls: [],
      addresses: [],
      related: [%{value: other.dav.uid, type: "Friend"}]
    }

    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    [relationship] = Contacts.list_relationships(contact.id)
    {:ok, _} = Contacts.archive_contact(other)
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, nested)
    assert [%{id: id}] = Contacts.list_relationships(contact.id)
    assert id == relationship.id
    assert {:ok, :ok} = Contacts.replace_contact_children(contact, aid, %{nested | related: []})
    assert [%{id: ^id}] = Contacts.list_relationships(contact.id)
  end
end
