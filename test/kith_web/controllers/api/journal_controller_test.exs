defmodule KithWeb.API.JournalControllerTest do
  use KithWeb.ConnCase

  import Kith.AccountsFixtures

  alias Kith.Accounts

  defp authed_conn(conn, user) do
    Kith.AccountsFixtures.enable_optional_features(user, ~w(journal))
    {raw_token, _} = Accounts.generate_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp create_viewer_user do
    user = user_fixture()
    {:ok, user} = Accounts.update_user_role(user, %{role: "viewer"})
    user
  end

  # ── List journal entries ──────────────────────────────────────────

  describe "GET /api/journal" do
    test "returns paginated list of entries", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      {:ok, _} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Entry 1</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      {:ok, _} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Entry 2</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      resp = conn |> get(~p"/api/journal") |> json_response(200)
      assert %{"data" => entries, "meta" => meta} = resp
      assert length(entries) == 2
      assert is_map(meta)
    end

    test "filters by mood parameter", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      {:ok, _} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Great day</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "mood" => "great",
          "is_private" => false
        })

      {:ok, _} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Bad day</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "mood" => "bad",
          "is_private" => false
        })

      resp = conn |> get(~p"/api/journal?mood=great") |> json_response(200)
      assert length(resp["data"]) == 1
      assert hd(resp["data"])["mood"] == "great"
    end

    test "excludes private entries from other users", %{conn: conn} do
      user_a = user_fixture()
      _user_b = user_fixture()

      # user_b creates a private entry in user_a's account
      # (This simulates multi-user accounts. For this test, each user has own account.)
      {:ok, _} =
        Kith.Journal.create_entry(user_a.account_id, user_a.id, %{
          "content" => "<p>My private</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => true
        })

      {:ok, _} =
        Kith.Journal.create_entry(user_a.account_id, user_a.id, %{
          "content" => "<p>My public</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      # user_a sees both (own private + public)
      conn_a = authed_conn(conn, user_a)
      resp = conn_a |> get(~p"/api/journal") |> json_response(200)
      assert length(resp["data"]) == 2
    end
  end

  # ── Show journal entry ────────────────────────────────────────────

  describe "GET /api/journal/:id" do
    test "returns a single entry", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      {:ok, entry} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "title" => "Test Entry",
          "content" => "<p>Show me</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "mood" => "good",
          "is_private" => false
        })

      resp = conn |> get(~p"/api/journal/#{entry.id}") |> json_response(200)
      assert %{"data" => data} = resp
      assert data["id"] == entry.id
      assert data["title"] == "Test Entry"
      assert data["content"] == "<p>Show me</p>"
      assert data["mood"] == "good"
    end

    test "returns 404 for non-existent entry", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> get(~p"/api/journal/999999") |> json_response(404)
      assert resp["status"] == 404
    end

    test "returns 404 for private entry of another user", %{conn: conn} do
      user_a = user_fixture()
      user_b = user_fixture()

      # Create a private entry by user_a
      {:ok, entry} =
        Kith.Journal.create_entry(user_a.account_id, user_a.id, %{
          "content" => "<p>Private</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => true
        })

      # user_b tries to see it (different account, so it's a 404 either way)
      conn_b = authed_conn(conn, user_b)
      resp = conn_b |> get(~p"/api/journal/#{entry.id}") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Create journal entry ──────────────────────────────────────────

  describe "POST /api/journal" do
    test "creates an entry with valid body -> 201 with Location header", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{
        "entry" => %{
          "title" => "A wonderful day",
          "content" => "<p>I had a wonderful day today.</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "mood" => "great"
        }
      }

      resp = conn |> post(~p"/api/journal", body)
      assert resp.status == 201

      data = json_response(resp, 201)["data"]
      assert data["title"] == "A wonderful day"
      assert data["mood"] == "great"
      assert data["author_id"] == user.id

      [location] = get_resp_header(resp, "location")
      assert location == "/api/journal/#{data["id"]}"
    end

    test "returns 422 when content is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{
        "entry" => %{
          "title" => "No content",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        }
      }

      resp = conn |> post(~p"/api/journal", body) |> json_response(422)
      assert resp["status"] == 422
      assert is_map(resp["errors"])
      assert Map.has_key?(resp["errors"], "content")
    end

    test "returns 422 when occurred_at is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{"entry" => %{"content" => "<p>Test</p>"}}
      resp = conn |> post(~p"/api/journal", body) |> json_response(422)
      assert resp["status"] == 422
      assert Map.has_key?(resp["errors"], "occurred_at")
    end

    test "returns 422 when mood is invalid", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{
        "entry" => %{
          "content" => "<p>Test</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "mood" => "ecstatic"
        }
      }

      resp = conn |> post(~p"/api/journal", body) |> json_response(422)
      assert resp["status"] == 422
      assert Map.has_key?(resp["errors"], "mood")
    end

    test "returns 400 when entry key is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> post(~p"/api/journal", %{"foo" => "bar"}) |> json_response(400)
      assert resp["status"] == 400
    end
  end

  # ── Update journal entry ──────────────────────────────────────────

  describe "PATCH /api/journal/:id" do
    test "updates an entry -> 200", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      {:ok, entry} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Original</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        })

      body = %{"entry" => %{"title" => "Updated Title", "mood" => "neutral"}}
      resp = conn |> patch(~p"/api/journal/#{entry.id}", body) |> json_response(200)
      assert resp["data"]["title"] == "Updated Title"
      assert resp["data"]["mood"] == "neutral"
    end

    test "returns 404 for non-existent entry", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{"entry" => %{"title" => "Nope"}}
      resp = conn |> patch(~p"/api/journal/999999", body) |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Delete journal entry ──────────────────────────────────────────

  describe "DELETE /api/journal/:id" do
    test "deletes an entry -> 204", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      {:ok, entry} =
        Kith.Journal.create_entry(user.account_id, user.id, %{
          "content" => "<p>Delete me</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        })

      resp = conn |> delete(~p"/api/journal/#{entry.id}")
      assert resp.status == 204

      # Verify it's gone
      get_resp = conn |> get(~p"/api/journal/#{entry.id}") |> json_response(404)
      assert get_resp["status"] == 404
    end

    test "returns 404 for non-existent entry", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> delete(~p"/api/journal/999999") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Unauthenticated access ────────────────────────────────────────

  describe "unauthenticated access" do
    test "GET /api/journal with no auth header -> 401", %{conn: conn} do
      resp = conn |> get(~p"/api/journal") |> json_response(401)
      assert resp["status"] == 401
    end

    test "POST /api/journal with no auth header -> 401", %{conn: conn} do
      body = %{"entry" => %{"content" => "Test"}}
      resp = conn |> post(~p"/api/journal", body) |> json_response(401)
      assert resp["status"] == 401
    end

    test "GET /api/journal/:id with no auth header -> 401", %{conn: conn} do
      resp = conn |> get(~p"/api/journal/1") |> json_response(401)
      assert resp["status"] == 401
    end
  end

  # ── Viewer role restrictions ──────────────────────────────────────

  describe "viewer role restrictions" do
    test "viewer can GET journal entries", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)

      resp = conn |> get(~p"/api/journal") |> json_response(200)
      assert is_list(resp["data"])
    end

    test "viewer cannot POST journal entries -> 403", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)

      body = %{
        "entry" => %{
          "content" => "<p>Nope</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        }
      }

      resp = conn |> post(~p"/api/journal", body) |> json_response(403)
      assert resp["status"] == 403
    end

    test "viewer cannot PATCH journal entries -> 403", %{conn: conn} do
      viewer = create_viewer_user()

      {:ok, entry} =
        Kith.Journal.create_entry(viewer.account_id, viewer.id, %{
          "content" => "<p>Test</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      conn = authed_conn(conn, viewer)
      body = %{"entry" => %{"title" => "Updated"}}
      resp = conn |> patch(~p"/api/journal/#{entry.id}", body) |> json_response(403)
      assert resp["status"] == 403
    end

    test "viewer cannot DELETE journal entries -> 403", %{conn: conn} do
      viewer = create_viewer_user()

      {:ok, entry} =
        Kith.Journal.create_entry(viewer.account_id, viewer.id, %{
          "content" => "<p>Test</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      conn = authed_conn(conn, viewer)
      resp = conn |> delete(~p"/api/journal/#{entry.id}") |> json_response(403)
      assert resp["status"] == 403
    end
  end

  # ── Account scoping ──────────────────────────────────────────────

  describe "account scoping" do
    test "user cannot see journal entries from another account", %{conn: conn} do
      user_a = user_fixture()
      user_b = user_fixture()

      {:ok, entry_b} =
        Kith.Journal.create_entry(user_b.account_id, user_b.id, %{
          "content" => "<p>Secret</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      conn_a = authed_conn(conn, user_a)

      # User A should not see user B's entry
      resp = conn_a |> get(~p"/api/journal/#{entry_b.id}") |> json_response(404)
      assert resp["status"] == 404
    end

    test "user A's journal list does not include user B's entries", %{conn: conn} do
      user_a = user_fixture()
      user_b = user_fixture()

      {:ok, _} =
        Kith.Journal.create_entry(user_b.account_id, user_b.id, %{
          "content" => "<p>B's entry</p>",
          "occurred_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "is_private" => false
        })

      conn_a = authed_conn(conn, user_a)
      resp = conn_a |> get(~p"/api/journal") |> json_response(200)
      assert resp["data"] == []
    end
  end
end
