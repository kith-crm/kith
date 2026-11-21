defmodule KithWeb.API.JournalController do
  @moduledoc """
  REST API controller for journal entries.

  Journal entries are account-level (not nested under contacts).
  Private entries are visible only to their author.
  """

  use KithWeb, :controller

  plug KithWeb.Plugs.RequireOptionalFeature, "journal"

  alias Kith.Journal.Entry
  alias Kith.{Policy, Repo}
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.Pagination

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List journal entries ──────────────────────────────────────────

  def index(conn, params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    query =
      Entry
      |> TenantScope.scope_to_account(account_id)
      |> where([e], e.is_private == false or e.author_id == ^user_id)

    query =
      case params["mood"] do
        nil -> query
        mood -> where(query, [e], e.mood == ^mood)
      end

    {entries, meta} = Pagination.paginate(query, params)
    json(conn, Pagination.paginated_response(Enum.map(entries, &entry_json/1), meta))
  end

  # ── Show journal entry ────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user_id = scope.user.id

    case Entry |> TenantScope.scope_to_account(account_id) |> Repo.get(id) do
      nil ->
        {:error, :not_found}

      %Entry{is_private: true, author_id: author_id} when author_id != user_id ->
        {:error, :not_found}

      entry ->
        json(conn, %{data: entry_json(entry)})
    end
  end

  # ── Create journal entry ──────────────────────────────────────────

  def create(conn, %{"entry" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :journal),
         {:ok, entry} <-
           %Entry{account_id: account_id, author_id: user.id}
           |> Entry.changeset(attrs)
           |> Repo.insert() do
      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/journal/#{entry.id}")
      |> json(%{data: entry_json(entry)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request, "Missing 'entry' key in request body."}
  end

  # ── Update journal entry ──────────────────────────────────────────

  def update(conn, %{"id" => id, "entry" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :journal),
         entry when not is_nil(entry) <-
           Entry |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, updated} <- entry |> Entry.changeset(attrs) |> Repo.update() do
      json(conn, %{data: entry_json(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'entry' key in request body."}
  end

  # ── Delete journal entry ──────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :journal),
         entry when not is_nil(entry) <-
           Entry |> TenantScope.scope_to_account(account_id) |> Repo.get(id),
         {:ok, _entry} <- Repo.delete(entry) do
      send_resp(conn, 204, "")
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  # ── Private helpers ───────────────────────────────────────────────

  defp entry_json(entry) do
    %{
      id: entry.id,
      title: entry.title,
      content: entry.content,
      occurred_at: entry.occurred_at,
      mood: entry.mood,
      is_private: entry.is_private,
      author_id: entry.author_id,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end
end
