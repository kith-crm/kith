defmodule KithWeb.API.TaskControllerTest do
  use KithWeb.ConnCase

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Accounts

  defp authed_conn(conn, user) do
    Kith.AccountsFixtures.enable_optional_features(user, ~w(tasks))
    {raw_token, _} = Accounts.generate_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{raw_token}")
  end

  defp create_viewer_user do
    user = user_fixture()
    {:ok, user} = Accounts.update_user_role(user, %{role: "viewer"})
    user
  end

  # ── List tasks for a contact ─────────────────────────────────────

  describe "GET /api/contacts/:contact_id/tasks" do
    test "returns paginated list of tasks", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      # Create tasks using the context so they're properly scoped
      {:ok, _task1} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Task 1",
          "contact_id" => contact.id,
          "is_private" => false
        })

      {:ok, _task2} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Task 2",
          "contact_id" => contact.id,
          "is_private" => false
        })

      resp = conn |> get(~p"/api/contacts/#{contact.id}/tasks") |> json_response(200)
      assert %{"data" => tasks, "meta" => meta} = resp
      assert length(tasks) == 2
      assert is_map(meta)
    end

    test "returns 404 for non-existent contact", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> get(~p"/api/contacts/999999/tasks") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Show task ──────────────────────────────────────────────────────

  describe "GET /api/tasks/:id" do
    test "returns a single task", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Show me",
          "contact_id" => contact.id,
          "is_private" => false
        })

      resp = conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
      assert %{"data" => %{"id" => _, "title" => "Show me"}} = resp
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> get(~p"/api/tasks/999999") |> json_response(404)
      assert resp["status"] == 404
    end

    test "returns 404 for private task created by another user", %{conn: conn} do
      user1 = user_fixture()
      # Create a second user in the same account
      user2 = user_fixture()

      contact = contact_fixture(user1.account_id)

      {:ok, private_task} =
        Kith.Tasks.create_task(user1.account_id, user1.id, %{
          "title" => "Private task",
          "contact_id" => contact.id,
          "is_private" => true
        })

      conn2 = authed_conn(conn, user2)
      resp = conn2 |> get(~p"/api/tasks/#{private_task.id}") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Create task ────────────────────────────────────────────────────

  describe "POST /api/contacts/:contact_id/tasks" do
    test "creates a task with valid body -> 201 with Location header", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      body = %{
        "task" => %{
          "title" => "Buy groceries",
          "description" => "Milk, eggs, bread",
          "priority" => "high"
        }
      }

      resp = conn |> post(~p"/api/contacts/#{contact.id}/tasks", body)
      assert resp.status == 201

      data = json_response(resp, 201)["data"]
      assert data["title"] == "Buy groceries"
      assert data["priority"] == "high"
      assert data["status"] == "pending"
      assert data["contact_id"] == contact.id

      [location] = get_resp_header(resp, "location")
      assert location == "/api/tasks/#{data["id"]}"
    end

    test "returns 422 when title is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      body = %{"task" => %{"description" => "No title"}}
      resp = conn |> post(~p"/api/contacts/#{contact.id}/tasks", body) |> json_response(422)

      assert resp["status"] == 422
      assert is_map(resp["errors"])
      assert Map.has_key?(resp["errors"], "title")
    end

    test "returns 400 when task key is missing", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      resp = conn |> post(~p"/api/contacts/#{contact.id}/tasks", %{}) |> json_response(400)
      assert resp["status"] == 400
    end

    test "returns 404 for non-existent contact", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{"task" => %{"title" => "Test"}}
      resp = conn |> post(~p"/api/contacts/999999/tasks", body) |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Update task ────────────────────────────────────────────────────

  describe "PATCH /api/tasks/:id" do
    test "updates a task -> 200", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Original",
          "contact_id" => contact.id
        })

      body = %{"task" => %{"title" => "Updated", "priority" => "low"}}
      resp = conn |> patch(~p"/api/tasks/#{task.id}", body) |> json_response(200)

      assert resp["data"]["title"] == "Updated"
      assert resp["data"]["priority"] == "low"
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      body = %{"task" => %{"title" => "Nope"}}
      resp = conn |> patch(~p"/api/tasks/999999", body) |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Delete task ────────────────────────────────────────────────────

  describe "DELETE /api/tasks/:id" do
    test "deletes a task -> 204", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Delete me",
          "contact_id" => contact.id
        })

      resp = conn |> delete(~p"/api/tasks/#{task.id}")
      assert resp.status == 204

      # Verify it's gone
      get_resp = conn |> get(~p"/api/tasks/#{task.id}") |> json_response(404)
      assert get_resp["status"] == 404
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> delete(~p"/api/tasks/999999") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Complete task ──────────────────────────────────────────────────

  describe "POST /api/tasks/:id/complete" do
    test "marks a task as completed -> 200", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)
      contact = contact_fixture(user.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(user.account_id, user.id, %{
          "title" => "Complete me",
          "contact_id" => contact.id
        })

      resp = conn |> post(~p"/api/tasks/#{task.id}/complete") |> json_response(200)
      assert resp["data"]["status"] == "completed"
      assert resp["data"]["completed_at"] != nil
    end

    test "returns 404 for non-existent task", %{conn: conn} do
      user = user_fixture()
      conn = authed_conn(conn, user)

      resp = conn |> post(~p"/api/tasks/999999/complete") |> json_response(404)
      assert resp["status"] == 404
    end
  end

  # ── Unauthenticated access ────────────────────────────────────────

  describe "unauthenticated access" do
    test "GET /api/contacts/:id/tasks with no auth header -> 401", %{conn: conn} do
      resp = conn |> get(~p"/api/contacts/1/tasks") |> json_response(401)
      assert resp["status"] == 401
    end

    test "POST /api/contacts/:id/tasks with no auth header -> 401", %{conn: conn} do
      body = %{"task" => %{"title" => "Test"}}
      resp = conn |> post(~p"/api/contacts/1/tasks", body) |> json_response(401)
      assert resp["status"] == 401
    end

    test "GET /api/tasks/:id with no auth header -> 401", %{conn: conn} do
      resp = conn |> get(~p"/api/tasks/1") |> json_response(401)
      assert resp["status"] == 401
    end
  end

  # ── Viewer role restrictions ──────────────────────────────────────

  describe "viewer role restrictions" do
    test "viewer can GET tasks", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)
      contact = contact_fixture(viewer.account_id)

      resp = conn |> get(~p"/api/contacts/#{contact.id}/tasks") |> json_response(200)
      assert is_list(resp["data"])
    end

    test "viewer cannot POST tasks -> 403", %{conn: conn} do
      viewer = create_viewer_user()
      conn = authed_conn(conn, viewer)
      contact = contact_fixture(viewer.account_id)

      body = %{"task" => %{"title" => "Nope"}}
      resp = conn |> post(~p"/api/contacts/#{contact.id}/tasks", body) |> json_response(403)
      assert resp["status"] == 403
    end

    test "viewer cannot PATCH tasks -> 403", %{conn: conn} do
      viewer = create_viewer_user()
      _admin = user_fixture(%{email: "admin-#{System.unique_integer()}@example.com"})
      contact = contact_fixture(viewer.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(viewer.account_id, viewer.id, %{
          "title" => "Test",
          "contact_id" => contact.id,
          "is_private" => false
        })

      conn = authed_conn(conn, viewer)
      body = %{"task" => %{"title" => "Updated"}}
      resp = conn |> patch(~p"/api/tasks/#{task.id}", body) |> json_response(403)
      assert resp["status"] == 403
    end

    test "viewer cannot DELETE tasks -> 403", %{conn: conn} do
      viewer = create_viewer_user()
      contact = contact_fixture(viewer.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(viewer.account_id, viewer.id, %{
          "title" => "Test",
          "contact_id" => contact.id,
          "is_private" => false
        })

      conn = authed_conn(conn, viewer)
      resp = conn |> delete(~p"/api/tasks/#{task.id}") |> json_response(403)
      assert resp["status"] == 403
    end

    test "viewer cannot complete tasks -> 403", %{conn: conn} do
      viewer = create_viewer_user()
      contact = contact_fixture(viewer.account_id)

      {:ok, task} =
        Kith.Tasks.create_task(viewer.account_id, viewer.id, %{
          "title" => "Test",
          "contact_id" => contact.id,
          "is_private" => false
        })

      conn = authed_conn(conn, viewer)
      resp = conn |> post(~p"/api/tasks/#{task.id}/complete") |> json_response(403)
      assert resp["status"] == 403
    end
  end

  # ── Account scoping ──────────────────────────────────────────────

  describe "account scoping" do
    test "user cannot see tasks from another account", %{conn: conn} do
      user_a = user_fixture()
      user_b = user_fixture()
      contact_b = contact_fixture(user_b.account_id)

      {:ok, task_b} =
        Kith.Tasks.create_task(user_b.account_id, user_b.id, %{
          "title" => "Secret",
          "contact_id" => contact_b.id,
          "is_private" => false
        })

      conn_a = authed_conn(conn, user_a)
      resp = conn_a |> get(~p"/api/tasks/#{task_b.id}") |> json_response(404)
      assert resp["status"] == 404
    end
  end
end
