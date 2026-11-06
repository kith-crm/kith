defmodule Kith.Workers.AccountResetWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Activities.Activity
  alias Kith.AuditLogs.AuditLog
  alias Kith.Contacts.{Contact, Tag}
  alias Kith.Conversations.Conversation
  alias Kith.Imports
  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Journal.Entry
  alias Kith.Reminders.Reminder
  alias Kith.Repo
  alias Kith.Tasks.Task, as: TaskSchema
  alias Kith.Workers.AccountResetWorker

  import Kith.Factory, only: [insert: 2]
  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures
  import Kith.RemindersFixtures

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

  describe "perform/1 — regression: re-import after reset" do
    test "re-import for same Monica contact id resolves to new local contact (no stale import_records)",
         ctx do
      # Initial import: contact + import_record for Monica id 964
      import_a =
        import_fixture(ctx.target_account, ctx.target_user, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "k"
        })

      contact_a = contact_fixture(ctx.target_account)

      {:ok, _} =
        Imports.record_imported_entity(import_a, "contact", "964", "contact", contact_a.id)

      # Run reset
      assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})

      # Target account fully wiped
      assert count(Contact, ctx.target_account) == 0
      assert count(Import, ctx.target_account) == 0
      assert count(ImportRecord, ctx.target_account) == 0

      # Re-import: new contact + new import_record for the same Monica id
      import_b =
        import_fixture(ctx.target_account, ctx.target_user, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "k"
        })

      contact_b = contact_fixture(ctx.target_account)

      {:ok, _} =
        Imports.record_imported_entity(import_b, "contact", "964", "contact", contact_b.id)

      # The photo-sync lookup that previously found stale data now resolves correctly
      assert %{local_entity_id: local_id} =
               Imports.find_import_record(ctx.target_account, "monica_api", "contact", "964")

      assert local_id == contact_b.id
    end
  end

  describe "perform/1 — cross-account isolation" do
    test "resetting account A does not touch any data in account B", ctx do
      target_contact = populate_data!(ctx.target_account, ctx.target_user)
      _other_contact = populate_data!(ctx.other_account, ctx.other_user)

      before_other = snapshot(ctx.other_account)

      assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})

      # Target wiped across every domain
      assert empty?(ctx.target_account)
      assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})
      assert empty?(ctx.target_account)
      assert Repo.get!(Kith.Accounts.User, ctx.target_user).account_id == ctx.target_account

      # Other account is bit-identical to before
      assert snapshot(ctx.other_account) == before_other

      # Sanity: target_contact is gone, other account still has its contact
      refute Repo.get(Contact, target_contact.id)
    end
  end

  test "reset preserves account configuration and reference data", ctx do
    account = Repo.get!(Kith.Accounts.Account, ctx.target_account)
    gender = insert(:gender, account: account)
    field_type = insert(:contact_field_type, account: account)
    gender = Repo.get!(Kith.Contacts.Gender, gender.id)
    field_type = Repo.get!(Kith.Contacts.ContactFieldType, field_type.id)
    rules = Kith.Reminders.list_reminder_rules(ctx.target_account)

    assert :ok = perform_job(AccountResetWorker, %{account_id: ctx.target_account})

    assert Repo.get!(Kith.Accounts.Account, account.id) == account
    assert Repo.get!(Kith.Contacts.Gender, gender.id) == gender
    assert Repo.get!(Kith.Contacts.ContactFieldType, field_type.id) == field_type
    assert Kith.Reminders.list_reminder_rules(ctx.target_account) == rules
  end

  defp populate_data!(account_id, user_id) do
    contact = contact_fixture(account_id)

    target_import =
      import_fixture(account_id, user_id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    {:ok, _} =
      Imports.record_imported_entity(target_import, "contact", "1", "contact", contact.id)

    account = Repo.get!(Kith.Accounts.Account, account_id)

    for factory <- [
          :address,
          :contact_field,
          :photo,
          :document,
          :pet,
          :gift,
          :debt,
          :immich_candidate
        ] do
      insert(factory, account: account, contact: contact)
    end

    second_contact = contact_fixture(account_id)

    insert(:duplicate_candidate,
      account: account,
      contact: contact,
      duplicate_contact: second_contact
    )

    Repo.insert!(%Tag{account_id: account_id, name: "t"})

    Repo.insert!(%Activity{
      account_id: account_id,
      title: "a",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%TaskSchema{
      account_id: account_id,
      creator_id: user_id,
      title: "x"
    })

    Repo.insert!(%Entry{
      account_id: account_id,
      author_id: user_id,
      content: "c",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    Repo.insert!(%Conversation{
      account_id: account_id,
      creator_id: user_id,
      contact_id: contact.id,
      subject: "s",
      platform: "other",
      status: "active"
    })

    reminder = reminder_fixture(account_id, contact.id, user_id)
    Kith.RemindersFixtures.reminder_instance_fixture(reminder)

    {:ok, _} =
      Kith.AuditLogs.create_audit_log(account_id, %{
        user_id: nil,
        user_name: "test",
        event: "account_data_reset",
        metadata: %{}
      })

    contact
  end

  defp snapshot(account_id) do
    %{
      subrecords: Enum.map(wiped_subrecord_schemas(), &count(&1, account_id)),
      contacts: count(Contact, account_id),
      imports: count(Import, account_id),
      import_records: count(ImportRecord, account_id),
      conversations: count(Conversation, account_id),
      tasks: count(TaskSchema, account_id),
      journal_entries: count(Entry, account_id),
      reminders: count(Reminder, account_id),
      tags: count(Tag, account_id),
      activities: count(Activity, account_id),
      audit_logs: count(AuditLog, account_id)
    }
  end

  defp empty?(account_id) do
    snapshot(account_id) ==
      %{
        subrecords: Enum.map(wiped_subrecord_schemas(), fn _ -> 0 end),
        contacts: 0,
        imports: 0,
        import_records: 0,
        conversations: 0,
        tasks: 0,
        journal_entries: 0,
        reminders: 0,
        tags: 0,
        activities: 0,
        audit_logs: 0
      }
  end

  defp wiped_subrecord_schemas do
    [
      Kith.Contacts.Address,
      Kith.Contacts.ContactField,
      Kith.Contacts.Photo,
      Kith.Contacts.Document,
      Kith.Contacts.Pet,
      Kith.Contacts.Gift,
      Kith.Contacts.Debt,
      Kith.Contacts.ImmichCandidate,
      Kith.Contacts.DuplicateCandidate,
      Kith.DAV.ContactDav,
      Kith.DAV.DocumentReference,
      Kith.Reminders.ReminderInstance
    ]
  end

  defp count(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
