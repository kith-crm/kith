defmodule Kith.Contacts.MergeSummary do
  @moduledoc """
  Gathers the multi-valued records and history counts a merge screen shows.

  Read-only. Duplicates are marked rather than removed so the screen can show
  what the merge will collapse instead of silently dropping it.
  """

  import Ecto.Query, warn: false

  alias Kith.Accounts.{OptionalFeatures, Scope}
  alias Kith.Contacts.{Address, ContactField, Document, Note, Photo}
  alias Kith.Repo

  @relationship_schema Kith.Contacts.Relationship

  @history [
    notes: Note,
    documents: Document,
    photos: Photo,
    calls: Kith.Activities.Call,
    life_events: Kith.Activities.LifeEvent,
    reminders: Kith.Reminders.Reminder,
    gifts: Kith.Contacts.Gift,
    debts: Kith.Contacts.Debt,
    pets: Kith.Contacts.Pet,
    tasks: Kith.Tasks.Task,
    conversations: Kith.Conversations.Conversation
  ]

  @doc """
  Builds the summary for `members`.

  Every `contact_fields`/`addresses`/`tags`/`aliases` entry also carries a
  `key` — the value `mark_duplicates/1` grouped it by to decide `duplicate?`.
  This is not part of the documented entry shape but is kept intentionally:
  `Kith.Contacts.Merge`'s `:dedupe_owned` step runs before `:apply_drop`, so a
  survivor row and a loser row with an equal, normalized value are
  equivalent — dropping only the one the user clicked can leave its
  equivalent behind and the value comes back. Callers building a drop list
  must expand a dropped entry to every entry sharing its `key`, not just the
  one row shown as a duplicate.
  """
  def build(members) do
    ids = Enum.map(members, & &1.id)

    summary(members, ids, history(ids))
  end

  @doc "Builds the merge preview with history that will move to the primary."
  def build(%Scope{account: account}, members, primary_id) do
    members = Enum.filter(members, &(&1.account_id == account.id))
    ids = Enum.map(members, & &1.id)
    loser_ids = List.delete(ids, primary_id)
    summary(members, ids, moving_history(loser_ids, primary_id, account))
  end

  defp summary(members, ids, history) do
    %{
      contact_fields: contact_fields(ids),
      addresses: addresses(ids),
      tags: tags(ids),
      aliases: aliases(members),
      history: history
    }
  end

  defp moving_history([], _primary_id, _account), do: %{}

  defp moving_history(ids, primary_id, account) do
    primary_activities =
      from(ac in "activity_contacts",
        join: a in Kith.Activities.Activity,
        on: a.id == ac.activity_id,
        where: ac.contact_id == ^primary_id and a.account_id == ^account.id,
        select: ac.activity_id
      )

    activities =
      Repo.one(
        from(ac in "activity_contacts",
          join: a in Kith.Activities.Activity,
          on: a.id == ac.activity_id,
          where: a.account_id == ^account.id and ac.contact_id in ^ids,
          where: ac.activity_id not in subquery(primary_activities),
          select: count(ac.activity_id, :distinct)
        )
      )

    {visible, retained} =
      ids
      |> history_counts(account.id)
      |> Map.put(:activities, activities)
      |> Map.put(:relationships, moving_relationship_count(ids, primary_id, account.id))
      |> Enum.split_with(fn {key, _count} ->
        feature = Atom.to_string(key)
        not OptionalFeatures.known?(feature) or OptionalFeatures.enabled?(account, feature)
      end)

    visible = Map.new(visible)
    retained_count = Enum.sum_by(retained, &elem(&1, 1))
    if retained_count > 0, do: Map.put(visible, :retained_history, retained_count), else: visible
  end

  defp moving_relationship_count(loser_ids, primary_id, account_id) do
    cluster_ids = [primary_id | loser_ids]

    # Group the external rows by their post-merge endpoints and type. A group
    # moves only when none of its rows already belong to the primary.
    groups =
      from(r in @relationship_schema,
        where: r.account_id == ^account_id,
        where:
          (r.contact_id in ^cluster_ids and r.related_contact_id not in ^cluster_ids) or
            (r.related_contact_id in ^cluster_ids and r.contact_id not in ^cluster_ids),
        select: %{
          owner:
            selected_as(
              fragment(
                "CASE WHEN ? = ANY(?) THEN ? ELSE ? END",
                r.contact_id,
                type(^cluster_ids, {:array, :integer}),
                type(^primary_id, :integer),
                r.contact_id
              ),
              :owner
            ),
          target:
            selected_as(
              fragment(
                "CASE WHEN ? = ANY(?) THEN ? ELSE ? END",
                r.related_contact_id,
                type(^cluster_ids, {:array, :integer}),
                type(^primary_id, :integer),
                r.related_contact_id
              ),
              :target
            ),
          type: r.relationship_type_id
        },
        group_by: [selected_as(:owner), selected_as(:target), r.relationship_type_id],
        having:
          fragment(
            "bool_and(? <> ? AND ? <> ?)",
            r.contact_id,
            ^primary_id,
            r.related_contact_id,
            ^primary_id
          )
      )

    Repo.aggregate(subquery(groups), :count)
  end

  defp contact_fields(ids) do
    from(f in ContactField,
      where: f.contact_id in ^ids,
      join: t in assoc(f, :contact_field_type),
      order_by: [asc: f.id],
      select: {f, t.name}
    )
    |> Repo.all()
    |> Enum.map(fn {field, name} ->
      %{
        id: field.id,
        label: name,
        value: field.value,
        owner_id: field.contact_id,
        key: {field.contact_field_type_id, normalize(field.value)}
      }
    end)
    |> mark_duplicates()
  end

  defp addresses(ids) do
    from(a in Address, where: a.contact_id in ^ids, order_by: [asc: a.id])
    |> Repo.all()
    |> Enum.map(fn address ->
      %{
        id: address.id,
        label: address.label || "Address",
        value: Enum.join(Enum.reject([address.line1, address.city], &is_nil/1), ", "),
        owner_id: address.contact_id,
        key: address_key(address)
      }
    end)
    |> mark_duplicates()
  end

  # Mirrors the blank-key guard in Kith.Contacts.Merge's dedupe_owned_step/2:
  # an address with neither line1 nor postal_code isn't a duplicate of
  # another address in the same shape (they may differ by city/region/
  # country, e.g. "Paris" vs "Tokyo"), so give each a key that can't collide.
  #
  # The engine compares these columns through `coalesce(col, '')`, so a NULL
  # and an empty string are the same value to it. Collapsing both to `""` here
  # keeps this key in step: a caller expanding a dropped entry to everything
  # sharing its key (see `build/1`) would otherwise miss the other side of a
  # nil/"" pair the engine is about to dedupe, and the dropped value would come
  # back on the survivor.
  defp address_key(address) do
    line1 = blank_to_empty(normalize(address.line1))
    postal_code = blank_to_empty(normalize(address.postal_code))

    if line1 == "" and postal_code == "" do
      {:no_key, address.id}
    else
      {line1, postal_code}
    end
  end

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(value), do: value

  defp tags(ids) do
    from(ct in "contact_tags",
      join: t in Kith.Contacts.Tag,
      on: t.id == ct.tag_id,
      where: ct.contact_id in ^ids,
      order_by: [asc: t.name],
      select: {ct.contact_id, t.id, t.name}
    )
    |> Repo.all()
    |> Enum.map(fn {owner_id, tag_id, name} ->
      %{id: tag_id, label: "Tag", value: name, owner_id: owner_id, key: tag_id}
    end)
    |> mark_duplicates()
  end

  # Aliases are unioned into a single set, unlike contact_fields/addresses/tags
  # (which keep duplicate rows, marked, since each row is independently
  # droppable). An alias array has no per-row identity to drop, so repeats
  # across members are folded away here rather than surfaced as duplicate?.
  defp aliases(members) do
    members
    |> Enum.flat_map(fn member ->
      Enum.map(
        member.aliases || [],
        &%{id: &1, label: "Alias", value: &1, owner_id: member.id, key: &1}
      )
    end)
    |> mark_duplicates()
    |> Enum.reject(& &1.duplicate?)
  end

  defp history_counts(ids, account_id) do
    Map.new(@history, fn {key, schema} ->
      query = from(r in schema, where: r.contact_id in ^ids)
      {key, Repo.aggregate(scope_history(query, account_id), :count)}
    end)
  end

  defp scope_history(query, nil), do: query
  defp scope_history(query, account_id), do: Kith.Scope.scope_to_account(query, account_id)

  defp history(ids) do
    activities =
      from(ac in "activity_contacts", where: ac.contact_id in ^ids, select: count())
      |> Repo.one()

    relationships =
      Repo.aggregate(
        from(r in @relationship_schema,
          where: r.contact_id in ^ids or r.related_contact_id in ^ids
        ),
        :count
      )

    ids
    |> history_counts(nil)
    |> Map.put(:activities, activities)
    |> Map.put(:relationships, relationships)
  end

  # The first occurrence of a key wins; later ones are what the merge collapses.
  # `key` is kept on the returned entry — see the moduledoc on `build/1`.
  defp mark_duplicates(entries) do
    {marked, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn entry, seen ->
        duplicate? = MapSet.member?(seen, entry.key)
        {Map.put(entry, :duplicate?, duplicate?), MapSet.put(seen, entry.key)}
      end)

    marked
  end

  # Pinned to the SQL in `Kith.Contacts.Merge`'s `dedupe_owned_step/2`, which
  # keys on `lower(btrim(col))`. One-argument `btrim` strips SPACES ONLY, while
  # `String.trim/1` strips every Unicode whitespace character — so a value with
  # a leading tab would read as "duplicate · dropped" on screen while the engine
  # kept both rows, and a caller expanding a dropped entry over everything
  # sharing its key (see `build/1`) would then drop a value the user never
  # excluded. `String.trim/2` with `" "` is byte-for-byte what `btrim` does.
  #
  # `lower()` vs `String.downcase/1` still differ for locale-specific casing
  # (Postgres folds per the database collation; Elixir folds per Unicode
  # default). Both are identical over ASCII, which is what these keys are in
  # practice; the whitespace half is the one that had a reachable divergence.
  defp normalize(nil), do: nil
  defp normalize(value) when is_binary(value), do: value |> String.trim(" ") |> String.downcase()
end
