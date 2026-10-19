defmodule KithWeb.ContactLive.RemindersComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{account_id: user.account_id, contact: contact_fixture(user.account_id)}
  end

  defp open_form(conn, contact) do
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    view |> element("button[phx-click='toggle-more-drawer']") |> render_click()
    view |> element("#reminders-#{contact.id} button", "Add") |> render_click()
    view
  end

  defp rem_form(view, contact), do: element(view, "#reminders-#{contact.id} form")

  defp tomorrow, do: Date.to_iso8601(Date.add(Date.utc_today(), 1))

  test "Custom… shows the count and unit fields; a preset hides them", %{
    conn: conn,
    contact: contact
  } do
    view = open_form(conn, contact)

    html =
      view
      |> rem_form(contact)
      |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})

    assert html =~ ~s(name="reminder[interval_count]")

    html =
      view
      |> rem_form(contact)
      |> render_change(%{reminder: %{type: "recurring", frequency: "weekly"}})

    refute html =~ ~s(name="reminder[interval_count]")
  end

  test "saving Every 10 days creates a day-interval reminder", %{
    conn: conn,
    contact: contact,
    account_id: account_id
  } do
    view = open_form(conn, contact)

    view
    |> rem_form(contact)
    |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})

    html =
      view
      |> rem_form(contact)
      |> render_submit(%{
        reminder: %{
          type: "recurring",
          title: "Water",
          frequency: "custom",
          interval_count: "10",
          interval_unit: "day",
          anchor_date: tomorrow(),
          description: "The ferns"
        }
      })

    assert html =~ "Every 10 days"
    assert html =~ "The ferns"

    assert [%{interval_unit: "day", interval_count: 10}] =
             Kith.Reminders.list_contact_reminders(account_id, contact.id)
  end

  test "a preset still saves", %{conn: conn, contact: contact, account_id: account_id} do
    view = open_form(conn, contact)

    view
    |> rem_form(contact)
    |> render_change(%{reminder: %{type: "recurring", frequency: "monthly"}})

    view
    |> rem_form(contact)
    |> render_submit(%{
      reminder: %{type: "recurring", title: "Rent", frequency: "monthly", anchor_date: tomorrow()}
    })

    assert [%{interval_unit: "month", interval_count: 1}] =
             Kith.Reminders.list_contact_reminders(account_id, contact.id)
  end

  test "a zero or non-numeric count is rejected and nothing is saved", %{
    conn: conn,
    contact: contact,
    account_id: account_id
  } do
    view = open_form(conn, contact)

    view
    |> rem_form(contact)
    |> render_change(%{reminder: %{type: "recurring", frequency: "custom"}})

    for bad <- ["0", "abc"] do
      view
      |> rem_form(contact)
      |> render_submit(%{
        reminder: %{
          type: "recurring",
          title: "X",
          frequency: "custom",
          interval_count: bad,
          interval_unit: "day",
          anchor_date: tomorrow()
        }
      })

      # The error path keeps the form open (flash is shown by the layout).
      assert has_element?(view, "#reminders-#{contact.id} form")
    end

    assert Kith.Reminders.list_contact_reminders(account_id, contact.id) == []
  end

  test "an inactive reminder is shown; first_met has no delete button", %{
    conn: conn,
    contact: contact,
    user: user
  } do
    {:ok, _} =
      Kith.Reminders.create_reminder(user.account_id, user.id, %{
        "type" => "one_time",
        "title" => "Renew passport",
        "anchor_date" => ~D[2020-01-01],
        "active" => false,
        "contact_id" => contact.id
      })

    {:ok, contact} =
      Kith.Contacts.update_contact(contact, %{
        first_met_at: ~D[2012-09-01],
        first_met_reminder: true
      })

    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    html = view |> element("button[phx-click='toggle-more-drawer']") |> render_click()

    assert html =~ "Renew passport"
    assert html =~ "First met"
    first_met = Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)

    refute has_element?(
             view,
             "#reminders-#{contact.id} button[phx-click='delete'][phx-value-id='#{first_met.id}']"
           )
  end

  test "a crafted delete event cannot remove a derived reminder", %{conn: conn, contact: contact} do
    {:ok, contact} =
      Kith.Contacts.update_contact(contact, %{
        first_met_at: ~D[2012-09-01],
        first_met_reminder: true
      })

    first_met = Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    view |> element("button[phx-click='toggle-more-drawer']") |> render_click()

    view
    |> with_target("#reminders-#{contact.id}")
    |> render_hook("delete", %{"id" => to_string(first_met.id)})

    render(view)
    assert Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
  end
end
