defmodule Kith.Imports.DuplicateAutomerge do
  @moduledoc """
  Second pass of the Monica-import auto-merge (issue #2).

  The importer's first pass (`Kith.Imports.Sources.MonicaApi.auto_merge_duplicates/2`)
  only merges contacts that share an exact normalized `{first_name, last_name}`
  group **and** a concrete shared email/phone/address. The detector
  (`Kith.DuplicateDetection.scan_account/1`) scores pairs independently and
  flags many more at `1.0` — most often an identical `display_name` with
  nothing else shared, or a transitive chain where each link rests on a
  different signal. Those clusters survive the first pass and show up in the
  duplicates UI at "100%".

  This pass runs a fresh scan, clusters the resulting `pending`
  `DuplicateCandidate` rows (optionally restricted to a set of contact ids —
  e.g. one import's records, so pre-existing contacts are never touched),
  keeps clusters that carry at least one pair scoring `>= min_score`
  (default `1.0`), and merges each surviving cluster through
  `Kith.Contacts.merge_contacts/2` with `Kith.DuplicateDetection.default_primary/1`
  choosing the survivor. The merge path already settles the merged
  `DuplicateCandidate` rows via `Kith.DuplicateDetection.resolve_after_merge/4`,
  so `cluster_count/1` drops without extra work here.

  Safety guards — a qualifying cluster is skipped (and `Logger.info`-logged)
  when:

    * any pair's only reason is `["name_match"]` with similarity `< 1.0`
      (a fuzzy name match must never drive an automatic merge, and it must
      not do so by transitivity either), or
    * two members carry different non-empty `birthdate`s.
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
          clusters_merged: non_neg_integer(),
          errors: [String.t()]
        }

  @doc """
  Runs the second pass for `account_id`.

  Options:

    * `:restrict_ids` — a list of contact ids; only candidate pairs whose
      *both* endpoints are in this list are considered. `nil` (default) scans
      the whole account.
    * `:min_score` — minimum pair score for a cluster to qualify
      (default `#{@auto_merge_score}`). Never lowered below `1.0` by callers
      in this codebase.
    * `:dry_run` — when `true`, report what would be merged without writing.

  Returns `t:result/0`.
  """
  @spec run(integer(), keyword()) :: result()
  def run(account_id, opts \\ []) when is_integer(account_id) do
    dry_run = Keyword.get(opts, :dry_run, false)
    min_score = Keyword.get(opts, :min_score, @auto_merge_score)
    restrict_ids = opts[:restrict_ids]

    DuplicateDetection.scan_account(account_id)

    clusters =
      account_id
      |> pending_pairs(restrict_ids)
      |> build_clusters()

    contacts_by_id = load_contacts(account_id, clusters)

    Enum.reduce(clusters, blank_result(), fn {member_ids, pairs}, acc ->
      members =
        member_ids
        |> Enum.map(&Map.get(contacts_by_id, &1))
        |> Enum.reject(&is_nil/1)

      process_cluster(members, pairs, min_score, dry_run, acc)
    end)
  end

  defp blank_result, do: %{merged: 0, skipped: 0, clusters_merged: 0, errors: []}

  defp process_cluster(members, pairs, min_score, dry_run, acc) do
    cond do
      length(members) < 2 ->
        acc

      not Enum.any?(pairs, &(&1.score >= min_score)) ->
        acc

      fuzzy_name_only_pair?(pairs) ->
        Logger.info(
          "[DuplicateAutomerge] skipping cluster #{inspect(ids(members))}: a pair rests only " <>
            "on a fuzzy name match (name_sim < 1.0)"
        )

        %{acc | skipped: acc.skipped + 1}

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

  defp fuzzy_name_only_pair?(pairs) do
    Enum.any?(pairs, fn p -> p.reasons == ["name_match"] and p.score < 1.0 end)
  end

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

  # Small union-find over the candidate pairs. `Kith.DuplicateDetection`'s own
  # `build_clusters/1` is private and re-queries the DB with its dismissed-edge
  # handling; here the input is an already-loaded, already-filtered pending
  # list, so a local pass is simpler and avoids widening that module's surface.
  defp build_clusters(pairs) do
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
    |> Enum.map(fn {_root, member_ids} ->
      member_set = MapSet.new(member_ids)

      cluster_pairs =
        Enum.filter(pairs, fn p ->
          MapSet.member?(member_set, p.contact_id) and
            MapSet.member?(member_set, p.duplicate_contact_id)
        end)

      {Enum.sort(member_ids), cluster_pairs}
    end)
    |> Enum.filter(fn {member_ids, _pairs} -> length(member_ids) >= 2 end)
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

  defp load_contacts(account_id, clusters) do
    ids =
      clusters
      |> Enum.flat_map(fn {member_ids, _pairs} -> member_ids end)
      |> Enum.uniq()

    Contact
    |> where([c], c.account_id == ^account_id and c.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
