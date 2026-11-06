defmodule Kith.Imports.ContactCleanupTest do
  # The failure test creates a restrictive FK, which locks the contacts table.
  use Kith.DataCase, async: false

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.Factory
  import Kith.ImportsFixtures

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Imports.ImportRecord
  alias Kith.Workers.ContactPurgeWorker

  setup do
    seed_reference_data!()
    user = user_fixture()
    account = Kith.Accounts.get_account!(user.account_id)
    contact = contact_fixture(account.id)
    import_job = import_fixture(account.id, user.id)
    %{user: user, account: account, contact: contact, import_job: import_job}
  end

  defp map_entity(import_job, type, entity) do
    {:ok, mapping} =
      Imports.record_imported_entity(import_job, type, "#{type}-#{entity.id}", type, entity.id)

    mapping
  end

  defp owned_rows(ctx) do
    basic =
      for type <- ~w(address call contact_field document life_event pet photo)a do
        {Atom.to_string(type), insert(type, contact: ctx.contact, account: ctx.account)}
      end

    authored =
      for type <- ~w(conversation debt gift reminder task)a do
        {Atom.to_string(type),
         insert(type, contact: ctx.contact, account: ctx.account, creator: ctx.user)}
      end

    note = insert(:note, contact: ctx.contact, account: ctx.account, author: ctx.user)
    conversation = authored |> List.keyfind("conversation", 0) |> elem(1)
    message = insert(:message, conversation: conversation, account: ctx.account)
    debt = authored |> List.keyfind("debt", 0) |> elem(1)
    payment = insert(:debt_payment, debt: debt, account: ctx.account)
    reminder = authored |> List.keyfind("reminder", 0) |> elem(1)

    instance =
      insert(:reminder_instance,
        reminder: reminder,
        contact: ctx.contact,
        account: ctx.account
      )

    [
      {"contact", ctx.contact},
      {"note", note},
      {"message", message},
      {"debt_payment", payment},
      {"reminder_instance", instance}
    ] ++
      basic ++ authored
  end

  test "hard deletion removes mappings for cascaded children, including nested messages", ctx do
    rows = owned_rows(ctx)
    mappings = Enum.map(rows, fn {type, row} -> map_entity(ctx.import_job, type, row) end)

    assert {:ok, deleted} = Contacts.hard_delete_contact(ctx.contact)
    assert deleted.id == ctx.contact.id

    for mapping <- mappings, do: assert(Repo.get(ImportRecord, mapping.id) == nil)
    for {_type, row} <- rows, do: assert(Repo.get(row.__struct__, row.id) == nil)
    assert Imports.get_import!(ctx.import_job.id)
  end

  test "soft deletion and restoration preserve import mappings", ctx do
    note = note_fixture(ctx.contact, ctx.user.id)
    contact_mapping = map_entity(ctx.import_job, "contact", ctx.contact)
    note_mapping = map_entity(ctx.import_job, "note", note)

    assert {:ok, trashed} = Contacts.soft_delete_contact(ctx.contact)
    assert Repo.get!(ImportRecord, contact_mapping.id)
    assert Repo.get!(ImportRecord, note_mapping.id)

    assert {:ok, _} = Contacts.restore_contact(trashed)
    assert Repo.get!(ImportRecord, contact_mapping.id)
    assert Repo.get!(ImportRecord, note_mapping.id)
  end

  test "empty trash cleans only the deleted contacts and is idempotent", ctx do
    note = note_fixture(ctx.contact, ctx.user.id)
    map_entity(ctx.import_job, "contact", ctx.contact)
    note_mapping = map_entity(ctx.import_job, "note", note)
    active = contact_fixture(ctx.account.id)
    active_mapping = map_entity(ctx.import_job, "contact", active)
    other_user = user_fixture()
    other_contact = contact_fixture(other_user.account_id)
    other_import = import_fixture(other_user.account_id, other_user.id)
    other_mapping = map_entity(other_import, "contact", other_contact)
    {:ok, _} = Contacts.soft_delete_contact(ctx.contact)
    {:ok, _} = Contacts.soft_delete_contact(other_contact)

    assert {:ok, 1} = Contacts.empty_trash(ctx.account.id)
    assert Repo.get(ImportRecord, note_mapping.id) == nil
    assert Repo.get!(ImportRecord, active_mapping.id)
    assert Repo.get!(ImportRecord, other_mapping.id)
    assert {:ok, 0} = Contacts.empty_trash(ctx.account.id)
  end

  test "nightly purge cleans mappings and keeps recent trash", ctx do
    note = note_fixture(ctx.contact, ctx.user.id)

    mappings = [
      map_entity(ctx.import_job, "contact", ctx.contact),
      map_entity(ctx.import_job, "note", note)
    ]

    old = DateTime.utc_now(:second) |> DateTime.add(-31, :day)
    ctx.contact |> change(deleted_at: old) |> Repo.update!()
    recent = contact_fixture(ctx.account.id)
    recent_mapping = map_entity(ctx.import_job, "contact", recent)
    {:ok, _} = Contacts.soft_delete_contact(recent)

    assert :ok = ContactPurgeWorker.perform(%Oban.Job{})
    for mapping <- mappings, do: assert(Repo.get(ImportRecord, mapping.id) == nil)
    assert Repo.get!(ImportRecord, recent_mapping.id)
    assert :ok = ContactPurgeWorker.perform(%Oban.Job{})
  end

  test "cleanup matches account and entity type, and preserves surviving activities", ctx do
    map_entity(ctx.import_job, "contact", ctx.contact)
    activity = insert(:activity, account: ctx.account)
    activity_mapping = map_entity(ctx.import_job, "activity", activity)
    other_contact = contact_fixture(ctx.account.id)

    Repo.insert_all("activity_contacts", [
      %{activity_id: activity.id, contact_id: ctx.contact.id},
      %{activity_id: activity.id, contact_id: other_contact.id}
    ])

    # An equal id in another entity namespace must not match the contact mapping.
    type_mapping = map_entity(ctx.import_job, "unrelated_type", ctx.contact)
    other_user = user_fixture()
    other_import = import_fixture(other_user.account_id, other_user.id)
    other_mapping = map_entity(other_import, "contact", ctx.contact)

    assert {:ok, _} = Contacts.hard_delete_contact(ctx.contact)

    for mapping <- [activity_mapping, type_mapping, other_mapping],
        do: assert(Repo.get!(ImportRecord, mapping.id))

    assert Repo.get!(Kith.Activities.Activity, activity.id)

    assert Repo.exists?(
             from(ac in "activity_contacts", where: ac.contact_id == ^other_contact.id)
           )
  end

  test "inbound relationship mappings are removed when their target is deleted", ctx do
    other = contact_fixture(ctx.account.id)
    type_id = Repo.one!(from(t in Contacts.RelationshipType, select: t.id, limit: 1))
    relationship = relationship_fixture(other, ctx.contact, type_id)
    mapping = map_entity(ctx.import_job, "relationship", relationship)

    assert {:ok, _} = Contacts.hard_delete_contact(ctx.contact)
    assert Repo.get(ImportRecord, mapping.id) == nil
  end

  test "purging a merged-away contact preserves remapped contact and child mappings", ctx do
    survivor = contact_fixture(ctx.account.id)
    note = note_fixture(ctx.contact, ctx.user.id)
    contact_mapping = map_entity(ctx.import_job, "contact", ctx.contact)
    note_mapping = map_entity(ctx.import_job, "note", note)

    assert {:ok, _} = Contacts.merge_contacts(survivor.id, ctx.contact.id)
    assert {:ok, 1} = Contacts.empty_trash(ctx.account.id)

    assert Repo.get!(ImportRecord, contact_mapping.id).local_entity_id == survivor.id
    assert Repo.get!(ImportRecord, note_mapping.id).local_entity_id == note.id
    assert Repo.get!(Contacts.Note, note.id).contact_id == survivor.id
  end

  test "deletion and mapping cleanup roll back with their enclosing transaction", ctx do
    note = note_fixture(ctx.contact, ctx.user.id)
    mapping = map_entity(ctx.import_job, "note", note)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = Contacts.hard_delete_contact(ctx.contact)
               assert Repo.get(ImportRecord, mapping.id) == nil
               Repo.rollback(:abort)
             end)

    assert Repo.get!(Contacts.Contact, ctx.contact.id)
    assert Repo.get!(Contacts.Note, note.id)
    assert Repo.get!(ImportRecord, mapping.id)
  end

  test "a failed contact deletion rolls back its import mapping cleanup", ctx do
    note = note_fixture(ctx.contact, ctx.user.id)
    mapping = map_entity(ctx.import_job, "note", note)

    # A restrictive FK forces the delete to fail after mapping cleanup ran.
    # The sandbox transaction rolls this table back with the test.
    Repo.query!("""
    CREATE TABLE contact_cleanup_delete_blocker (
      contact_id bigint REFERENCES contacts(id) ON DELETE RESTRICT
    )
    """)

    Repo.query!("INSERT INTO contact_cleanup_delete_blocker (contact_id) VALUES ($1)", [
      ctx.contact.id
    ])

    assert_raise Ecto.ConstraintError, fn -> Contacts.hard_delete_contact(ctx.contact) end

    assert Repo.get!(Contacts.Contact, ctx.contact.id)
    assert Repo.get!(Contacts.Note, note.id)
    assert Repo.get!(ImportRecord, mapping.id)
  end
end
