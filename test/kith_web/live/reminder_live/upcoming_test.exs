defmodule KithWeb.ReminderLive.UpcomingTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  test "a first_met reminder shows the sparkles icon and the First met label", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)
    # Anniversary in about five days; skip 29 Feb so the shift is never clamped.
    soon = Date.add(Date.utc_today(), 5)
    soon = if {soon.month, soon.day} == {2, 29}, do: Date.add(soon, 1), else: soon
    met = Date.shift(soon, year: -3)

    {:ok, _} =
      Kith.Contacts.update_contact(contact, %{first_met_at: met, first_met_reminder: true})

    {:ok, view, _html} = live(conn, ~p"/reminders/upcoming")

    assert has_element?(view, "span.hero-sparkles")
    assert has_element?(view, "p", "First met")
  end

  test "a deceased contact's reminder remains visible", %{conn: conn, user: user} do
    contact = contact_fixture(user.account_id, %{deceased: true})

    {:ok, _} =
      Kith.Reminders.create_reminder(user.account_id, user.id, %{
        type: "one_time",
        title: "Visit grave",
        anchor_date: Date.add(Date.utc_today(), 5),
        contact_id: contact.id
      })

    {:ok, view, _html} = live(conn, ~p"/reminders/upcoming")

    assert has_element?(view, "p", "Visit grave")
  end

  for {duration, minutes, label} <- [
        {"fifteen_minutes", 15, "15 minutes"},
        {"one_hour", 60, "1 hour"},
        {"one_day", 1440, "1 day"},
        {"three_days", 4320, "3 days"}
      ] do
    test "the #{label} snooze action uses a supported duration", %{conn: conn, user: user} do
      contact = contact_fixture(user.account_id)
      reminder = Kith.RemindersFixtures.reminder_fixture(user.account_id, contact.id, user.id)
      instance = Kith.RemindersFixtures.reminder_instance_fixture(reminder)
      {:ok, view, _html} = live(conn, ~p"/reminders/upcoming")
      started = DateTime.utc_now()

      html =
        view
        |> element(
          "button[phx-click='snooze-instance'][phx-value-duration='#{unquote(duration)}']"
        )
        |> render_click()

      assert html =~ "Reminder snoozed for #{unquote(label)}"
      updated = Kith.Repo.reload!(instance)
      assert updated.status == "snoozed"
      assert_in_delta DateTime.diff(updated.snoozed_until, started), unquote(minutes) * 60, 2
    end
  end
end
