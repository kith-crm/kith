defmodule Kith.Contacts.MergeSummary do
  @moduledoc """
  Gathers the multi-valued records and history counts a merge screen shows.

  Read-only. Duplicates are marked rather than removed so the screen can show
  what the merge will collapse instead of silently dropping it.
  """

  import Ecto.Query, warn: false

  alias Kith.Contacts.{Address, ContactField, Document, Note, Photo}
  alias Kith.Repo

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
    conversations: Kith.Conversations.Conversation,
    relationships: Kith.Contacts.Relationship
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

    %{
      contact_fields: contact_fields(ids),
      addresses: addresses(ids),
      tags: tags(ids),
      aliases: aliases(members),
      history: history(ids)
    }
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
  defp address_key(address) do
    line1 = normalize(address.line1)
    postal_code = normalize(address.postal_code)

    if blank?(line1) and blank?(postal_code) do
      {:no_key, address.id}
    else
      {line1, postal_code}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

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

  defp history(ids) do
    counts =
      Map.new(@history, fn {key, schema} ->
        {key, Repo.aggregate(from(r in schema, where: r.contact_id in ^ids), :count)}
      end)

    activities =
      from(ac in "activity_contacts", where: ac.contact_id in ^ids, select: count())
      |> Repo.one()

    Map.put(counts, :activities, activities)
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

  defp normalize(nil), do: nil
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end
