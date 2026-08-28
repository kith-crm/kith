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
  `DuplicateCandidate` graph (optionally restricted to a set of contact ids —
  e.g. one import's records, so pre-existing contacts are never touched):

    * an **edge** is a candidate pair; a **strong edge** scores `>= min_score`
      (default `1.0`);
    * a connected component of *strong* edges with two or more members is a
      merge target — every internal edge clears the floor by construction;
    * contacts that hang off such a component only through a weaker edge (a
      `0.85` email, a `0.60` address, a `name_sim < 1.0` name match) are left
      unmerged and `Logger.info`-logged.

  Each merge target is merged through `Kith.Contacts.merge_contacts/2` with
  `Kith.DuplicateDetection.default_primary/1` choosing the survivor. The merge
  path already settles the merged `DuplicateCandidate` rows via
  `Kith.DuplicateDetection.resolve_after_merge/4`, so `cluster_count/1` drops
  without extra work here.

  A merge target is still skipped (and `Logger.info`-logged) when two members
  carry different non-empty `birthdate`s.

  Requiring *every* internal edge to clear `min_score` subsumes the earlier
  explicit "fuzzy name-only edge" guard: at the default floor of `1.0` a
  name-only edge with `name_sim < 1.0` has `score < 1.0` and is simply not a
  strong edge. An operator who lowers `--min-score` is deliberately widening
  what counts as confident.
  """

  import Ecto.Query

  require Logger

  alias Kith.Contacts
  alias Kith.Contacts.Contact
  alias Kith.Contacts.DuplicateCandidate
  alias Kith.DuplicateDetection
  alias Kith.Repo

  @auto_merge_score 1.0

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
    * `:min_score` — the strong-edge floor (default `#{@auto_merge_score}`).
      Callers in this codebase never lower it below `1.0` except an explicit
      operator override.
    * `:dry_run` — when `true`, report what would be merged and write nothing.
      The whole pass (including the detector scan it runs) executes inside a
      transaction that is always rolled back, so a dry run leaves zero rows
      behind.

  Returns `t:result/0`. `skipped` counts merge targets held back by the
  birthdate guard; `left_behind` counts contacts dropped from a component
  because their only link to it was a sub-floor edge.
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

    DuplicateDetection.scan_account(account_id)

    pairs = pending_pairs(account_id, restrict_ids)
    strong_pairs = Enum.filter(pairs, &(&1.score >= min_score))

    strong_components = components(strong_pairs)
    left_behind = left_behind_ids(components(pairs), strong_components)
    log_left_behind(left_behind)

    contacts_by_id = load_contacts(account_id, strong_components)

    strong_components
    |> Enum.filter(&(MapSet.size(&1) >= 2))
    |> Enum.reduce(blank_result(left_behind), fn member_set, acc ->
      members =
        member_set
        |> Enum.map(&Map.get(contacts_by_id, &1))
        |> Enum.reject(&is_nil/1)

      process_cluster(members, dry_run, acc)
    end)
  end

  defp blank_result(left_behind) do
    %{
      merged: 0,
      skipped: 0,
      left_behind: MapSet.size(left_behind),
      clusters_merged: 0,
      errors: []
    }
  end

  defp process_cluster(members, dry_run, acc) do
    cond do
      length(members) < 2 ->
        acc

      birthdate_conflict?(members) ->
        Logger.info(
          "[DuplicateAutomerge] skipping cluster #{inspect(ids(members))}: members disagree " <>
            "on a non-empty birthdate"
        )

        %{acc | skipped: acc.skipped + 1}

      dry_run ->
        %{
          acc
          | merged: acc.merged + length(members) - 1,
            clusters_merged: acc.clusters_merged + 1
        }

      true ->
        merge_cluster(members, acc)
    end
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

    %{
      acc
      | merged: acc.merged + merged,
        clusters_merged: acc.clusters_merged + if(merged > 0, do: 1, else: 0),
        errors: errors
    }
  end

  defp ids(members), do: members |> Enum.map(& &1.id) |> Enum.sort()

  defp log_left_behind(left_behind) do
    if MapSet.size(left_behind) > 0 do
      Logger.info(
        "[DuplicateAutomerge] not merging #{inspect(Enum.sort(left_behind))}: linked to a " <>
          "merged cluster only by an edge scoring below the floor"
      )
    end
  end

  # Contacts that a full-graph component contains but no strong component does —
  # i.e. they were only ever attached through a sub-floor edge. Components with
  # no strong part at all (a plain non-confident pair) are not "left behind",
  # they simply never qualified, so they are excluded.
  defp left_behind_ids(full_components, strong_components) do
    strong_union = Enum.reduce(strong_components, MapSet.new(), &MapSet.union(&2, &1))

    Enum.reduce(full_components, MapSet.new(), fn full, acc ->
      dropped = MapSet.difference(full, strong_union)

      if MapSet.size(dropped) > 0 and MapSet.size(dropped) < MapSet.size(full) do
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
