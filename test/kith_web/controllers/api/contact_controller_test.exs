defmodule KithWeb.API.ContactControllerTest do
  use KithWeb.ConnCase

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Accounts

  # Helper to get an authenticated conn
  defp authed_conn(conn, user) do
    {raw_token, _} = Accounts.generate_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp create_viewer_user do
    user = user_fixture()
    {:ok, user} = Accounts.update_user_role(user, %{role: "viewer"})
    user
  end

  # ── Pagination (TEST-10-01) ──────────────────────────────────────────

  describe "GET /api/contacts pagination (TEST-10-01)" do
    test "paginates contacts with limit=10 across 3 pages, no duplicates", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      # Create 25 contacts
      _contacts =
        for i <- 1..25 do
          contact_fixture(user.account_id, %{first_name: "Contact", last_name: "#{i}"})
        end

      # Page 1
      resp1 = conn |> get(~p"/api/contacts?limit=10") |> json_response(200)
      assert length(resp1["data"]) == 10
      assert resp1["meta"]["has_more"] == true
      assert resp1["meta"]["next_cursor"] != nil

      # Page 2
      resp2 =
        conn
        |> get(~p"/api/contacts?limit=10&after=#{resp1["meta"]["next_cursor"]}")
        |> json_response(200)

      assert length(resp2["data"]) == 10
      assert resp2["meta"]["has_more"] == true
      assert resp2["meta"]["next_cursor"] != nil

      # Page 3
      resp3 =
        conn
        |> get(~p"/api/contacts?limit=10&after=#{resp2["meta"]["next_cursor"]}")
        |> json_response(200)

      assert length(resp3["data"]) == 5
      assert resp3["meta"]["has_more"] == false
      assert resp3["meta"]["next_cursor"] == nil

      # No duplicates across all pages
      all_ids =
        Enum.map(resp1["data"], & &1["id"]) ++
          Enum.map(resp2["data"], & &1["id"]) ++
          Enum.map(resp3["data"], & &1["id"])

      assert length(Enum.uniq(all_ids)) == 25
    end
  end

  # ── Create contact (TEST-10-03) ─────────────────────────────────────

  describe "POST /api/contacts (TEST-10-03)" do
    test "creates a contact with valid body → 201 with Location header", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{
        "contact" => %{
          "first_name" => "Alice",
          "last_name" => "Wonder",
          "nickname" => "Ali"
        }
      }

      resp = conn |> post(~p"/api/contacts", body)

      assert resp.status == 201
      data = json_response(resp, 201)["data"]
      assert data["first_name"] == "Alice"
      assert data["last_name"] == "Wonder"
      assert data["nickname"] == "Ali"
      assert data["id"] != nil

      # Verify Location header
      [location] = get_resp_header(resp, "location")
      assert location == "/api/contacts/#{data["id"]}"
    end

    test "returns 422 when first_name is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{"contact" => %{"last_name" => "NoFirst"}}
      resp = conn |> post(~p"/api/contacts", body) |> json_response(422)

      # RFC 7807 format
      assert resp["type"] == "about:blank"
      assert resp["title"] == "Unprocessable Entity"
      assert resp["status"] == 422
      assert is_map(resp["errors"])
      assert Map.has_key?(resp["errors"], "first_name")
    end
  end

  # ── Update contact (TEST-10-04) ─────────────────────────────────────

  describe "PATCH /api/contacts/:id (TEST-10-04)" do
    test "updates a contact field → 200", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id, %{first_name: "Before"})

      body = %{"contact" => %{"first_name" => "After"}}
      resp = conn |> patch(~p"/api/contacts/#{contact.id}", body) |> json_response(200)

      assert resp["data"]["first_name"] == "After"
      assert resp["data"]["id"] == contact.id
    end
  end

  # ── Soft-delete (TEST-10-05) ────────────────────────────────────────

  describe "DELETE /api/contacts/:id (TEST-10-05)" do
    test "soft-deletes a contact → 204, then GET returns 404", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      # Delete returns 204
      delete_resp = conn |> delete(~p"/api/contacts/#{contact.id}")
      assert delete_resp.status == 204

      # GET now returns 404
      get_resp = conn |> get(~p"/api/contacts/#{contact.id}") |> json_response(404)
      assert get_resp["status"] == 404
      assert get_resp["type"] == "about:blank"
    end
  end

  # ── Merge (TEST-10-06) ─────────────────────────────────────────────

  describe "POST /api/contacts/merge (TEST-10-06)" do
    test "merges two contacts, survivor has data, non-survivor → 404", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      survivor =
        contact_fixture(user.account_id, %{first_name: "Survivor", last_name: "Smith"})

      non_survivor =
        contact_fixture(user.account_id, %{first_name: "NonSurvivor", last_name: "Jones"})

      body = %{
        "survivor_id" => survivor.id,
        "non_survivor_id" => non_survivor.id
      }

      resp = conn |> post(~p"/api/contacts/merge", body) |> json_response(200)
      assert resp["data"]["id"] == survivor.id
      assert resp["data"]["first_name"] == "Survivor"

      # Non-survivor should be gone (soft-deleted)
      get_resp = conn |> get(~p"/api/contacts/#{non_survivor.id}") |> json_response(404)
      assert get_resp["status"] == 404
    end

    test "keeps the survivor's value when the non-survivor is newer, and fills gaps", %{
      conn: conn
    } do
      user = user_fixture()
      conn = authed_conn(conn, user)

      survivor =
        contact_fixture(user.account_id, %{
          first_name: "Survivor",
          last_name: "Smith",
          middle_name: nil
        })

      non_survivor =
        contact_fixture(user.account_id, %{
          first_name: "NonSurvivor",
          last_name: "Jones",
          middle_name: "Filled"
        })

      # The resolver breaks a 1-1 conflict by most-recently-updated, so make the
      # non-survivor unambiguously newer: without the survivor-value protection
      # this merge renames the survivor to "NonSurvivor".
      Kith.Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^non_survivor.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)]
      )

      body = %{"survivor_id" => survivor.id, "non_survivor_id" => non_survivor.id}

      resp = conn |> post(~p"/api/contacts/merge", body) |> json_response(200)

      assert resp["data"]["first_name"] == "Survivor"
      assert resp["data"]["last_name"] == "Smith"
      # A field the survivor had no value for is still gap-filled (design spec §6).
      assert resp["data"]["middle_name"] == "Filled"
    end
  end

  # ── Archive (TEST-10-17) ───────────────────────────────────────────

  describe "archive/unarchive (TEST-10-17)" do
    test "POST archive → archived:true, excluded from index, included with ?archived=true, DELETE restores",
         %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id, %{first_name: "Archivable"})

      # Archive the contact
      archive_resp =
        conn
        |> post(~p"/api/contacts/#{contact.id}/archive")
        |> json_response(200)

      assert archive_resp["data"]["archived"] == true

      # Default GET excludes archived contacts
      index_resp = conn |> get(~p"/api/contacts") |> json_response(200)
      ids = Enum.map(index_resp["data"], & &1["id"])
      refute contact.id in ids

      # GET with ?archived=true includes it
      archived_resp =
        conn |> get(~p"/api/contacts?archived=true") |> json_response(200)

      archived_ids = Enum.map(archived_resp["data"], & &1["id"])
      assert contact.id in archived_ids

      # Unarchive (DELETE archive) restores it
      unarchive_resp =
        conn
        |> delete(~p"/api/contacts/#{contact.id}/archive")
        |> json_response(200)

      assert unarchive_resp["data"]["archived"] == false
    end
  end

  # ── Archived filter (TEST-10-18/19) ────────────────────────────────

  describe "archived filter (TEST-10-18/19)" do
    test "default excludes archived, ?archived=true shows only archived", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      normal = contact_fixture(user.account_id, %{first_name: "Normal"})

      archived_contact = contact_fixture(user.account_id, %{first_name: "Archived"})

      conn |> post(~p"/api/contacts/#{archived_contact.id}/archive") |> json_response(200)

      # Default: only non-archived
      default_resp = conn |> get(~p"/api/contacts") |> json_response(200)
      default_ids = Enum.map(default_resp["data"], & &1["id"])
      assert normal.id in default_ids
      refute archived_contact.id in default_ids

      # ?archived=true: only archived
      archived_resp = conn |> get(~p"/api/contacts?archived=true") |> json_response(200)
      archived_ids = Enum.map(archived_resp["data"], & &1["id"])
      assert archived_contact.id in archived_ids
      refute normal.id in archived_ids
    end
  end

  # ── Favorite ───────────────────────────────────────────────────────

  describe "favorite/unfavorite" do
    test "POST favorite → favorite:true, DELETE → favorite:false", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      # Favorite
      fav_resp =
        conn
        |> post(~p"/api/contacts/#{contact.id}/favorite")
        |> json_response(200)

      assert fav_resp["data"]["favorite"] == true

      # Unfavorite
      unfav_resp =
        conn
        |> delete(~p"/api/contacts/#{contact.id}/favorite")
        |> json_response(200)

      assert unfav_resp["data"]["favorite"] == false
    end
  end

  # ── Unauthenticated (TEST-10-11) ──────────────────────────────────

  describe "unauthenticated access (TEST-10-11)" do
    test "GET /api/contacts with no auth header → 401 RFC 7807", %{conn: conn} do
      resp = conn |> get(~p"/api/contacts") |> json_response(401)

      assert resp["type"] == "about:blank"
      assert resp["title"] == "Unauthorized"
      assert resp["status"] == 401
    end
  end

  # ── Viewer role (TEST-10-12) ──────────────────────────────────────

  describe "viewer role restrictions (TEST-10-12)" do
    test "viewer can GET contacts", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)

      # Create a contact in the account (using Repo directly since viewer can't POST)
      contact = contact_fixture(viewer.account_id, %{first_name: "Visible"})

      resp = conn |> get(~p"/api/contacts") |> json_response(200)
      ids = Enum.map(resp["data"], & &1["id"])
      assert contact.id in ids
    end

    test "viewer cannot POST contacts → 403", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)

      body = %{"contact" => %{"first_name" => "Nope"}}
      resp = conn |> post(~p"/api/contacts", body) |> json_response(403)

      assert resp["type"] == "about:blank"
      assert resp["status"] == 403
    end

    test "viewer cannot PATCH contacts → 403", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)
      contact = contact_fixture(viewer.account_id)

      body = %{"contact" => %{"first_name" => "Nope"}}
      resp = conn |> patch(~p"/api/contacts/#{contact.id}", body) |> json_response(403)

      assert resp["status"] == 403
    end

    test "viewer cannot DELETE contacts → 403", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)
      contact = contact_fixture(viewer.account_id)

      resp = conn |> delete(~p"/api/contacts/#{contact.id}") |> json_response(403)
      assert resp["status"] == 403
    end
  end

  # ── Account scoping ────────────────────────────────────────────────

  describe "account scoping" do
    test "user A cannot see user B's contacts", %{conn: conn} do
      user_a = user_fixture()
      user_b = user_fixture()

      # Create contact in user B's account
      contact_b = contact_fixture(user_b.account_id, %{first_name: "SecretB"})

      conn_a = authed_conn(conn, user_a)

      # User A listing should not contain user B's contact
      resp = conn_a |> get(~p"/api/contacts") |> json_response(200)
      ids = Enum.map(resp["data"], & &1["id"])
      refute contact_b.id in ids

      # User A fetching by ID should get 404
      get_resp = conn_a |> get(~p"/api/contacts/#{contact_b.id}") |> json_response(404)
      assert get_resp["status"] == 404
    end
  end
end
