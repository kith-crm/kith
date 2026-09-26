defmodule Kith.RemindersTest do
  use Kith.DataCase, async: true

  alias Kith.Reminders
  alias Kith.Reminders.{Reminder, ReminderInstance}
  alias Kith.TimeHelper

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.RemindersFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    account_id = user.account_id
    contact = contact_fixture(account_id)
    seed_reminder_rules!(account_id)
    %{user: user, account_id: account_id, contact: contact}
  end

  ## Reminder CRUD

  describe "list_reminders/2" do
    test "returns active reminders for a contact", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      assert [%Reminder{id: id}] = Reminders.list_reminders(account_id, contact.id)
      assert id == r.id
    end

    test "excludes inactive reminders", %{account_id: account_id, contact: contact, user: user} do
      r = reminder_fixture(account_id, contact.id, user.id)
      r |> Ecto.Changeset.change(active: false) |> Repo.update!()
      assert Reminders.list_reminders(account_id, contact.id) == []
    end
  end

  describe "get_reminder!/2" do
    test "returns reminder by id scoped to account", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      assert Reminders.get_reminder!(account_id, r.id).id == r.id
    end

    test "raises for wrong account", %{contact: contact, user: user, account_id: account_id} do
      r = reminder_fixture(account_id, contact.id, user.id)
      other_user = user_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Reminders.get_reminder!(other_user.account_id, r.id)
      end
    end
  end

  ## Reminder Schemas

  describe "Reminder changeset validations" do
    test "requires frequency for stay_in_touch type", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "stay_in_touch",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id,
          frequency: nil
        })

      refute cs.valid?
      assert %{frequency: _} = errors_on(cs)
    end

    test "requires frequency for recurring type", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "recurring",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id,
          frequency: nil
        })

      refute cs.valid?
    end

    test "rejects non-nil frequency for one_time type", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "one_time",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id,
          frequency: "weekly"
        })

      refute cs.valid?
      assert %{frequency: ["must be nil for one-time reminders"]} = errors_on(cs)
    end

    test "rejects unknown frequency values", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "recurring",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id,
          frequency: "every_tuesday"
        })

      refute cs.valid?
    end

    test "accepts valid frequency for recurring", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "recurring",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id,
          frequency: "monthly"
        })

      assert cs.valid?
    end

    test "rejects unknown type", %{account_id: account_id, contact: contact, user: user} do
      cs =
        Reminder.create_changeset(%Reminder{}, %{
          type: "daily",
          next_reminder_date: Date.utc_today(),
          contact_id: contact.id,
          account_id: account_id,
          creator_id: user.id
        })

      refute cs.valid?
    end
  end

  ## ReminderInstance

  describe "ReminderInstance changesets" do
    test "resolve_changeset sets status and resolved_at", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)
      cs = ReminderInstance.resolve_changeset(i)
      assert cs.changes.status == "resolved"
      assert cs.changes.resolved_at
    end

    test "dismiss_changeset sets status and resolved_at", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)
      cs = ReminderInstance.dismiss_changeset(i)
      assert cs.changes.status == "dismissed"
      assert cs.changes.resolved_at
    end

    test "fail_changeset sets status to failed", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)
      cs = ReminderInstance.fail_changeset(i)
      assert cs.changes.status == "failed"
    end

    test "validates status inclusion", %{account_id: account_id, contact: contact, user: user} do
      r = reminder_fixture(account_id, contact.id, user.id)

      cs =
        ReminderInstance.create_changeset(%ReminderInstance{}, %{
          reminder_id: r.id,
          account_id: account_id,
          contact_id: contact.id,
          scheduled_for: DateTime.utc_now(),
          status: "invalid"
        })

      refute cs.valid?
    end
  end

  ## Reminder Rules

  describe "reminder rules" do
    test "seed_default_rules creates 3 rules", %{account_id: account_id} do
      rules = Reminders.list_reminder_rules(account_id)
      assert length(rules) == 3
      assert Enum.map(rules, & &1.days_before) == [0, 7, 30]
    end

    test "active_rules returns only active rules", %{account_id: account_id} do
      rules = Reminders.list_reminder_rules(account_id)
      seven_day = Enum.find(rules, &(&1.days_before == 7))
      {:ok, _} = Reminders.toggle_reminder_rule(seven_day)

      active = Reminders.active_rules(account_id)
      assert length(active) == 2
      refute Enum.any?(active, &(&1.days_before == 7))
    end

    test "cannot deactivate on-day rule", %{account_id: account_id} do
      rules = Reminders.list_reminder_rules(account_id)
      on_day = Enum.find(rules, &(&1.days_before == 0))
      assert {:error, :cannot_deactivate_on_day_rule} = Reminders.toggle_reminder_rule(on_day)
    end
  end

  ## Birthday Reminder

  describe "birthday reminders" do
    test "get_birthday_reminder returns birthday or nil", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      assert Reminders.get_birthday_reminder(contact.id, account_id) == nil

      birthday_reminder_fixture(account_id, contact.id, user.id)
      assert %Reminder{type: "birthday"} = Reminders.get_birthday_reminder(contact.id, account_id)
    end

    test "delete_birthday_reminder is safe when none exists", %{
      account_id: account_id,
      contact: contact
    } do
      assert {:ok, :no_birthday_reminder} =
               Reminders.delete_birthday_reminder(contact.id, account_id)
    end

    test "convert_to_birthday_reminder rewrites an existing reminder in place", %{
      account_id: account_id,
      user: user
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})

      recurring =
        reminder_fixture(account_id, contact.id, user.id, %{
          type: "recurring",
          frequency: "annually",
          next_reminder_date: ~D[2024-01-01]
        })

      assert {:ok, converted} = Reminders.convert_to_birthday_reminder(recurring, contact)
      assert converted.id == recurring.id
      assert converted.type == "birthday"
      assert converted.frequency == nil
      assert converted.next_reminder_date == TimeHelper.next_birthday_date(~D[1990-06-15])
    end

    test "convert_to_birthday_reminder errors when a distinct birthday reminder exists", %{
      account_id: account_id,
      user: user
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})
      birthday_reminder_fixture(account_id, contact.id, user.id)

      recurring =
        reminder_fixture(account_id, contact.id, user.id, %{
          type: "recurring",
          frequency: "annually",
          next_reminder_date: ~D[2024-01-01]
        })

      assert {:error, %Ecto.Changeset{}} =
               Reminders.convert_to_birthday_reminder(recurring, contact)
    end
  end

  ## Stay-in-Touch Resolution

  describe "resolve_stay_in_touch_instance/1" do
    test "resolves pending instance and advances next date", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = stay_in_touch_reminder_fixture(account_id, contact.id, user.id, "monthly")
      _i = reminder_instance_fixture(r)

      assert {:ok, :resolved} = Reminders.resolve_stay_in_touch_instance(contact.id)

      updated = Repo.get!(Reminder, r.id)
      expected_date = Date.add(Date.utc_today(), 30)
      assert updated.next_reminder_date == expected_date
      assert updated.enqueued_oban_job_ids == []
    end

    test "returns :no_pending_instance when none exists", %{contact: contact} do
      assert {:ok, :no_pending_instance} = Reminders.resolve_stay_in_touch_instance(contact.id)
    end
  end

  ## Instance Management

  describe "resolve_instance/1 and dismiss_instance/1" do
    test "resolve_instance sets status to resolved", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)
      {:ok, resolved} = Reminders.resolve_instance(i)
      assert resolved.status == "resolved"
      assert resolved.resolved_at
    end

    test "dismiss_instance sets status to dismissed", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)
      {:ok, dismissed} = Reminders.dismiss_instance(i)
      assert dismissed.status == "dismissed"
      assert dismissed.resolved_at
    end

    test "resolve_instance advances stay-in-touch next_reminder_date", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = stay_in_touch_reminder_fixture(account_id, contact.id, user.id, "weekly")
      i = reminder_instance_fixture(r)
      {:ok, _} = Reminders.resolve_instance(i)

      updated = Repo.get!(Reminder, r.id)
      assert updated.next_reminder_date == Date.add(Date.utc_today(), 7)
    end
  end

  ## Upcoming Reminders

  describe "upcoming/2" do
    test "returns reminders within window", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      # Due in 7 days (within 30-day window)
      reminder_fixture(account_id, contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 7)
      })

      # Due in 60 days (outside 30-day window)
      reminder_fixture(account_id, contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 60),
        type: "recurring",
        frequency: "monthly"
      })

      results = Reminders.upcoming(account_id, 30)
      assert length(results) == 1
    end

    test "excludes deceased contacts", %{account_id: account_id, user: user} do
      deceased_contact = contact_fixture(account_id, %{deceased: true})

      reminder_fixture(account_id, deceased_contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 7)
      })

      assert Reminders.upcoming(account_id, 30) == []
    end

    test "excludes soft-deleted contacts", %{account_id: account_id, user: user} do
      deleted_contact = contact_fixture(account_id)
      deleted_contact |> Kith.Contacts.Contact.soft_delete_changeset() |> Repo.update!()

      reminder_fixture(account_id, deleted_contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 7)
      })

      assert Reminders.upcoming(account_id, 30) == []
    end

    test "excludes archived contacts", %{account_id: account_id, user: user} do
      archived_contact = contact_fixture(account_id, %{is_archived: true})

      reminder_fixture(account_id, archived_contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 7)
      })

      assert Reminders.upcoming(account_id, 30) == []
    end
  end

  ## Upcoming Count

  describe "upcoming_count/1" do
    test "returns count of upcoming reminders", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      reminder_fixture(account_id, contact.id, user.id, %{
        next_reminder_date: Date.add(Date.utc_today(), 7)
      })

      assert Reminders.upcoming_count(account_id) == 1
    end
  end

  ## Pending Instances

  describe "has_pending_instance?/1" do
    test "returns true when pending instance exists", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      reminder_instance_fixture(r)
      assert Reminders.has_pending_instance?(r.id)
    end

    test "returns false when no pending instance", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = reminder_fixture(account_id, contact.id, user.id)
      refute Reminders.has_pending_instance?(r.id)
    end
  end

  ## Archive Contact Reminders

  describe "archive_contact_reminders/2" do
    test "deactivates stay-in-touch and dismisses pending instances", %{
      account_id: account_id,
      contact: contact,
      user: user
    } do
      r = stay_in_touch_reminder_fixture(account_id, contact.id, user.id)
      i = reminder_instance_fixture(r)

      :ok = Reminders.archive_contact_reminders(contact.id, account_id)

      updated_reminder = Repo.get!(Reminder, r.id)
      assert updated_reminder.active == false

      updated_instance = Repo.get!(ReminderInstance, i.id)
      assert updated_instance.status == "dismissed"
      assert updated_instance.resolved_at
    end
  end

  ## Cancel All For Contact

  describe "cancel_all_for_contact/2" do
    test "returns ok", %{account_id: account_id, contact: contact, user: user} do
      _r = reminder_fixture(account_id, contact.id, user.id)
      assert {:ok, _} = Reminders.cancel_all_for_contact(contact.id, account_id)
    end
  end
end
