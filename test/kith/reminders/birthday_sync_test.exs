defmodule Kith.Reminders.BirthdaySyncTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Reminders}
  alias Kith.Reminders.Occurrences

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  test "creating a contact with a birthdate creates its birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

    r = Reminders.get_birthday_reminder(contact.id, ctx.account_id)

    assert %{
             type: "birthday",
             anchor_date: ~D[1990-06-15],
             interval_unit: "year",
             interval_count: 1
           } = r

    assert r.creator_id == ctx.user.id

    assert r.next_reminder_date ==
             Occurrences.next_on_or_after(Kith.Reminders.Reminder.schedule(r), Date.utc_today())
  end

  test "changing the birthdate re-anchors the same reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})
    before = Reminders.get_birthday_reminder(contact.id, ctx.account_id)

    {:ok, contact} = Contacts.update_contact(contact, %{birthdate: ~D[1990-12-01]})

    after_change = Reminders.get_birthday_reminder(contact.id, ctx.account_id)
    assert after_change.id == before.id
    assert after_change.anchor_date == ~D[1990-12-01]
  end

  test "removing the birthdate deletes the birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

    {:ok, contact} = Contacts.update_contact(contact, %{birthdate: nil})

    assert Reminders.get_birthday_reminder(contact.id, ctx.account_id) == nil
  end

  test "a contact without a birthdate gets no birthday reminder", ctx do
    contact = contact_fixture(ctx.account_id)
    assert Reminders.get_birthday_reminder(contact.id, ctx.account_id) == nil
  end

  test "a Feb 29 birthdate falls back to Feb 28 in non-leap years", ctx do
    contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1992-02-29]})
    r = Reminders.get_birthday_reminder(contact.id, ctx.account_id)

    assert Occurrences.next_on_or_after(Kith.Reminders.Reminder.schedule(r), ~D[2027-01-01]) ==
             ~D[2027-02-28]
  end
end
