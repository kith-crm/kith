defmodule KithWeb.API.ReminderControllerTest do
  use KithWeb.ConnCase

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  defp authed_conn(conn, user) do
    {raw_token, _} = Kith.Accounts.generate_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp create_reminder_via_api(conn, contact_id, attrs \\ %{}) do
    default = %{
      "title" => "Birthday",
      "type" => "one_time",
      "next_reminder_date" => Date.to_iso8601(Date.add(Date.utc_today(), 15))
    }

    post(conn, ~p"/api/contacts/#{contact_id}/reminders", %{
      "reminder" => Map.merge(default, attrs)
    })
  end

  setup %{conn: conn} do
    user = user_fixture()
    contact = contact_fixture(user.account_id, %{})
    conn = authed_conn(conn, user)
    %{conn: conn, user: user, contact: contact}
  end

  describe "POST /api/contacts/:contact_id/reminders" do
    test "creates a reminder and returns 201", %{conn: conn, contact: contact} do
      conn = create_reminder_via_api(conn, contact.id)

      assert %{"data" => %{"id" => id, "title" => "Birthday", "type" => "one_time"}} =
               json_response(conn, 201)

      assert is_integer(id)
    end
  end

  describe "GET /api/contacts/:contact_id/reminders" do
    test "lists reminders for a contact", %{conn: conn, user: user, contact: contact} do
      create_reminder_via_api(conn, contact.id, %{"title" => "R1"})

      _conn2 =
        build_conn()
        |> authed_conn(user)
        |> create_reminder_via_api(contact.id, %{"title" => "R2"})

      conn3 =
        build_conn()
        |> authed_conn(user)
        |> get(~p"/api/contacts/#{contact.id}/reminders")

      assert %{"data" => reminders} = json_response(conn3, 200)
      assert length(reminders) == 2
    end
  end

  describe "GET /api/reminders/upcoming" do
    test "with window=30 returns only near-future reminders", %{
      conn: conn,
      user: user,
      contact: contact
    } do
      # Create a reminder 15 days from now (within 30-day window)
      create_reminder_via_api(conn, contact.id, %{
        "title" => "Soon",
        "next_reminder_date" => Date.to_iso8601(Date.add(Date.utc_today(), 15))
      })

      # Create a reminder 45 days from now (outside 30-day window)
      _conn2 =
        build_conn()
        |> authed_conn(user)
        |> create_reminder_via_api(contact.id, %{
          "title" => "Later",
          "next_reminder_date" => Date.to_iso8601(Date.add(Date.utc_today(), 45))
        })

      conn3 =
        build_conn()
        |> authed_conn(user)
        |> get(~p"/api/reminders/upcoming?window=30")

      assert %{"data" => reminders} = json_response(conn3, 200)
      titles = Enum.map(reminders, & &1["title"])
      assert "Soon" in titles
      refute "Later" in titles
    end

    test "with window=60 includes further-out reminders", %{
      conn: conn,
      user: user,
      contact: contact
    } do
      create_reminder_via_api(conn, contact.id, %{
        "title" => "Soon",
        "next_reminder_date" => Date.to_iso8601(Date.add(Date.utc_today(), 15))
      })

      _conn2 =
        build_conn()
        |> authed_conn(user)
        |> create_reminder_via_api(contact.id, %{
          "title" => "MidRange",
          "next_reminder_date" => Date.to_iso8601(Date.add(Date.utc_today(), 45))
        })

      conn3 =
        build_conn()
        |> authed_conn(user)
        |> get(~p"/api/reminders/upcoming?window=60")

      assert %{"data" => reminders} = json_response(conn3, 200)
      titles = Enum.map(reminders, & &1["title"])
      assert "Soon" in titles
      assert "MidRange" in titles
    end

    test "invalid window value returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/reminders/upcoming?window=999")
      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "PATCH /api/reminders/:id" do
    test "updates a reminder", %{conn: conn, user: user, contact: contact} do
      resp = create_reminder_via_api(conn, contact.id, %{"title" => "Original"})
      %{"data" => %{"id" => id}} = json_response(resp, 201)

      conn2 =
        build_conn()
        |> authed_conn(user)
        |> patch(~p"/api/reminders/#{id}", %{"reminder" => %{"title" => "Updated"}})

      assert %{"data" => %{"title" => "Updated"}} = json_response(conn2, 200)
    end
  end

  describe "DELETE /api/reminders/:id" do
    test "deletes a reminder and returns 204", %{conn: conn, user: user, contact: contact} do
      resp = create_reminder_via_api(conn, contact.id)
      %{"data" => %{"id" => id}} = json_response(resp, 201)

      conn2 =
        build_conn()
        |> authed_conn(user)
        |> delete(~p"/api/reminders/#{id}")

      assert conn2.status == 204
    end
  end

  describe "schedule fields" do
    test "create accepts a preset and returns interval fields", %{conn: conn, contact: contact} do
      conn =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{
            "type" => "recurring",
            "title" => "Rent",
            "frequency" => "monthly",
            "anchor_date" => "2024-02-01"
          }
        })

      data = json_response(conn, 201)["data"]
      assert data["frequency"] == "monthly"
      assert data["interval_unit"] == "month"
      assert data["interval_count"] == 1
      assert data["anchor_date"] == "2024-02-01"
      assert Date.compare(Date.from_iso8601!(data["next_reminder_date"]), Date.utc_today()) != :lt
    end

    test "create accepts unit + count outside the presets", %{conn: conn, contact: contact} do
      conn =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{
            "type" => "recurring",
            "title" => "Every 3 weeks",
            "interval_unit" => "week",
            "interval_count" => 3,
            "anchor_date" => Date.to_iso8601(Date.utc_today())
          }
        })

      data = json_response(conn, 201)["data"]
      assert data["frequency"] == nil
      assert {data["interval_unit"], data["interval_count"]} == {"week", 3}
    end

    test "birthday reminders can't be created, edited or deleted", %{conn: conn, contact: contact} do
      conn1 =
        post(conn, ~p"/api/contacts/#{contact.id}/reminders", %{
          "reminder" => %{"type" => "birthday", "anchor_date" => "1990-06-15"}
        })

      assert json_response(conn1, 422)

      {:ok, contact} = Kith.Contacts.update_contact(contact, %{birthdate: ~D[1990-06-15]})
      birthday = Kith.Reminders.get_birthday_reminder(contact.id, contact.account_id)

      conn2 = patch(conn, ~p"/api/reminders/#{birthday.id}", %{"reminder" => %{"title" => "x"}})
      assert json_response(conn2, 422)

      conn3 = delete(conn, ~p"/api/reminders/#{birthday.id}")
      assert json_response(conn3, 422)
    end
  end
end
