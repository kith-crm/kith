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

  describe "touch_contact!/1" do
    test "bumps updated_at", %{contact: contact} do
      old_updated_at = contact.updated_at
      # Ensure at least 1 second passes
      Process.sleep(1100)
      updated = Contacts.touch_contact!(contact)
      assert DateTime.compare(updated.updated_at, old_updated_at) == :gt
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

      nested = %{
        emails: [],
        phones: [],
        urls: [],
        addresses: [],
        related: [%{value: "kith-contact-#{other.id}", type: "Friend"}]
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
end
