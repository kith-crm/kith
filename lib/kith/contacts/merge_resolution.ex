defmodule Kith.Contacts.MergeResolution do
  @moduledoc """
  Turns a set of member contacts into the complete field map a merge will apply.

  Pure: reads the structs it is given and writes nothing. This is the single
  implementation of merge resolution — the cluster LiveView calls it to render,
  the REST API adapter calls it to build its payload, and the engine never calls
  it at all. That separation is what makes a merge apply exactly what the user
  approved: the engine validates a concrete map rather than re-deriving one at
  transaction time.

  Resolution is recomputed from scratch whenever the member selection changes;
  explicit user choices are not carried across a change.
  """

  alias Kith.Contacts.MergeFields

  defstruct fields: %{}, conflicts: %{}, attributions: %{}

  @type t :: %__MODULE__{
          fields: %{atom() => term() | :clear},
          conflicts: %{atom() => [%{value: term(), member_ids: [integer()], count: integer()}]},
          attributions: %{atom() => :all_agree | {:only, integer()} | {:some, integer()} | :none}
        }

  @doc """
  Resolves `members` into a complete field map.

  `survivor_id` must be the id of one of `members`. It is needed by rules that
  are relative to the surviving record rather than to the set as a whole.
  """
  def resolve(members, survivor_id) when is_list(members) and members != [] do
    member_ids = MapSet.new(members, & &1.id)

    MergeFields.choice_fields()
    |> Enum.reduce(%__MODULE__{}, fn field, acc ->
      put_resolution(acc, field, resolve_scalar(members, field))
    end)
    |> resolve_coupled(members)
    |> clear_self_reference(member_ids)
    |> resolve_arrays(members)
    |> resolve_policy_fields(members)
    |> resolve_immich(members, survivor_id)
  end

  # A contact cannot be met through a record it just absorbed.
  defp clear_self_reference(acc, member_ids) do
    case Map.get(acc.fields, :first_met_through_id) do
      id when is_integer(id) ->
        if MapSet.member?(member_ids, id) do
          %{acc | fields: Map.put(acc.fields, :first_met_through_id, :clear)}
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp resolve_arrays(acc, members) do
    Enum.reduce(MergeFields.array_fields(), acc, fn field, acc ->
      union =
        members
        |> Enum.flat_map(&(Map.fetch!(&1, field) || []))
        |> Enum.uniq()

      %{acc | fields: Map.put(acc.fields, field, union)}
    end)
  end

  # A date and its year-unknown flag move together. The date is resolved by the
  # ordinary scalar rules in the reduce above (so it keeps its conflicts and
  # attribution for the cluster screen); the flag is then read off the members
  # holding the winning date rather than resolved on its own. Taking the flag
  # from a different member than the date is how a 1900 placeholder ends up
  # marked as a real birth year.
  defp resolve_coupled(acc, members) do
    Enum.reduce(MergeFields.coupled_fields(), acc, fn {date_field, flag_field}, acc ->
      flag = coupled_flag(members, date_field, Map.fetch!(acc.fields, date_field), flag_field)
      %{acc | fields: Map.put(acc.fields, flag_field, flag)}
    end)
  end

  # Both flags are `null: false` with `default: false`, so an absent date
  # resolves the flag to `false`, never `:clear`.
  defp coupled_flag(_members, _date_field, :clear, _flag_field), do: false

  defp coupled_flag(members, date_field, value, flag_field) do
    # When members agree on the date but disagree on the flag, "year unknown"
    # wins: asserting a placeholder year is real is the worse of the two errors.
    members
    |> Enum.filter(&(Map.fetch!(&1, date_field) == value))
    |> Enum.any?(&Map.fetch!(&1, flag_field))
  end

  defp resolve_policy_fields(acc, members) do
    favorite = Enum.any?(members, & &1.favorite)
    is_archived = not Enum.any?(members, &(not &1.is_archived))
    deceased = Enum.any?(members, & &1.deceased)

    deceased_at =
      members
      |> Enum.filter(& &1.deceased)
      |> Enum.map(& &1.deceased_at)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> :clear
        dates -> Enum.min(dates, Date)
      end

    fields =
      acc.fields
      |> Map.put(:favorite, favorite)
      |> Map.put(:is_archived, is_archived)
      |> Map.put(:deceased, deceased)
      |> Map.put(:deceased_at, deceased_at)

    %{acc | fields: fields}
  end

  # `immich_status` is a `null: false` column with a check constraint
  # (`unlinked | needs_review | linked`), ordered here by how much state it
  # stands for. A merge must never move a contact *down* this ladder: dropping
  # a `needs_review` survivor to `unlinked` hides it from
  # `Contacts.list_needs_review/1` just as `:remap_immich_candidates` finishes
  # moving every member's pending suggestion onto it.
  @immich_status_rank %{"unlinked" => 0, "needs_review" => 1, "linked" => 2}

  # The four Immich columns move together: an id from one record paired with
  # another record's sync timestamp is corrupt state.
  defp resolve_immich(acc, members, survivor_id) do
    linked = Enum.filter(members, &(not is_nil(&1.immich_person_id)))
    survivor = Enum.find(members, &(&1.id == survivor_id))

    source =
      cond do
        survivor && survivor.immich_person_id -> survivor
        linked == [] -> nil
        true -> Enum.max_by(linked, &sync_key/1)
      end

    fields =
      Enum.reduce(MergeFields.immich_fields(), acc.fields, fn field, fields ->
        Map.put(fields, field, resolve_immich_field(field, source, members))
      end)

    %{acc | fields: fields}
  end

  # With no linked source the three nullable columns have nothing to carry, but
  # the status still does — it is the strongest status any member held.
  defp resolve_immich_field(:immich_status, nil, members), do: strongest_immich_status(members)
  defp resolve_immich_field(_field, nil, _members), do: :clear
  defp resolve_immich_field(field, source, _members), do: Map.fetch!(source, field) || :clear

  defp strongest_immich_status(members) do
    members
    |> Enum.max_by(&Map.get(@immich_status_rank, &1.immich_status, 0))
    |> Map.fetch!(:immich_status)
  end

  defp sync_key(%{immich_last_synced_at: nil}), do: 0
  defp sync_key(%{immich_last_synced_at: at}), do: DateTime.to_unix(at)

  defp put_resolution(acc, field, {value, attribution, candidates}) do
    acc = %{
      acc
      | fields: Map.put(acc.fields, field, value),
        attributions: Map.put(acc.attributions, field, attribution)
    }

    if candidates == [] do
      acc
    else
      %{acc | conflicts: Map.put(acc.conflicts, field, candidates)}
    end
  end

  # Returns {resolved_value, attribution, conflict_candidates}
  defp resolve_scalar(members, field) do
    held =
      members
      |> Enum.map(fn member -> {member.id, normalize(Map.fetch!(member, field))} end)
      |> Enum.reject(fn {_id, value} -> is_nil(value) end)

    case held |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        {:clear, :none, []}

      [only] ->
        ids = Enum.map(held, &elem(&1, 0))
        {only, attribution_for(length(ids), length(members), ids), []}

      _many ->
        candidates = candidates(held)
        value = default_value(members, candidates)
        chosen = Enum.find(candidates, &(&1.value == value))
        {value, attribution_for(chosen.count, length(members), chosen.member_ids), candidates}
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value

  # Attribution reflects how many of *all* members hold the resolved value —
  # not how many members hold any value at all. A value held by 2 of 3
  # members is `{:some, 2}` even though all 3 members have some company set.
  defp attribution_for(count, total_members, ids) do
    case count do
      0 -> :none
      1 -> {:only, hd(ids)}
      ^total_members -> :all_agree
      n -> {:some, n}
    end
  end

  defp candidates(held) do
    held
    |> Enum.group_by(fn {_id, value} -> value end, fn {id, _value} -> id end)
    |> Enum.map(fn {value, ids} -> %{value: value, member_ids: ids, count: length(ids)} end)
  end

  # Most-held value wins; ties break toward the most recently updated member
  # holding it, then toward the lowest member id. `updated_at` is
  # second-precision, so exact ties are common in tests and in practice — the
  # id tie-break makes the winner deterministic instead of falling out of
  # map-iteration order.
  defp default_value(members, candidates) do
    updated_at = Map.new(members, &{&1.id, &1.updated_at})

    candidates
    |> Enum.max_by(fn %{member_ids: ids, count: count} ->
      newest =
        ids
        |> Enum.map(&Map.fetch!(updated_at, &1))
        |> Enum.max(DateTime)
        |> DateTime.to_unix()

      lowest_id = Enum.min(ids)

      {count, newest, -lowest_id}
    end)
    |> Map.fetch!(:value)
  end
end
