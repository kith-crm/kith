defmodule KithWeb.API.StatisticsControllerTest do
  use KithWeb.ConnCase

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  defp authed_conn(conn, user) do
    Kith.AccountsFixtures.enable_optional_features(user, ~w(activities calls))
    {raw_token, _} = Kith.Accounts.generate_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  setup %{conn: conn} do
    user = user_fixture()
    conn = authed_conn(conn, user)
    %{conn: conn, user: user}
  end

  describe "GET /api/statistics" do
    test "returns statistics with correct keys", %{conn: conn} do
      conn = get(conn, ~p"/api/statistics")

      assert %{
               "data" =>
                 %{
                   "total_contacts" => _,
                   "total_notes" => _,
                   "total_activities" => _,
                   "total_calls" => _,
                   "account_created_at" => _
                 } = data
             } = json_response(conn, 200)

      assert is_integer(data["total_contacts"])
      assert is_integer(data["total_notes"])
      assert is_integer(data["total_activities"])
      assert is_integer(data["total_calls"])
    end

    test "counts match after creating resources", %{conn: conn, user: user} do
      # Create 3 contacts
      c1 = contact_fixture(user.account_id, %{})
      c2 = contact_fixture(user.account_id, %{})
      _c3 = contact_fixture(user.account_id, %{})

      # Create 2 notes
      {:ok, _} =
        Kith.Repo.insert(%Kith.Contacts.Note{
          contact_id: c1.id,
          account_id: user.account_id,
          body: "Note 1"
        })

      {:ok, _} =
        Kith.Repo.insert(%Kith.Contacts.Note{
          contact_id: c2.id,
          account_id: user.account_id,
          body: "Note 2"
        })

      conn = get(conn, ~p"/api/statistics")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["total_contacts"] == 3
      assert data["total_notes"] == 2
    end

    test "all roles can access statistics", %{conn: _conn} do
      # Create a viewer-role user
      user = user_fixture(%{role: "viewer"})
      conn = build_conn() |> authed_conn(user) |> get(~p"/api/statistics")
      assert %{"data" => _} = json_response(conn, 200)

      # Create an editor-role user
      user2 = user_fixture(%{role: "editor"})
      conn2 = build_conn() |> authed_conn(user2) |> get(~p"/api/statistics")
      assert %{"data" => _} = json_response(conn2, 200)

      # Create an admin-role user
      user3 = user_fixture(%{role: "admin"})
      conn3 = build_conn() |> authed_conn(user3) |> get(~p"/api/statistics")
      assert %{"data" => _} = json_response(conn3, 200)
    end
  end
end
