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
    # Anniversary five days from now, whatever the year.
    met = Date.shift(Date.add(Date.utc_today(), 5), year: -3)

    {:ok, _} =
      Kith.Contacts.update_contact(contact, %{first_met_at: met, first_met_reminder: true})

    {:ok, _view, html} = live(conn, ~p"/reminders/upcoming")

    assert html =~ "hero-sparkles"
    assert html =~ "First met"
  end
end
