defmodule KithWeb.ContactLive.AboutComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    %{contact: contact_fixture(user.account_id)}
  end

  defp edit(conn, contact) do
    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    view |> element("#about-#{contact.id} button", "Edit") |> render_click()
    view
  end

  test "checking the box creates the anniversary reminder; unchecking deletes it", %{
    conn: conn,
    contact: contact
  } do
    view = edit(conn, contact)

    view
    |> element("#about-#{contact.id} form")
    |> render_submit(%{contact: %{first_met_at: "2012-09-01", first_met_reminder: "true"}})

    assert Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
    stop_view(view)

    view = edit(conn, contact)

    # form/3 unchecks the (checked) checkbox with `false`; the value submitted
    # is then the hidden input's "false" taken from the markup.
    view
    |> form("#about-#{contact.id} form", %{
      contact: %{first_met_at: "2012-09-01", first_met_reminder: false}
    })
    |> render_submit()

    refute Kith.Reminders.get_first_met_reminder(contact.id, contact.account_id)
    stop_view(view)
  end

  test "the edit form renders a hidden false input before the checkbox", %{
    conn: conn,
    contact: contact
  } do
    view = edit(conn, contact)
    html = view |> element("#about-#{contact.id} form") |> render()

    assert html =~ ~s(name="contact[first_met_reminder]")
    assert html =~ "Remind me every year"
    assert html =~ ~r/type="hidden"[^>]*value="false"|value="false"[^>]*type="hidden"/
    stop_view(view)
  end

  defp stop_view(view) do
    # Saving sends a follow-up :contact_updated message that reloads database
    # associations. Drain that message and stop the view before its sandbox
    # owner exits; the test process ending can otherwise kill an active query.
    render(view)
    GenServer.stop(view.pid, :normal)
    refute Process.alive?(view.pid)
  end
end
