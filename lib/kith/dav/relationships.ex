defmodule Kith.DAV.Relationships do
  @moduledoc """
  Account-scoped shared relationship projection and native reconciliation.

  A projected view represents one target and public category and keeps internal
  bindings to every equivalent forward/reverse native edge. Custom subtype
  names are never public classification. Reconciliation must run inside the
  caller's account-locked write transaction; this module does not publish DAV
  revisions or resolve relationships by display name.
  """

  import Ecto.Query

  alias Kith.Contacts.{Contact, Relationship, RelationshipType}
  alias Kith.DAV.{ContactDav, Store, UID}
  alias Kith.Repo

  @snapshot_key {__MODULE__, :read_snapshot}

  @categories ~w(contact spouse parent child sibling friend colleague)
  @public_categories %{
    "spouse" => "spouse",
    "parent" => "parent",
    "child" => "child",
    "sibling" => "sibling",
    "friend" => "friend",
    "best_friend" => "friend",
    "colleague" => "colleague"
  }
  @labels %{
    "contact" => "Contact",
    "spouse" => "Spouse",
    "parent" => "Parent",
    "child" => "Child",
    "sibling" => "Sibling",
    "friend" => "Friend",
    "colleague" => "Colleague"
  }
  @shared_target_fields ~w(id account_id first_name middle_name last_name nickname display_name company)a

  @doc """
  Projects both directions, collapsing equivalent edges by target/category.

  `bindings` and target IDs are internal only. The opaque `id` can safely name a
  generated compatibility group; it never exposes a native relationship ID.
  """
  def project(%Contact{} = contact) do
    if visible?(contact) do
      contact
      |> edges()
      |> Enum.flat_map(&edge_view(&1, contact.id))
      |> Enum.group_by(&{&1.target_id, &1.type})
      |> Enum.map(fn {_key, views} -> collapse(views) end)
      |> Enum.sort_by(&{&1.target_id, &1.type})
    else
      []
    end
  end

  @doc """
  Replaces visible shared edges while preserving private subtype IDs on matches.

  Unknown URI/text entries are returned as `client_only`; known hidden targets
  are returned as `suppressed` and must also be omitted from client-document
  rendering. Omitted hidden native edges remain untouched. Returns affected
  endpoint IDs for the caller's atomic document/revision publication.
  """
  def reconcile(%Contact{} = contact, entries) when is_list(entries) do
    if Repo.in_transaction?() do
      Repo.transaction(fn -> reconcile_locked(contact, entries) end)
    else
      {:error, :transaction_required}
    end
  end

  defp reconcile_locked(contact, entries) do
    current = project(contact)
    {resolved, client_only, suppressed} = resolve_entries(contact, entries)
    incoming = Enum.uniq_by(resolved, &{&1.target.id, &1.type})
    wanted = MapSet.new(incoming, &{&1.target.id, &1.type})
    existing = MapSet.new(current, &{&1.target_id, &1.type})
    removed = Enum.reject(current, &MapSet.member?(wanted, {&1.target_id, &1.type}))
    added = Enum.reject(incoming, &MapSet.member?(existing, {&1.target.id, &1.type}))

    # Resolve destinations before deleting anything: absent trusted vocabulary
    # must fail the command rather than silently dropping incoming relations.
    destinations = destinations!(added)
    delete_views!(contact.account_id, removed)
    Enum.each(added, &insert_edge!(contact, &1, destinations))

    %{
      affected_contact_ids:
        Enum.uniq([
          contact.id | Enum.map(removed, & &1.target_id) ++ Enum.map(added, & &1.target.id)
        ]),
      client_only: client_only,
      suppressed: suppressed
    }
  end

  @doc "Caches relationship edges and local UID visibility for one consistent read."
  def with_snapshot(account_id, fun) do
    previous = Process.get(@snapshot_key)
    edges = Repo.all(edge_query(account_id))

    targets =
      Repo.all(
        from(c in Contact,
          join: d in ContactDav,
          on: d.contact_id == c.id and d.account_id == c.account_id,
          where: c.account_id == ^account_id,
          select: %{
            id: c.id,
            account_id: c.account_id,
            deleted_at: c.deleted_at,
            is_archived: c.is_archived,
            uid: d.uid
          }
        )
      )

    indexed =
      Enum.reduce(edges, %{}, fn edge, acc ->
        acc = Map.update(acc, edge.contact_id, [edge], &[edge | &1])

        if edge.contact_id == edge.related_contact_id,
          do: acc,
          else: Map.update(acc, edge.related_contact_id, [edge], &[edge | &1])
      end)

    Process.put(@snapshot_key, %{
      account_id: account_id,
      edges: indexed,
      targets: Map.new(targets, &{&1.uid, &1})
    })

    try do
      fun.()
    after
      if previous, do: Process.put(@snapshot_key, previous), else: Process.delete(@snapshot_key)
    end
  end

  defp edges(contact) do
    case Process.get(@snapshot_key) do
      %{account_id: account_id, edges: edges} when account_id == contact.account_id ->
        Map.get(edges, contact.id, []) |> Enum.sort_by(& &1.id)

      _ ->
        contact.account_id
        |> edge_query()
        |> where([r], r.contact_id == ^contact.id or r.related_contact_id == ^contact.id)
        |> Repo.all()
    end
  end

  defp edge_query(account_id) do
    from(r in Relationship,
      join: owner in Contact,
      on: owner.id == r.contact_id and owner.account_id == r.account_id,
      join: target in Contact,
      on: target.id == r.related_contact_id and target.account_id == r.account_id,
      join: type in RelationshipType,
      on: type.id == r.relationship_type_id,
      where: r.account_id == ^account_id,
      where: is_nil(type.account_id) or type.account_id == ^account_id,
      order_by: r.id,
      preload: [:relationship_type, contact: :dav, related_contact: :dav]
    )
  end

  defp edge_view(edge, contact_id) do
    {target, direction} =
      if edge.contact_id == contact_id,
        do: {edge.related_contact, :forward},
        else: {edge.contact, :reverse}

    if visible?(target) and match?(%{uid: uid} when is_binary(uid), target.dav) do
      type = public_category(edge.relationship_type, direction)
      target = target |> Map.take(@shared_target_fields) |> Map.put(:dav, %{uid: target.dav.uid})

      [
        %{
          target_id: target.id,
          related_contact: target,
          uid: target.dav.uid,
          value: UID.urn(target.dav.uid),
          type: type,
          label: Map.fetch!(@labels, type),
          relationship_type: %{name: Map.fetch!(@labels, type)},
          bindings: [%{id: edge.id, direction: direction}]
        }
      ]
    else
      []
    end
  end

  defp collapse([first | _] = views) do
    bindings = views |> Enum.flat_map(& &1.bindings) |> Enum.sort_by(& &1.id)
    fingerprint = Enum.map(bindings, &{&1.id, &1.direction}) |> :erlang.term_to_binary()
    token = :crypto.hash(:sha256, fingerprint) |> Base.encode16(case: :lower)
    first |> Map.put(:bindings, bindings) |> Map.put(:id, "rel-" <> token)
  end

  defp public_category(%RelationshipType{account_id: nil, system_key: key}, direction) do
    key |> then(&Map.get(@public_categories, &1, "contact")) |> inverse_category(direction)
  end

  defp public_category(_type, _direction), do: "contact"
  defp inverse_category("parent", :reverse), do: "child"
  defp inverse_category("child", :reverse), do: "parent"
  defp inverse_category(category, _direction), do: category

  @doc """
  Removes known hidden-target relationship properties and their grouped companions.

  Text-valued relationships and unknown external identities remain client data.
  Generated companions without a shared group must additionally be removed by
  the document's native binding policy; this function never guesses by name.
  """
  def safe_document_properties(%Contact{} = contact, properties) when is_list(properties) do
    hidden = Enum.filter(properties, &hidden_reference?(contact.account_id, &1))
    groups = hidden |> Enum.map(& &1.group) |> Enum.reject(&is_nil/1) |> MapSet.new()

    Enum.reject(properties, fn property ->
      property in hidden or (property.group != nil and MapSet.member?(groups, property.group))
    end)
  end

  defp hidden_reference?(account_id, property) do
    if property.normalized_name in ["RELATED", "X-KITH-RELATED"] and not text_property?(property) do
      case lookup_target(account_id, property.value) do
        nil -> false
        target -> not visible?(target)
      end
    else
      false
    end
  end

  defp lookup_target(account_id, value) do
    case Process.get(@snapshot_key) do
      %{account_id: ^account_id, targets: targets} ->
        case UID.normalize(value) do
          {:ok, uid} -> Map.get(targets, uid)
          _ -> nil
        end

      _ ->
        Store.get_related(account_id, value)
    end
  end

  defp text_property?(property) do
    values =
      property.parameters
      |> Enum.filter(&(&1.normalized_name == "VALUE"))
      |> Enum.flat_map(& &1.values)

    values != [] and Enum.all?(values, &(String.downcase(&1) == "text"))
  end

  defp resolve_entries(contact, entries) do
    {resolved, client_only, suppressed} =
      Enum.reduce(entries, {[], [], []}, fn entry, acc ->
        append_resolution(resolve_entry(contact.account_id, entry), entry, acc)
      end)

    {Enum.reverse(resolved), Enum.reverse(client_only), Enum.reverse(suppressed)}
  end

  defp resolve_entry(account_id, entry) do
    case resolve_target(account_id, entry) do
      nil ->
        :client_only

      target ->
        if visible?(target),
          do: {:shared, %{target: target, type: normalize_category(Map.get(entry, :type))}},
          else: :suppressed
    end
  end

  defp append_resolution(:client_only, entry, {resolved, client_only, suppressed}),
    do: {resolved, [entry | client_only], suppressed}

  defp append_resolution(:suppressed, entry, {resolved, client_only, suppressed}),
    do: {resolved, client_only, [entry | suppressed]}

  defp append_resolution({:shared, value}, _entry, {resolved, client_only, suppressed}),
    do: {[value | resolved], client_only, suppressed}

  defp resolve_target(account_id, entry) do
    if Map.get(entry, :value_type) in [:text, "text"],
      do: nil,
      else: Store.get_related(account_id, Map.get(entry, :value))
  end

  defp normalize_category(type) when is_binary(type) do
    type = String.downcase(type)
    if type in @categories, do: type, else: "contact"
  end

  defp normalize_category(_), do: "contact"

  defp destinations!(entries) do
    entries
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Map.new(fn category ->
      case Repo.one(
             from(t in RelationshipType,
               where: is_nil(t.account_id) and t.system_key == ^category
             )
           ) do
        nil -> Repo.rollback({:missing_shared_relationship_type, category})
        type -> {category, type.id}
      end
    end)
  end

  defp delete_views!(account_id, views) do
    ids = views |> Enum.flat_map(& &1.bindings) |> Enum.map(& &1.id) |> Enum.uniq()

    from(r in Relationship, where: r.account_id == ^account_id and r.id in ^ids)
    |> Repo.delete_all()
  end

  defp insert_edge!(contact, entry, destinations) do
    attrs = %{
      account_id: contact.account_id,
      contact_id: contact.id,
      related_contact_id: entry.target.id,
      relationship_type_id: Map.fetch!(destinations, entry.type)
    }

    case %Relationship{} |> Relationship.changeset(attrs) |> Repo.insert() do
      {:ok, _relationship} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp visible?(contact), do: is_nil(contact.deleted_at) and not contact.is_archived
end
