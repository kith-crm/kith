defmodule Kith.ContactsSubEntitiesTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    account_id = user.account_id
    contact = contact_fixture(account_id)
    %{user: user, account_id: account_id, contact: contact}
  end

  ## Notes

  describe "notes" do
    test "list_notes/2 returns notes for contact", %{contact: contact, user: user} do
      note = note_fixture(contact, user.id)
      notes = Contacts.list_notes(contact.id, user.id)
      assert length(notes) == 1
      assert hd(notes).id == note.id
    end

    test "list_notes/2 filters private notes from other users", %{
      contact: contact,
      user: user,
      account_id: account_id
    } do
      # Create a note by user, marked private
      note_fixture(contact, user.id, %{"body" => "private", "is_private" => "true"})

      # Another user should not see it
      other_user = user_fixture(%{email: "other#{System.unique_integer()}@example.com"})
      # Update account_id so other_user is in same account for the query to work
      Repo.update_all(
        from(u in "users", where: u.id == ^other_user.id),
        set: [account_id: account_id]
      )

      notes = Contacts.list_notes(contact.id, other_user.id)
      assert notes == []
    end

    test "list_notes/2 shows private notes to author", %{contact: contact, user: user} do
      note_fixture(contact, user.id, %{"body" => "secret", "is_private" => "true"})
      notes = Contacts.list_notes(contact.id, user.id)
      assert length(notes) == 1
    end

    test "toggle_note_favorite/1 toggles favorite", %{contact: contact, user: user} do
      note = note_fixture(contact, user.id)
      assert note.favorite == false

      {:ok, toggled} = Contacts.toggle_note_favorite(note)
      assert toggled.favorite == true

      {:ok, toggled2} = Contacts.toggle_note_favorite(toggled)
      assert toggled2.favorite == false
    end

    test "get_note!/3 raises for private note of another user", %{
      contact: contact,
      user: user,
      account_id: account_id
    } do
      note = note_fixture(contact, user.id, %{"is_private" => "true"})

      other_user = user_fixture(%{email: "other2#{System.unique_integer()}@example.com"})

      Repo.update_all(
        from(u in "users", where: u.id == ^other_user.id),
        set: [account_id: account_id]
      )

      assert_raise Ecto.NoResultsError, fn ->
        Contacts.get_note!(account_id, note.id, other_user.id)
      end
    end

    test "delete_note/1 removes the note", %{contact: contact, user: user} do
      note = note_fixture(contact, user.id)
      {:ok, _} = Contacts.delete_note(note)
      assert Contacts.list_notes(contact.id, user.id) == []
    end
  end

  ## Addresses

  describe "addresses" do
    test "CRUD for addresses", %{contact: contact} do
      address = address_fixture(contact)
      assert address.city == "Springfield"

      addresses = Contacts.list_addresses(contact.id)
      assert length(addresses) == 1

      {:ok, updated} = Contacts.update_address(address, %{"city" => "Shelbyville"})
      assert updated.city == "Shelbyville"

      {:ok, _} = Contacts.delete_address(address)
      assert Contacts.list_addresses(contact.id) == []
    end

    test "get_address!/2 retrieves by account", %{contact: contact, account_id: account_id} do
      address = address_fixture(contact)
      fetched = Contacts.get_address!(account_id, address.id)
      assert fetched.id == address.id
    end
  end

  ## Contact Fields

  describe "contact_fields" do
    test "CRUD for contact fields", %{contact: contact, account_id: account_id} do
      [email_type | _] = Contacts.list_contact_field_types(account_id)

      field = contact_field_fixture(contact, email_type.id)
      assert field.value == "test@example.com"

      fields = Contacts.list_contact_fields(contact.id)
      assert length(fields) == 1
      assert hd(fields).contact_field_type.name == "Email"

      {:ok, updated} = Contacts.update_contact_field(field, %{"value" => "new@example.com"})
      assert updated.value == "new@example.com"

      {:ok, _} = Contacts.delete_contact_field(field)
      assert Contacts.list_contact_fields(contact.id) == []
    end

    test "create_contact_field/3 with normalize: false skips phone normalization",
         %{contact: contact, account_id: account_id} do
      phone_type =
        Enum.find(Contacts.list_contact_field_types(account_id), fn t ->
          t.protocol in ["tel", "tel:"]
        end)

      attrs = %{"contact_field_type_id" => phone_type.id, "value" => "+1 (202) 555-0100"}

      assert {:ok, field} =
               Contacts.create_contact_field(contact, attrs, normalize: false)

      assert field.value == "+1 (202) 555-0100"
    end

    test "create_contact_field/3 with normalize: true (default) normalizes phone",
         %{contact: contact, account_id: account_id} do
      phone_type =
        Enum.find(Contacts.list_contact_field_types(account_id), fn t ->
          t.protocol in ["tel", "tel:"]
        end)

      attrs = %{"contact_field_type_id" => phone_type.id, "value" => "+1 (202) 555-0100"}

      assert {:ok, field} = Contacts.create_contact_field(contact, attrs)
      assert field.value == "+12025550100"
    end
  end

  ## Relationships

  describe "relationships" do
    test "create and list relationships (forward + reverse)", %{
      contact: contact,
      account_id: account_id
    } do
      other = contact_fixture(account_id, %{first_name: "Bob", display_name: "Bob Smith"})
      [friend_type | _] = Contacts.list_relationship_types(account_id)

      relationship_fixture(contact, other, friend_type.id)

      # Forward: contact -> other
      forward_rels = Contacts.list_relationships_for_contact(contact.id)
      assert length(forward_rels) == 1
      assert hd(forward_rels).related_contact.id == other.id
      assert hd(forward_rels).label == friend_type.name

      # Reverse: other -> contact
      reverse_rels = Contacts.list_relationships_for_contact(other.id)
      assert length(reverse_rels) == 1
      assert hd(reverse_rels).related_contact.id == contact.id
      assert hd(reverse_rels).label == friend_type.reverse_name
    end

    test "delete_relationship/1 removes the relationship", %{
      contact: contact,
      account_id: account_id
    } do
      other = contact_fixture(account_id, %{first_name: "Carol", display_name: "Carol Lee"})
      [friend_type | _] = Contacts.list_relationship_types(account_id)

      rel = relationship_fixture(contact, other, friend_type.id)
      {:ok, _} = Contacts.delete_relationship(rel)

      assert Contacts.list_relationships_for_contact(contact.id) == []
    end
  end

  ## Photos

  describe "photos" do
    test "CRUD and avatar", %{contact: contact, account_id: _account_id} do
      photo1 = photo_fixture(contact)
      photo2 = photo_fixture(contact, %{"file_name" => "photo2.jpg"})

      photos = Contacts.list_photos(contact.id)
      assert length(photos) == 2

      # Set avatar (stores storage_key, not URL)
      {:ok, updated_contact} = Contacts.set_avatar(contact, photo1)
      assert updated_contact.avatar == photo1.storage_key

      # Setting another as avatar replaces the first
      {:ok, updated_contact2} = Contacts.set_avatar(updated_contact, photo2)
      assert updated_contact2.avatar == photo2.storage_key

      # Deleting avatar photo clears avatar
      {:ok, _} = Contacts.delete_photo(photo2)
      cleared_contact = Contacts.get_contact!(updated_contact2.account_id, contact.id)
      assert is_nil(cleared_contact.avatar)

      {:ok, _} = Contacts.delete_photo(photo1)
      assert length(Contacts.list_photos(contact.id)) == 0
    end
  end

  ## Documents

  describe "documents" do
    test "CRUD for documents", %{contact: contact} do
      doc = document_fixture(contact)
      assert doc.file_name == "doc.pdf"

      docs = Contacts.list_documents(contact.id)
      assert length(docs) == 1

      {:ok, _} = Contacts.delete_document(doc)
      assert Contacts.list_documents(contact.id) == []
    end
  end

  ## Reference Data

  describe "reference data" do
    test "list functions return seeded data", %{account_id: account_id} do
      assert length(Contacts.list_emotions(account_id)) >= 2
      assert length(Contacts.list_life_event_types(account_id)) >= 2
      assert length(Contacts.list_contact_field_types(account_id)) >= 2
      assert length(Contacts.list_relationship_types(account_id)) >= 2
      assert length(Contacts.list_call_directions()) >= 2
    end
  end
end
