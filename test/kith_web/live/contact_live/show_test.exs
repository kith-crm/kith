defmodule KithWeb.ContactLive.ShowTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures
  import Kith.RemindersFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    seed_reference_data!()
    contact = contact_fixture(user.account_id)
    %{contact: contact, account_id: user.account_id}
  end

  describe "contact profile page" do
    test "renders hero banner with contact name", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ contact.display_name
    end

    test "renders activity stream", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "Activity"
      assert html =~ "Filter"
    end

    test "shows empty state when no activity", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "No activity yet"
    end

    test "more drawer toggles", %{conn: conn, contact: contact} do
      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")
      # More drawer is collapsed by default
      assert html =~ "Reminders, Pets, Debts"
      refute html =~ "No reminders set."

      # Click to expand
      html = view |> element("button[phx-click=toggle-more-drawer]") |> render_click()
      assert html =~ "Reminders"
    end

    test "favorite toggle works", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      view |> element("button[phx-click=toggle-favorite]") |> render_click()

      updated = Kith.Contacts.get_contact!(contact.account_id, contact.id)
      assert updated.favorite == true
    end
  end

  describe "activity stream" do
    test "notes appear in unified stream", %{conn: conn, contact: contact, user: user} do
      note_fixture(contact, user.id, %{"body" => "<p>Test note content</p>"})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "Test note content"
      assert html =~ "Note"
    end

    test "quick-add buttons are visible", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "+ Note"
      assert html =~ "+ Call"
      assert html =~ "+ Event"
    end
  end

  describe "sidebar sections" do
    test "basic info card renders", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "Basic Info"
    end

    test "addresses section works", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

      view |> element("#add-address-#{contact.id}") |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        address: %{
          line1: "456 Oak Ave",
          city: "Portland",
          province: "OR",
          postal_code: "97201",
          country: "US"
        }
      })
      |> render_submit()

      addresses = Kith.Contacts.list_addresses(contact.id)
      assert length(addresses) == 1
      assert hd(addresses).line1 == "456 Oak Ave"

      html = render(view)
      assert html =~ "456 Oak Ave"
    end

    test "contact fields section works", %{conn: conn, contact: contact, account_id: account_id} do
      [email_type | _] = Kith.Contacts.list_contact_field_types(account_id)

      {:ok, _field} =
        Kith.Contacts.create_contact_field(
          Kith.Contacts.get_contact!(account_id, contact.id),
          %{"value" => "jane@example.com", "contact_field_type_id" => email_type.id}
        )

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "jane@example.com"
    end
  end

  describe "birthday badge" do
    test "a 29 February birthday renders the expected next-birthday text in any year", %{
      conn: conn,
      account_id: account_id
    } do
      today = Date.utc_today()

      # Independent of the production helper: in a common year the anniversary is 28 Feb.
      next =
        [today.year, today.year + 1]
        |> Enum.map(&Date.new!(&1, 2, if(Calendar.ISO.leap_year?(&1), do: 29, else: 28)))
        |> Enum.find(&(Date.compare(&1, today) != :lt))

      days = Date.diff(next, today)

      expected =
        cond do
          days == 0 -> "Birthday today"
          days == 1 -> "Birthday tomorrow"
          true -> "Birthday in #{days} days"
        end

      leap = contact_fixture(account_id, %{birthdate: ~D[1992-02-29]})
      {:ok, _view, html} = live(conn, ~p"/contacts/#{leap.id}")
      assert html =~ expected
    end

    test "shows birthday badge when contact has birthdate", %{conn: conn, account_id: account_id} do
      birthday_contact =
        contact_fixture(account_id, %{birthdate: Date.add(Date.utc_today(), 5)})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{birthday_contact.id}")
      assert html =~ "Birthday in 5 days"
    end

    test "shows birthday today badge", %{conn: conn, account_id: account_id} do
      today = Date.utc_today()
      # Same month/day but a past year ensures birthday is today
      birthdate = %{today | year: today.year - 30}

      birthday_contact = contact_fixture(account_id, %{birthdate: birthdate})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{birthday_contact.id}")
      assert html =~ "Birthday today"
    end

    test "no birthday badge when no birthdate set", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      refute html =~ "Birthday"
    end
  end

  describe "reminders section" do
    test "shows existing reminders in more drawer", %{
      conn: conn,
      contact: contact,
      account_id: account_id,
      user: user
    } do
      reminder_fixture(account_id, contact.id, user.id, %{title: "Call them back"})

      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      html = view |> element("button[phx-click=toggle-more-drawer]") |> render_click()
      assert html =~ "Call them back"
    end

    test "shows Add button in reminders section", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      html = view |> element("button[phx-click=toggle-more-drawer]") |> render_click()
      assert html =~ "Add"
    end

    test "can create a reminder via the context", %{
      conn: conn,
      contact: contact,
      account_id: account_id,
      user: user
    } do
      # Create reminder via context and verify it appears in the UI
      next_date = Date.add(Date.utc_today(), 7)

      {:ok, _reminder} =
        Kith.Reminders.create_reminder(account_id, user.id, %{
          "type" => "one_time",
          "title" => "Follow up call",
          "next_reminder_date" => next_date,
          "contact_id" => contact.id,
          "account_id" => account_id,
          "creator_id" => user.id
        })

      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      html = view |> element("button[phx-click=toggle-more-drawer]") |> render_click()
      assert html =~ "Follow up call"

      # Verify the Add button renders (component CRUD is functional)
      assert html =~ "Add"
    end

    test "can delete a reminder via the context", %{
      contact: contact,
      account_id: account_id,
      user: user
    } do
      reminder = reminder_fixture(account_id, contact.id, user.id, %{title: "Delete me"})

      assert [_] = Kith.Reminders.list_reminders(account_id, contact.id)
      {:ok, _} = Kith.Reminders.delete_reminder(reminder)
      assert [] = Kith.Reminders.list_reminders(account_id, contact.id)
    end
  end

  describe "photo upload from timeline" do
    test "photo modal shows upload form instead of redirect", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

      # The photo button is in an Alpine dropdown. Find it by its phx attributes.
      view
      |> element(~s|button[phx-click="open-entry-modal"][phx-value-type="photo"]|)
      |> render_click()

      html = render(view)
      # Should show upload form, not a redirect link
      assert html =~ "Upload Photos"
      assert html =~ "photo-upload-form"
      refute html =~ "/edit#photos"
    end
  end
end
