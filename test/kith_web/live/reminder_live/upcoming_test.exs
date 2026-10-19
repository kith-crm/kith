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
end
