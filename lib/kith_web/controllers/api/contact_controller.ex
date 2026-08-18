defmodule KithWeb.API.ContactController do
  @moduledoc """
  REST API controller for contacts.

  Provides CRUD operations plus archive/unarchive, favorite/unfavorite,
  merge, and trash/restore endpoints.
  """

  use KithWeb, :controller

  alias Kith.{Contacts, Policy}
  alias Kith.Contacts.Contact
  alias Kith.Scope, as: TenantScope
  alias KithWeb.API.{ContactJSON, ErrorJSON, Includes, Pagination}

  import Ecto.Query

  action_fallback KithWeb.API.FallbackController

  # ── List contacts ─────────────────────────────────────────────────────

  def index(conn, %{"trashed" => "true"} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    user = scope.user

    if Policy.can?(user, :manage, :contact) do
      query = TenantScope.scope_trashed(Contact, account_id)
      {contacts, meta} = Pagination.paginate(query, params)
      json(conn, Pagination.paginated_response(Enum.map(contacts, &ContactJSON.data/1), meta))
    else
      return_forbidden(conn)
    end
  end

  def index(conn, params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    case Includes.parse_includes(params, :contact_list) do
      {:ok, includes} ->
        list_active_contacts(conn, params, account_id, includes)

      {:error, detail} ->
        {:error, :bad_request, detail}
    end
  end

  # ── Show contact ──────────────────────────────────────────────────────

  def show(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id

    with {:ok, includes} <- Includes.parse_includes(params, :contact_show),
         preloads = Includes.to_preloads(includes),
         contact when not is_nil(contact) <-
           Contacts.get_contact(account_id, id, preload: preloads) do
      data = format_contact_data(contact, includes)
      json(conn, %{data: data})
    else
      nil -> {:error, :not_found}
      {:error, detail} -> {:error, :bad_request, detail}
    end
  end

  # ── Create contact ────────────────────────────────────────────────────

  def create(conn, %{"contact" => contact_params}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :create, :contact),
         {:ok, contact} <- Contacts.create_contact(account_id, contact_params) do
      Kith.AuditLogs.log_event(account_id, user, :contact_created,
        contact_id: contact.id,
        contact_name: contact.display_name
      )

      conn
      |> put_status(201)
      |> put_resp_header("location", "/api/contacts/#{contact.id}")
      |> json(%{data: ContactJSON.data(contact)})
    else
      false -> {:error, :forbidden}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request, "Missing 'contact' key in request body."}
  end

  # ── Update contact ────────────────────────────────────────────────────

  def update(conn, %{"id" => id, "contact" => contact_params}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, id),
         safe_params = Map.drop(contact_params, ["account_id", "deleted_at", "id"]),
         {:ok, updated} <- Contacts.update_contact(contact, safe_params) do
      Kith.AuditLogs.log_event(account_id, user, :contact_updated,
        contact_id: updated.id,
        contact_name: updated.display_name
      )

      json(conn, %{data: ContactJSON.data(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def update(_conn, %{"id" => _id}) do
    {:error, :bad_request, "Missing 'contact' key in request body."}
  end

  # ── Delete (soft-delete) contact ──────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :delete, :contact),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, id),
         {:ok, _contact} <- Contacts.soft_delete_contact(contact) do
      Kith.AuditLogs.log_event(account_id, user, :contact_deleted,
        contact_id: contact.id,
        contact_name: contact.display_name
      )

      send_resp(conn, 204, "")
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # ── Archive / Unarchive ───────────────────────────────────────────────

  def archive(conn, %{"contact_id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, id),
         {:ok, updated} <- Contacts.archive_contact(contact) do
      Kith.AuditLogs.log_event(account_id, user, :contact_archived,
        contact_id: contact.id,
        contact_name: contact.display_name
      )

      json(conn, %{data: ContactJSON.data(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def unarchive(conn, %{"contact_id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, id),
         {:ok, updated} <- Contacts.unarchive_contact(contact) do
      Kith.AuditLogs.log_event(account_id, user, :contact_restored,
        contact_id: contact.id,
        contact_name: contact.display_name
      )

      json(conn, %{data: ContactJSON.data(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # ── Favorite / Unfavorite ─────────────────────────────────────────────

  def favorite(conn, %{"contact_id" => id}) do
    toggle_favorite(conn, id, true)
  end

  def unfavorite(conn, %{"contact_id" => id}) do
    toggle_favorite(conn, id, false)
  end

  defp toggle_favorite(conn, id, value) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         contact when not is_nil(contact) <- Contacts.get_contact(account_id, id),
         {:ok, updated} <- Contacts.update_contact(contact, %{"favorite" => value}) do
      json(conn, %{data: ContactJSON.data(updated)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # ── Merge ─────────────────────────────────────────────────────────────

  def merge(conn, %{"survivor_id" => survivor_id, "non_survivor_id" => non_survivor_id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         :ok <- validate_merge_ids(survivor_id, non_survivor_id),
         survivor when not is_nil(survivor) <- Contacts.get_contact(account_id, survivor_id),
         loser when not is_nil(loser) <- Contacts.get_contact(account_id, non_survivor_id),
         fields = Contacts.legacy_resolution_fields(survivor, loser),
         {:ok, merged} <-
           Contacts.merge_cluster(scope, survivor.id, [loser.id], %{fields: fields, drop: %{}}) do
      json(conn, %{data: ContactJSON.data(merged)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, :same_ids} -> {:error, :bad_request, "Cannot merge a contact with itself."}
      {:error, reason} -> {:error, :bad_request, "Merge failed: #{inspect(reason)}"}
    end
  end

  def merge(_conn, _params) do
    {:error, :bad_request, "Missing survivor_id and non_survivor_id."}
  end

  # ── Restore (from trash) ──────────────────────────────────────────────

  def restore(conn, %{"contact_id" => id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :manage, :contact),
         {:ok, contact} <- find_trashed_contact(account_id, id),
         {:ok, restored} <- Contacts.restore_contact(contact) do
      Kith.AuditLogs.log_event(account_id, user, :contact_restored,
        contact_id: contact.id,
        contact_name: contact.display_name
      )

      json(conn, %{data: ContactJSON.data(restored)})
    else
      false -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :not_in_trash} -> {:error, :bad_request, "Contact is not in trash."}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────

  defp list_active_contacts(conn, params, account_id, includes) do
    preloads = Includes.to_preloads(includes)

    query =
      Contact
      |> TenantScope.scope_active(account_id)
      |> apply_filters(params)
      |> maybe_search(params, account_id)

    query = if preloads != [], do: from(q in query, preload: ^preloads), else: query

    {contacts, meta} = Pagination.paginate(query, params)

    data = Enum.map(contacts, &format_contact_data(&1, includes))

    json(conn, Pagination.paginated_response(data, meta))
  end

  defp format_contact_data(contact, []), do: ContactJSON.data(contact)

  defp format_contact_data(contact, includes),
    do: ContactJSON.data_with_includes(contact, includes)

  defp validate_merge_ids(id, id), do: {:error, :same_ids}
  defp validate_merge_ids(_s, _n), do: :ok

  defp find_trashed_contact(account_id, id) do
    contact =
      Contact
      |> TenantScope.scope_trashed(account_id)
      |> Kith.Repo.get(id)

    cond do
      not is_nil(contact) -> {:ok, contact}
      is_nil(Contacts.get_contact(account_id, id)) -> {:error, :not_found}
      true -> {:error, :not_in_trash}
    end
  end

  defp apply_filters(query, params) do
    query
    |> filter_archived(params)
    |> filter_favorite(params)
    |> filter_tags(params)
  end

  defp filter_archived(query, %{"archived" => "true"}) do
    from(q in query, where: q.is_archived == true)
  end

  defp filter_archived(query, _params) do
    from(q in query, where: q.is_archived == false)
  end

  defp filter_favorite(query, %{"favorite" => "true"}) do
    from(q in query, where: q.favorite == true)
  end

  defp filter_favorite(query, _params), do: query

  defp filter_tags(query, %{"tag_ids" => tag_ids}) when is_list(tag_ids) and tag_ids != [] do
    ids = Enum.map(tag_ids, &to_integer/1) |> Enum.reject(&is_nil/1)

    if ids == [] do
      query
    else
      from(q in query,
        join: ct in "contact_tags",
        on: ct.contact_id == q.id,
        where: ct.tag_id in ^ids,
        distinct: true
      )
    end
  end

  defp filter_tags(query, _params), do: query

  defp maybe_search(query, %{"q" => q}, _account_id) when is_binary(q) and q != "" do
    search = "%#{String.replace(q, ~r/[%_\\]/, "\\\\\\0")}%"

    from(q_query in query,
      left_join: cf in Kith.Contacts.ContactField,
      on: cf.contact_id == q_query.id,
      where:
        ilike(q_query.first_name, ^search) or
          ilike(q_query.last_name, ^search) or
          ilike(q_query.display_name, ^search) or
          ilike(q_query.nickname, ^search) or
          ilike(q_query.company, ^search) or
          ilike(cf.value, ^search),
      distinct: true
    )
  end

  defp maybe_search(query, _params, _account_id), do: query

  defp return_forbidden(conn) do
    conn
    |> put_status(403)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(403, "Admin role required.", conn.request_path))
  end

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(_), do: nil
end
