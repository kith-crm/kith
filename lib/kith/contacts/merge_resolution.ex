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
  def resolve(members, _survivor_id) when is_list(members) and members != [] do
    Enum.reduce(MergeFields.choice_fields(), %__MODULE__{}, fn field, acc ->
      put_resolution(acc, field, resolve_scalar(members, field))
    end)
  end

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
