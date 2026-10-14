defmodule Kith.Imports.DuplicateAutomerge do
  @moduledoc """
  Second pass of the Monica-import auto-merge (issue #2).

  The importer's first pass (`Kith.Imports.Sources.MonicaApi.auto_merge_duplicates/3`)
  only merges contacts that share an exact normalized `{first_name, last_name}`
  group **and** a concrete shared email/phone/address. The detector
  (`Kith.DuplicateDetection.scan_account/1`) scores pairs independently and
  flags many more at `1.0` — most often an identical `display_name` with
  nothing else shared, or a transitive chain where each link rests on a
  different signal. Those clusters survive the first pass and show up in the
  duplicates UI at "100%".

  This pass runs a fresh scan, then works over the scoped `pending`
  `DuplicateCandidate` graph. `:restrict_ids` narrows it to pairs whose *both*
  endpoints are in a given contact-id set — the Monica importer passes the
  contacts it genuinely inserted this run (not contacts merely re-touched on a
  re-import), so pre-existing records are never merged. Omitting `:restrict_ids`
  (the `kith.duplicates.automerge` mix task) scans the whole account.

  Over that graph:

    * an **edge** is a candidate pair; a **strong edge** must both score
      `>= min_score` (default `1.0`) **and** carry at least one concrete-signal
      reason — `email_match`, `phone_match`, or `address_match`;
    * a pair whose only reason is `name_match` is **never** a strong edge, even
      at score `1.0`. Two different people routinely share an identical
      first+last name, so a name-only match is left as a pending
      `DuplicateCandidate` for manual review and never auto-merged;
    * a connected component of *strong* edges with two or more members is a
      merge target — every internal edge clears the floor and rests on a
      concrete signal by construction;
    * contacts that hang off such a component only through a non-strong edge
      (a sub-floor score, or a name-only match at any score) are left unmerged
      and `Logger.info`-logged.

  Each merge target is merged through `Kith.Contacts.merge_contacts/2` with
  `Kith.DuplicateDetection.default_primary/1` choosing the survivor. The merge
  path already settles the merged `DuplicateCandidate` rows via
  `Kith.DuplicateDetection.resolve_after_merge/4`, so `cluster_count/1` drops
  without extra work here.

  A merge target is still skipped (and `Logger.info`-logged) when two members
  carry different non-empty `birthdate`s.
  """

  import Ecto.Query

  require Logger

  alias Kith.Contacts
  alias Kith.Contacts.Contact
  alias Kith.Contacts.DuplicateCandidate
  alias Kith.DuplicateDetection
  alias Kith.Repo

  @auto_merge_score 1.0

  # A name-only candidate never auto-merges, whatever its score: two different
  # people routinely share an identical first+last name. Such a pair stays a
  # pending `DuplicateCandidate` for manual review. A strong edge must carry at
  # least one of these concrete-signal reasons.
  @concrete_reasons ~w(email_match phone_match address_match)

  @type result :: %{
          merged: non_neg_integer(),
          skipped: non_neg_integer(),
          left_behind: non_neg_integer(),
          clusters_merged: non_neg_integer(),
          errors: [String.t()]
        }

  @doc """
  Runs the second pass for `account_id`.

  Options:

    * `:restrict_ids` — a list of contact ids; only candidate pairs whose
      *both* endpoints are in this list are considered. `nil` (default) scans
      the whole account.
    * `:min_score` — the strong-edge score floor (default `#{@auto_merge_score}`).
      Callers in this codebase never lower it below `1.0` except an explicit
      operator override. A name-only pair is excluded regardless of this value.
    * `:dry_run` — when `true`, report what would be merged and write nothing.
      The whole pass (including the detector scan it runs) executes inside a
      transaction that is always rolled back, so a dry run leaves zero rows
      behind.

  Returns `t:result/0`. `skipped` counts merge targets held back by the
  birthdate guard; `left_behind` counts contacts dropped from a merge target
  because their only link to it was a non-strong edge (sub-floor score or a
  name-only match).
  """
  @spec run(integer(), keyword()) :: result()
  def run(account_id, opts \\ []) when is_integer(account_id) do
    if Keyword.get(opts, :dry_run, false) do
      {:error, result} =
        Repo.transaction(fn -> Repo.rollback(execute(account_id, opts)) end)

      result
    else
      execute(account_id, opts)
    end
  end

  defp execute(account_id, opts) do
    min_score = Keyword.get(opts, :min_score, @auto_merge_score)
    dry_run = Keyword.get(opts, :dry_run, false)
    restrict_ids = opts[:restrict_ids]

    # `restrict_ids == []` means an import that created no contacts this run —
    # there is nothing to merge, so skip the full-account detector scan
    # entirely. `nil` (whole-account mix task) and a non-empty list both scan.
    if restrict_ids == [] do
      %{blank_result() | left_behind: 0}
    else
      DuplicateDetection.scan_account(account_id)
      merge_pending(account_id, min_score, dry_run, restrict_ids)
    end
  end

  defp merge_pending(account_id, min_score, dry_run, restrict_ids) do
    pairs = pending_pairs(account_id, restrict_ids)
    strong_pairs = Enum.filter(pairs, &strong_edge?(&1, min_score))
    strong_components = components(strong_pairs)
    contacts_by_id = load_contacts(account_id, strong_components)

    {result, merged_union} =
      strong_components
      |> Enum.filter(&(MapSet.size(&1) >= 2))
      |> Enum.reduce({blank_result(), MapSet.new()}, fn member_set, {acc, merged} ->
        members =
          member_set
          |> Enum.map(&Map.get(contacts_by_id, &1))
          |> Enum.reject(&is_nil/1)

        case process_cluster(members, dry_run, acc) do
          {:merged, acc} -> {acc, MapSet.union(merged, member_set)}
          {:not_merged, acc} -> {acc, merged}
        end
      end)

    # Only count contacts left behind by a component that actually merged —
    # a strong cluster held back by the birthdate guard leaves nothing behind.
    left_behind = left_behind_ids(components(pairs), merged_union)
    log_left_behind(left_behind)

    %{result | left_behind: MapSet.size(left_behind)}
  end

  defp blank_result do
    %{
      merged: 0,
      skipped: 0,
      left_behind: 0,
      clusters_merged: 0,
      errors: []
    }
  end

  defp process_cluster(members, dry_run, acc) do
    cond do
      length(members) < 2 ->
        {:not_merged, acc}

      birthdate_conflict?(members) ->
        Logger.info(
          "[DuplicateAutomerge] skipping cluster #{inspect(ids(members))}: members disagree " <>
            "on a non-empty birthdate"
        )

        {:not_merged, %{acc | skipped: acc.skipped + 1}}

      dry_run ->
        {:merged,
         %{
           acc
           | merged: acc.merged + length(members) - 1,
             clusters_merged: acc.clusters_merged + 1
         }}

      true ->
        merge_cluster(members, acc)
    end
  end

  # A strong edge clears the score floor AND rests on at least one concrete
  # signal (shared email/phone/address). A pair whose only reason is
  # `"name_match"` is never strong, even at score 1.0.
  defp strong_edge?(pair, min_score) do
    pair.score >= min_score and Enum.any?(pair.reasons, &(&1 in @concrete_reasons))
  end

  # Conservative on purpose: a `birthdate_year_unknown` contact whose day/month
  # happens to match another's full date is still treated as a conflict here.
  defp birthdate_conflict?(members) do
    members
    |> Enum.map(& &1.birthdate)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length() > 1
  end

  defp merge_cluster(members, acc) do
    primary = DuplicateDetection.default_primary(members)
    losers = Enum.reject(members, &(&1.id == primary.id))

    {merged, errors} =
      Enum.reduce(losers, {0, acc.errors}, fn loser, {count, errs} ->
        case Contacts.merge_contacts(primary.id, loser.id) do
          {:ok, _} ->
            {count + 1, errs}

          {:error, reason} ->
            msg =
              "[DuplicateAutomerge] failed to merge contact #{loser.id} into #{primary.id}: " <>
                inspect(reason)

            Logger.warning(msg)
            {count, errs ++ [msg]}
        end
      end)

    acc = %{
      acc
      | merged: acc.merged + merged,
        clusters_merged: acc.clusters_merged + if(merged > 0, do: 1, else: 0),
        errors: errors
    }

    {if(merged > 0, do: :merged, else: :not_merged), acc}
  end

  defp ids(members), do: members |> Enum.map(& &1.id) |> Enum.sort()

  defp log_left_behind(left_behind) do
    if MapSet.size(left_behind) > 0 do
      Logger.info(
        "[DuplicateAutomerge] not merging #{inspect(Enum.sort(left_behind))}: linked to a " <>
          "merged cluster only by a non-strong edge (sub-floor score, or a name-only match)"
      )
    end
  end

  # A contact is "left behind" only if it sits in a full-graph component
  # alongside a cluster that actually merged, yet was itself attached to that
  # cluster only by a non-strong edge (sub-floor score or name-only). If the
  # component's strong core never merged — no strong part, or the birthdate
  # guard held it back — nobody is left behind; they stay pending candidates.
  defp left_behind_ids(full_components, merged_union) do
    Enum.reduce(full_components, MapSet.new(), fn full, acc ->
      dropped = MapSet.difference(full, merged_union)
      merged_here = MapSet.intersection(full, merged_union)

      if MapSet.size(merged_here) >= 2 and MapSet.size(dropped) > 0 do
        MapSet.union(acc, dropped)
      else
        acc
      end
    end)
  end

  # ── Candidate loading + clustering ───────────────────────────────────

  defp pending_pairs(account_id, restrict_ids) do
    DuplicateCandidate
    |> where([d], d.account_id == ^account_id and d.status == "pending")
    |> maybe_restrict(restrict_ids)
    |> join(:inner, [d], c1 in Contact, on: c1.id == d.contact_id)
    |> join(:inner, [d], c2 in Contact, on: c2.id == d.duplicate_contact_id)
    |> where([d, c1, c2], is_nil(c1.deleted_at) and is_nil(c2.deleted_at))
    |> select([d], d)
    |> Repo.all()
  end

  defp maybe_restrict(query, nil), do: query

  defp maybe_restrict(query, ids) when is_list(ids) do
    id_list = ids |> MapSet.new() |> MapSet.to_list()

    where(
      query,
      [d],
      d.contact_id in ^id_list and d.duplicate_contact_id in ^id_list
    )
  end

  # Connected components (as a list of id `MapSet`s) over the given edge list,
  # via union-find. `Kith.DuplicateDetection`'s own clustering is private and
  # re-queries the DB with dismissed-edge handling; here the input is an
  # already-loaded, already-filtered list, so a local pass is simpler.
  defp components([]), do: []

  defp components(pairs) do
    parent =
      Enum.reduce(pairs, %{}, fn p, acc ->
        acc
        |> Map.put_new(p.contact_id, p.contact_id)
        |> Map.put_new(p.duplicate_contact_id, p.duplicate_contact_id)
      end)

    parent =
      Enum.reduce(pairs, parent, fn p, acc ->
        union(acc, p.contact_id, p.duplicate_contact_id)
      end)

    parent
    |> Map.keys()
    |> Enum.group_by(&find(parent, &1))
    |> Enum.map(fn {_root, member_ids} -> MapSet.new(member_ids) end)
  end

  defp find(parent, node) do
    case Map.fetch!(parent, node) do
      ^node -> node
      next -> find(parent, next)
    end
  end

  defp union(parent, a, b) do
    root_a = find(parent, a)
    root_b = find(parent, b)

    if root_a == root_b, do: parent, else: Map.put(parent, root_a, root_b)
  end

  defp load_contacts(_account_id, []), do: %{}

  defp load_contacts(account_id, components) do
    ids =
      components
      |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
      |> MapSet.to_list()

    Contact
    |> where([c], c.account_id == ^account_id and c.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
