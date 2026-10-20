defmodule Kith.Reminders.FirstMetSyncTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Reminders, Repo}
  alias Kith.Reminders.Reminder

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  test "no reminder unless the contact opts in", ctx do
    contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
  end

  test "opting in creates a yearly first_met reminder owned by the account owner", ctx do
    contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})
    {:ok, contact} = Contacts.update_contact(contact, %{first_met_reminder: true})

    r = Reminders.get_first_met_reminder(contact.id, ctx.account_id)

    assert %{
             type: "first_met",
             anchor_date: ~D[2012-09-01],
             interval_unit: "year",
             interval_count: 1,
             title: nil
           } = r

    assert r.creator_id == ctx.user.id
  end

  test "creating a contact already opted in creates the reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    assert %{type: "first_met"} = Reminders.get_first_met_reminder(contact.id, ctx.account_id)
  end

  test "changing the first-met date re-anchors the same reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    before = Reminders.get_first_met_reminder(contact.id, ctx.account_id)
    {:ok, contact} = Contacts.update_contact(contact, %{first_met_at: ~D[2013-03-03]})
    after_change = Reminders.get_first_met_reminder(contact.id, ctx.account_id)

    assert after_change.id == before.id
    assert after_change.anchor_date == ~D[2013-03-03]
  end

  test "opting out deletes the reminder", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, contact} = Contacts.update_contact(contact, %{first_met_reminder: false})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
  end

  test "clearing the first-met date deletes the reminder but keeps the opt-in", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, contact} = Contacts.update_contact(contact, %{first_met_at: nil})
    assert Reminders.get_first_met_reminder(contact.id, ctx.account_id) == nil
    assert contact.first_met_reminder
  end

  test "sync_first_met/1 is idempotent", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    {:ok, r1} = Reminders.sync_first_met(contact)
    {:ok, r2} = Reminders.sync_first_met(contact)
    assert r1.id == r2.id
  end

  test "the unique index rejects a second first_met reminder for one contact", ctx do
    contact =
      contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01], first_met_reminder: true})

    assert {:error, _changeset} =
             Reminders.create_reminder(ctx.account_id, ctx.user.id, %{
               type: "first_met",
               title: nil,
               anchor_date: ~D[2012-09-01],
               interval_unit: "year",
               interval_count: 1,
               contact_id: contact.id
             })

    assert Repo.aggregate(from(r in Reminder, where: r.contact_id == ^contact.id), :count) == 1
  end

  test "birthday sync still works after the shared refactor", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})
    assert %{type: "birthday"} = Reminders.get_birthday_reminder(contact.id, ctx.account_id)
  end
end
