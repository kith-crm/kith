defmodule KithWeb.API.TaskController do
  @moduledoc """
  REST API controller for contact tasks.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "tasks"

  alias Kith.{Contacts, Policy, Repo}
  alias Kith.Scope, as: TenantScope
  alias Kith.Tasks.Task
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List tasks for a contact ───────────────────────────────────────

  def index(conn, %{"contact_id" => contact_id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    with {:ok, _contact} <- fetch_contact(account_id, contact_id) do
      query =
        Task
        |> TenantScope.scope_to_account(account_id)
        |> where([t], t.contact_id == ^contact_id)
        |> where([t], t.is_private == false or t.creator_id == ^user_id)

      {tasks, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(tasks, &task_json/1), meta))
    end
  end

  # ── Show task ──────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    case Task |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil ->
        {:error, :not_found}

      %Task{is_private: true, creator_id: creator_id} when creator_id != user_id ->
        {:error, :not_found}

      task ->
        json(conn, %{data: task_json(task)})
    end
  end

  # ── Create task ────────────────────────────────────────────────────

  def create(conn, %{"contact_id" => contact_id, "task" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :task),
         {:ok, contact} <- fetch_contact(account_id, contact_id),
         {:ok, task} <-
           %Task{contact_id: contact.id, account_id: account_id, creator_id: user.id}
           |> Task.changeset(attrs)
           |> Repo.insert() do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/tasks/#{task.id}")
      |> json(%{data: task_json(task)})
    else
      false -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, %{"contact_id" => _contact_id}) do
    {:error, :bad_request, "Missing 'task' key in request body."}
  end

  # ── Update task ────────────────────────────────────────────────────

  def update(conn, %{"id" => id, "task" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :task),
         task when not is_nil(task) <-
           Task |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- task |> Task.changeset(attrs) |> Repo.update() do
      json(conn, %{data: task_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'task' key in request body."}
  end

  # ── Delete task ────────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :task),
         task when not is_nil(task) <-
           Task |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _task} <- Repo.delete(task) do
      send_resp(conn, 204, "")
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  # ── Complete task ──────────────────────────────────────────────────

  def complete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :task),
         task when not is_nil(task) <-
           Task |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- task |> Task.changeset(%{status: "completed"}) |> Repo.update() do
      json(conn, %{data: task_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp fetch_contact(account_id, contact_id) do
    case Contacts.get_contact(account_id, contact_id) do
      nil -> {:error, :not_found}
      contact -> {:ok, contact}
    end
  end

  defp task_json(task) do
    %{
      id: task.id,
      contact_id: task.contact_id,
      creator_id: task.creator_id,
      title: task.title,
      description: task.description,
      due_date: task.due_date,
      priority: task.priority,
      status: task.status,
      completed_at: task.completed_at,
      is_private: task.is_private,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end
end
