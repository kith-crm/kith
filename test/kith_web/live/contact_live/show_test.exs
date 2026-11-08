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

    test "note editing selects saved content and privacy and only updates that note", %{
      conn: conn,
      contact: contact,
      user: user
    } do
      first =
        note_fixture(contact, user.id, %{
          "body" => "<strong>First saved</strong>",
          "is_private" => true
        })

      second = note_fixture(contact, user.id, %{"body" => "<em>Second saved</em>"})
      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert html =~ "<strong>First saved</strong>"
      assert html =~ "<em>Second saved</em>"

      view
      |> element("button[phx-click=edit-entry][phx-value-id='#{first.id}'][phx-value-type=note]")
      |> render_click()

      assert has_element?(view, "input[name='entry[is_private]'][checked]")
      assert has_element?(view, "input[name='entry[body]'][value='<strong>First saved</strong>']")

      view
      |> form("form[phx-submit=save-entry]")
      |> render_submit(entry: %{body: "<del>Updated first</del>", is_private: "true"})

      assert Kith.Contacts.get_note!(contact.account_id, first.id, user.id).body ==
               "<del>Updated first</del>"

      assert Kith.Contacts.get_note!(contact.account_id, second.id, user.id).body ==
               "<em>Second saved</em>"

      view
      |> element("button[phx-click=edit-entry][phx-value-id='#{second.id}'][phx-value-type=note]")
      |> render_click()

      refute has_element?(view, "input[name='entry[is_private]'][checked]")
      assert has_element?(view, "input[name='entry[body]'][value='<em>Second saved</em>']")
    end

    test "invalid note submissions retain submitted privacy and editor value", %{
      conn: conn,
      contact: contact
    } do
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      view |> element("button[phx-click=open-entry-modal][phx-value-type=note]") |> render_click()

      view
      |> form("form[phx-submit=save-entry]")
      |> render_submit(entry: %{body: "   ", is_private: "true"})

      assert has_element?(view, "input[name='entry[body]'][value='   ']")
      assert has_element?(view, "input[name='entry[is_private]'][checked]")
      assert render(view) =~ "can&#39;t be blank"
    end

    test "private notes remain hidden from another account member", %{
      conn: conn,
      contact: contact,
      user: user
    } do
      other =
        Kith.AccountsFixtures.user_fixture()
        |> Ecto.Changeset.change(account_id: user.account_id)
        |> Kith.Repo.update!()

      note_fixture(contact, other.id, %{"body" => "Private secret", "is_private" => true})
      note_fixture(contact, other.id, %{"body" => "Shared note"})
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")
      refute html =~ "Private secret"
      assert html =~ "Shared note"
    end

    test "Note and Call are direct actions and Life Event is in the overflow menu", %{
      conn: conn,
      contact: contact
    } do
      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")
      assert has_element?(view, "#activity-stream button[phx-value-type='note']", "+ Note")
      assert has_element?(view, "#activity-stream button[phx-value-type='call']", "+ Call")
      refute html =~ "+ Event"

      assert has_element?(
               view,
               "#activity-stream button[aria-label='Add timeline entry'] + div[x-show='open'] button[phx-value-type='life_event']",
               "+ Life Event"
             )
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

  test "canonical contact field protocols render usable links", %{
    conn: conn,
    contact: contact,
    account_id: account_id
  } do
    for {protocol, value, target} <- [
          {"tel", "+12025550100", "tel:+12025550100"},
          {"mailto", "fixture@example.test", "mailto:fixture@example.test"},
          {"https", "example.test/profile", "https://example.test/profile"},
          {"http", "http://example.test/profile", "http://example.test/profile"}
        ] do
      {:ok, type} =
        Kith.Contacts.create_contact_field_type(account_id, %{
          name: "Canonical #{protocol}",
          protocol: protocol
        })

      {:ok, _} =
        Kith.Contacts.create_contact_field(contact, %{
          value: value,
          label: "Work",
          contact_field_type_id: type.id
        })

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      assert has_element?(view, "a[href='#{target}']")
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

  describe "timeline photo viewer" do
    test "storage backed thumbnails open one viewer in either layout", %{
      conn: conn,
      contact: contact
    } do
      filename = "MqkbdPlbb5ChW49ifnLKWcchWDhOSQEGwSbIfKvb.jpeg"
      photo = photo_fixture(contact, %{"file_name" => filename})
      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")
      refute html =~ filename

      assert has_element?(
               view,
               ~s(button[aria-label="View photo"] img[src="#{Kith.Storage.url(photo.storage_key)}"])
             )

      view |> element(~s(button[aria-label="View photo"])) |> render_click()
      assert has_element?(view, "#photo-modal img[src='#{Kith.Storage.url(photo.storage_key)}']")
      view |> with_target("#activity-stream") |> render_hook("close-photo", %{})
      refute has_element?(view, "#photo-modal")

      view
      |> element(~s(button[phx-click="filter-toggle"][phx-value-type="photo"]))
      |> render_click()

      assert has_element?(view, ~s(button[aria-label="View photo"] img))
      view |> element(~s(button[aria-label="View photo"])) |> render_click()
      assert has_element?(view, "#photo-modal")
      assert Kith.Contacts.get_photo!(contact.account_id, photo.id).file_name == filename
    end

    test "rejects foreign account and contact photo identifiers", %{conn: conn, contact: contact} do
      other_contact = contact_fixture(contact.account_id)
      foreign_user = Kith.AccountsFixtures.user_fixture()
      foreign_contact = contact_fixture(foreign_user.account_id)
      photos = [photo_fixture(other_contact), photo_fixture(foreign_contact)]
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")

      for photo <- photos do
        view
        |> with_target("#activity-stream")
        |> render_hook("open-photo", %{"id" => to_string(photo.id)})

        refute has_element?(view, "#photo-modal")
      end
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
