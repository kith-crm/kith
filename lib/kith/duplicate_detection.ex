defmodule Kith.DuplicateDetection do
  import Ecto.Query, warn: false
  import Kith.Scope
  alias Kith.Contacts.Contact
  alias Kith.Contacts.DuplicateCandidate
  alias Kith.DuplicateDetection.Cluster
  alias Kith.Repo

  @default_page_size 20

  def list_candidates(account_id, opts \\ []) do
    status = Keyword.get(opts, :status, "pending")
    limit = Keyword.get(opts, :limit, @default_page_size)
    offset = Keyword.get(opts, :offset, 0)

    DuplicateCandidate
    |> scope_to_account(account_id)
    |> where([d], d.status == ^status)
    |> order_by([d], desc: d.score)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Repo.preload([:contact, :duplicate_contact])
  end

  def get_candidate!(account_id, id) do
    DuplicateCandidate
    |> scope_to_account(account_id)
    |> Repo.get!(id)
    |> Repo.preload([:contact, :duplicate_contact])
  end

  def dismiss_candidate(%DuplicateCandidate{} = candidate) do
    invalidate_cluster_count(candidate.account_id)
    candidate |> DuplicateCandidate.dismiss_changeset() |> Repo.update()
  end

  def mark_merged(%DuplicateCandidate{} = candidate) do
    invalidate_cluster_count(candidate.account_id)
    candidate |> DuplicateCandidate.merge_changeset() |> Repo.update()
  end

  @cluster_count_ttl :timer.minutes(5)

  def pending_count(account_id) do
    DuplicateCandidate
    |> scope_to_account(account_id)
    |> where([d], d.status == "pending")
    |> Repo.aggregate(:count)
  end

  def pending_candidates_for_contact(account_id, contact_id) do
    from(dc in DuplicateCandidate,
      where: dc.account_id == ^account_id,
      where: dc.status == "pending",
      where: dc.contact_id == ^contact_id or dc.duplicate_contact_id == ^contact_id,
      order_by: [desc: :score],
      preload: [:contact, :duplicate_contact]
    )
    |> Repo.all()
  end

  @status_rank %{"pending" => 0, "dismissed" => 1, "merged" => 2}

  @doc """
  Settles candidate pairs after a merge.

  Three rules, from the design spec §2. Let `S` be the merged set (survivor +
  losers) and `U` the unchecked ids:

    * both endpoints in `S` → `merged`
    * one endpoint in `S`, one in `U` → `dismissed` (the user reviewed and
      rejected that match)
    * both endpoints in `U` → untouched

  Then every remaining pair referencing a loser is repointed onto the
  survivor, because the survivor now *is* that contact. Without repointing, a
  dismissal recorded against a loser evaporates when the loser is trashed and
  the rejected match returns on the next scan.

  Callers must run this inside their own transaction (the engine's `Multi`
  does) — this function does not open one itself, since wrapping it here
  would only nest inside that outer transaction and swallow a rollback
  raised by any step, silently losing it as this function's result is
  discarded and always `:ok`.

  `unchecked_ids` is defensively subtracted from the merged set: if a caller
  passes an id in both, treating it as "merged" wins (it's a member being
  merged) — an id can't simultaneously be unchecked, so the overlap is
  dropped from `unchecked_ids` before either rule runs. This guards the
  trashed-endpoint invariant: without it, an overlapping id would let the
  second call downgrade a `merged` row to `dismissed`.
  """
  def resolve_after_merge(account_id, survivor_id, loser_ids, unchecked_ids) do
    merged_ids = [survivor_id | loser_ids]
    unchecked_ids = unchecked_ids -- merged_ids
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    set_status(account_id, merged_ids, merged_ids, "merged", now)
    set_status(account_id, merged_ids, unchecked_ids, "dismissed", now)
    repoint(account_id, survivor_id, loser_ids)

    :ok
  end

  defp set_status(_account_id, _left, [], _status, _now), do: :ok

  defp set_status(account_id, left, right, status, now) do
    from(d in DuplicateCandidate,
      where: d.account_id == ^account_id,
      where:
        (d.contact_id in ^left and d.duplicate_contact_id in ^right) or
          (d.contact_id in ^right and d.duplicate_contact_id in ^left)
    )
    |> Repo.update_all(set: [status: status, resolved_at: now])
  end

  # Delete-then-insert rather than update_all: the unique index on
  # (account_id, contact_id, duplicate_contact_id) and the contact_id
  # ordering check constraint both reject an in-place rewrite.
  #
  # Only rows with exactly one endpoint in the merged set (survivor + losers)
  # qualify: a row with both endpoints already inside the merged set was just
  # settled to "merged" by `set_status/5` above, and repointing it here would
  # collapse it onto a self-pair (survivor, survivor) and silently drop it —
  # destroying the very row `set_status/5` just wrote.
  defp repoint(_account_id, _survivor_id, []), do: :ok

  defp repoint(account_id, survivor_id, loser_ids) do
    merged_ids = [survivor_id | loser_ids]

    query =
      from(d in DuplicateCandidate,
        where: d.account_id == ^account_id,
        where:
          (d.contact_id in ^loser_ids and d.duplicate_contact_id not in ^merged_ids) or
            (d.duplicate_contact_id in ^loser_ids and d.contact_id not in ^merged_ids)
      )

    rows = Repo.all(query)
    Repo.delete_all(query)

    rows
    |> Enum.map(&repoint_row(&1, survivor_id, loser_ids))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn row -> {row.contact_id, row.duplicate_contact_id} end)
    |> Enum.each(fn {{low, high}, candidates} ->
      strongest = Enum.max_by(candidates, &Map.fetch!(@status_rank, &1.status))
      merge_or_insert(account_id, low, high, strongest)
    end)
  end

  defp repoint_row(row, survivor_id, loser_ids) do
    one = if row.contact_id in loser_ids, do: survivor_id, else: row.contact_id

    two =
      if row.duplicate_contact_id in loser_ids, do: survivor_id, else: row.duplicate_contact_id

    if one == two do
      nil
    else
      {low, high} = if one < two, do: {one, two}, else: {two, one}
      %{row | contact_id: low, duplicate_contact_id: high}
    end
  end

  defp merge_or_insert(account_id, low, high, candidate) do
    invalidate_cluster_count(account_id)

    existing =
      Repo.one(
        from(d in DuplicateCandidate,
          where:
            d.account_id == ^account_id and d.contact_id == ^low and
              d.duplicate_contact_id == ^high
        )
      )

    # The winner is a whole row, not just a status: a row's score, reasons and
    # timestamps describe the match that produced *that* status, so pairing the
    # existing row's status with the repointed row's evidence would misreport
    # both.
    winner =
      if existing &&
           Map.fetch!(@status_rank, existing.status) >= Map.fetch!(@status_rank, candidate.status) do
        existing
      else
        candidate
      end

    attrs = %{
      contact_id: low,
      duplicate_contact_id: high,
      score: winner.score,
      reasons: winner.reasons,
      status: winner.status,
      detected_at: winner.detected_at,
      resolved_at: winner.resolved_at
    }

    if existing do
      existing |> DuplicateCandidate.changeset(attrs) |> Repo.update!()
    else
      %DuplicateCandidate{account_id: account_id}
      |> DuplicateCandidate.changeset(attrs)
      |> Repo.insert!()
    end
  end

  @doc """
  Lists derived duplicate clusters, highest confidence first.

  Options: `:limit` (default #{@default_page_size}), `:offset` (default 0).
  """
  def list_clusters(account_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    offset = Keyword.get(opts, :offset, 0)

    account_id
    |> build_clusters()
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  @doc """
  Lists a page of derived clusters together with the total cluster count, from
  a single cluster derivation.

  Prefer this over separate `list_clusters/2` + `cluster_count/1` calls when
  both are needed for the same request (e.g. rendering a page and its total),
  since each derivation re-runs the candidate query and the union-find pass.

  Options: `:limit` (default #{@default_page_size}), `:offset` (default 0).
  """
  def list_clusters_page(account_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    offset = Keyword.get(opts, :offset, 0)

    clusters = build_clusters(account_id)

    %{clusters: clusters |> Enum.drop(offset) |> Enum.take(limit), total: length(clusters)}
  end

  @doc """
  How many clusters are pending review.

  Counts groups directly from the union-find derivation rather than building
  full `%Cluster{}` structs, so it never queries contacts.

  Cached per account. This is the sidebar badge, which `KithWeb.UserAuth`
  resolves in an `on_mount` hook — so it runs for every authenticated
  LiveView, twice per navigation (disconnected then connected mount), on a
  screen that may have nothing to do with duplicates. Every write path that
  can change the answer drops the entry, so the TTL is only a backstop against
  a change made outside this module.
  """
  def cluster_count(account_id) do
    case Cachex.fetch(:kith_cache, cluster_count_key(account_id), fn _key ->
           {:commit, compute_cluster_count(account_id), ttl: @cluster_count_ttl}
         end) do
      {:ok, count} -> count
      {:commit, count} -> count
      # A cache that is down or erroring must not take the badge — and with it
      # every authenticated page — down with it.
      _ -> compute_cluster_count(account_id)
    end
  end

  defp compute_cluster_count(account_id) do
    {acc, _pending} = derive_groups(account_id)
    Enum.count(acc.groups, fn {_id, members} -> MapSet.size(members) >= 2 end)
  end

  defp cluster_count_key(account_id), do: {:duplicate_cluster_count, account_id}

  # Called from every path that inserts, updates or resolves a candidate row.
  # Placed on the low-level writes rather than the public entry points so a new
  # caller cannot route around it.
  defp invalidate_cluster_count(account_id) do
    Cachex.del(:kith_cache, cluster_count_key(account_id))
    :ok
  end

  defp build_clusters(account_id) do
    {acc, pending} = derive_groups(account_id)
    to_clusters(acc, account_id, pending)
  end

  defp derive_groups(account_id) do
    pending = pending_candidates(account_id)
    negatives = pending |> blocking_dismissed(account_id) |> index_negatives()

    acc =
      pending
      # Fully deterministic: scores come from a small fixed set, so ties are
      # the common case. Without the id tiebreak, which edge wins would
      # depend on arbitrary row order and clustering would vary between
      # identical runs.
      |> Enum.sort_by(&{-&1.score, &1.contact_id, &1.duplicate_contact_id})
      |> Enum.reduce(%{groups: %{}, of: %{}, next: 0}, &union_pair(&2, &1, negatives))

    {acc, pending}
  end

  defp pending_candidates(account_id) do
    DuplicateCandidate
    |> scope_to_account(account_id)
    |> where([d], d.status == "pending")
    |> join(:inner, [d], one in Contact,
      on: one.id == d.contact_id and one.account_id == ^account_id
    )
    |> join(:inner, [d, one], two in Contact,
      on: two.id == d.duplicate_contact_id and two.account_id == ^account_id
    )
    |> where([d, one, two], is_nil(one.deleted_at) and is_nil(two.deleted_at))
    |> select([d], d)
    |> Repo.all()
  end

  # Only dismissed pairs with *both* endpoints in the pending set can change
  # the outcome: `ensure_group/2` is called with nothing but pending endpoints,
  # so every group member is one, and `blocked?/4` only ever looks up ids drawn
  # from two groups. A negative edge touching a contact no pending pair
  # mentions can never be consulted.
  #
  # This is what keeps the derivation bounded. Dismissed rows are permanent and
  # `dismiss_selection/3` writes a full clique over the selection, so the
  # account's dismissed set grows without limit — loading all of it made every
  # derivation proportional to the account's whole dismissal history rather
  # than to the work actually pending.
  #
  # The endpoints came from the join above, so they are already known live and
  # account-scoped; the contacts join is not repeated here.
  defp blocking_dismissed([], _account_id), do: []

  defp blocking_dismissed(pending, account_id) do
    ids =
      Enum.reduce(pending, MapSet.new(), fn d, acc ->
        acc |> MapSet.put(d.contact_id) |> MapSet.put(d.duplicate_contact_id)
      end)
      |> MapSet.to_list()

    DuplicateCandidate
    |> scope_to_account(account_id)
    |> where([d], d.status == "dismissed")
    |> where([d], d.contact_id in ^ids and d.duplicate_contact_id in ^ids)
    |> select([d], d)
    |> Repo.all()
  end

  # Dismissed pairs indexed as contact_id => the set of contact ids it was
  # dismissed against, so `blocked?/4` can look up membership instead of
  # scanning them. Only the pairs `blocking_dismissed/2` kept reach here.
  defp index_negatives(dismissed) do
    Enum.reduce(dismissed, %{}, fn d, acc ->
      acc
      |> Map.update(
        d.contact_id,
        MapSet.new([d.duplicate_contact_id]),
        &MapSet.put(&1, d.duplicate_contact_id)
      )
      |> Map.update(
        d.duplicate_contact_id,
        MapSet.new([d.contact_id]),
        &MapSet.put(&1, d.contact_id)
      )
    end)
  end

  defp union_pair(acc, pair, negatives) do
    {acc, group_a} = ensure_group(acc, pair.contact_id)
    {acc, group_b} = ensure_group(acc, pair.duplicate_contact_id)

    cond do
      group_a == group_b -> acc
      blocked?(acc, group_a, group_b, negatives) -> acc
      true -> merge_groups(acc, group_a, group_b)
    end
  end

  defp ensure_group(acc, contact_id) do
    case Map.fetch(acc.of, contact_id) do
      {:ok, group_id} ->
        {acc, group_id}

      :error ->
        group_id = acc.next

        acc = %{
          acc
          | groups: Map.put(acc.groups, group_id, MapSet.new([contact_id])),
            of: Map.put(acc.of, contact_id, group_id),
            next: group_id + 1
        }

        {acc, group_id}
    end
  end

  # A dismissed pair is a negative edge: the user already reviewed those two
  # contacts and rejected the match, so no third contact may reunite them by
  # transitivity. Walks the smaller of the two member sets, doing a map
  # lookup + set-disjoint check per member against the larger set — O(min(|a|,
  # |b|)) instead of scanning every dismissed pair in the account.
  defp blocked?(acc, group_a, group_b, negatives) do
    members_a = Map.fetch!(acc.groups, group_a)
    members_b = Map.fetch!(acc.groups, group_b)

    {small, large} =
      if MapSet.size(members_a) <= MapSet.size(members_b) do
        {members_a, members_b}
      else
        {members_b, members_a}
      end

    Enum.any?(small, fn id ->
      case Map.fetch(negatives, id) do
        {:ok, partners} -> not MapSet.disjoint?(partners, large)
        :error -> false
      end
    end)
  end

  defp merge_groups(acc, group_a, group_b) do
    members_b = Map.fetch!(acc.groups, group_b)
    members = MapSet.union(Map.fetch!(acc.groups, group_a), members_b)

    of = Enum.reduce(members_b, acc.of, &Map.put(&2, &1, group_a))

    %{acc | groups: acc.groups |> Map.put(group_a, members) |> Map.delete(group_b), of: of}
  end

  defp to_clusters(acc, account_id, pending) do
    contacts =
      acc.of
      |> Map.keys()
      |> then(fn ids ->
        Contact |> scope_to_account(account_id) |> where([c], c.id in ^ids) |> Repo.all()
      end)
      |> Map.new(&{&1.id, &1})

    acc.groups
    |> Enum.map(fn {_id, members} -> build_cluster(members, pending, contacts) end)
    |> Enum.filter(fn cluster -> length(cluster.contacts) >= 2 end)
    |> Enum.sort_by(&{-&1.max_score, &1.key})
  end

  defp build_cluster(members, pending, contacts) do
    pairs =
      Enum.filter(pending, fn p ->
        MapSet.member?(members, p.contact_id) and
          MapSet.member?(members, p.duplicate_contact_id)
      end)

    member_contacts =
      members
      |> Enum.map(&Map.get(contacts, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.id)

    %Cluster{
      key: members |> Enum.min(),
      contacts: member_contacts,
      pairs: pairs,
      max_score: pairs |> Enum.map(& &1.score) |> Enum.max(fn -> 0.0 end),
      reasons: pairs |> Enum.flat_map(& &1.reasons) |> Enum.uniq()
    }
  end

  @doc """
  Finds the cluster containing `contact_id`, or `nil`.

  Takes any member id rather than only the cluster key, so a bookmark survives
  the key shifting when a lower-id member joins.
  """
  def get_cluster(account_id, contact_id) do
    account_id
    |> build_clusters()
    |> Enum.find(fn cluster ->
      Enum.any?(cluster.contacts, &(&1.id == contact_id))
    end)
  end

  @count_schemas [
    Kith.Contacts.Note,
    Kith.Contacts.Address,
    Kith.Contacts.ContactField,
    Kith.Contacts.Document,
    Kith.Contacts.Photo,
    Kith.Activities.Call,
    Kith.Activities.LifeEvent
  ]

  @doc """
  The member that should survive by default: the one holding the most attached
  records, tie-broken by earliest creation, then by lowest id.

  Moving the fewest rows is the cheap part; the real reason is that the richest,
  oldest record is the id external clients (CardDAV, Immich) are already pinned
  to. The id tiebreak makes the choice deterministic on its own — without it,
  a tie on both count and `inserted_at` (easy with second-precision timestamps
  and a bulk import) would resolve by whatever order `contacts` happened to be
  passed in, an accident of the caller rather than a rule.

  `contacts` must be non-empty; callers only ever pass cluster members, and a
  cluster always has at least two.
  """
  def default_primary(contacts) do
    ids = Enum.map(contacts, & &1.id)
    counts = attached_counts(ids)

    Enum.max_by(contacts, fn contact ->
      {Map.get(counts, contact.id, 0), -DateTime.to_unix(contact.inserted_at), -contact.id}
    end)
  end

  defp attached_counts(ids) do
    schema_counts =
      Enum.reduce(@count_schemas, %{}, fn schema, acc ->
        from(r in schema,
          where: r.contact_id in ^ids,
          group_by: r.contact_id,
          select: {r.contact_id, count(r.id)}
        )
        |> Repo.all()
        |> Enum.reduce(acc, fn {id, n}, acc -> Map.update(acc, id, n, &(&1 + n)) end)
      end)

    from(ac in "activity_contacts",
      where: ac.contact_id in ^ids,
      group_by: ac.contact_id,
      select: {ac.contact_id, count()}
    )
    |> Repo.all()
    |> Enum.reduce(schema_counts, fn {id, n}, acc -> Map.update(acc, id, n, &(&1 + n)) end)
  end

  @doc """
  Records that the selected members are not duplicates of each other.

  Writes the full clique over `selected_ids` rather than only the pairs
  detection happened to produce: a cluster is often a chain (A–B, B–C), and
  dismissing only those leaves no negative edge between A and C. Pairs between
  two unchecked members are never touched — the user excluded them, and
  excluding is not a statement about them.

  `selected_ids` and `unchecked_ids` are caller-supplied, so every id is
  verified to belong to `account_id` before anything is written — the
  candidate row's foreign key only proves the contact exists, not that it's
  this account's, and a bad caller could otherwise write a dismissal row
  referencing another account's contact. Ids that don't resolve to this
  account are silently dropped from their list rather than raising, since
  this is a bulk action driven by UI selection state, not a single-resource
  lookup.

  The whole batch of pairs is written inside one transaction, so a mid-loop
  failure cannot leave the clique half-written — some rejected matches
  recorded, others not — which for negative edges reopens exactly the
  transitivity hole the clique exists to close.

  The transaction bounds a failure but does not prevent one: `DuplicateCandidate`
  rows for the same pair are also written by `Kith.Workers.DuplicateDetectionWorker`,
  and a scan inserting the pair between this function's read and its write would
  otherwise violate the `[:account_id, :contact_id, :duplicate_contact_id]`
  unique index. Each pair is written with an upsert instead, so the racing row is
  dismissed rather than colliding.

  Returns `:ok`, or `{:error, reason}` if the transaction failed.
  """
  def dismiss_selection(account_id, selected_ids, unchecked_ids) do
    invalidate_cluster_count(account_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    selected_ids = owned_ids(account_id, selected_ids)
    unchecked_ids = owned_ids(account_id, unchecked_ids)

    cliques =
      for one <- selected_ids, two <- selected_ids, one < two, do: {one, two}

    crosses =
      for one <- selected_ids, two <- unchecked_ids, one != two do
        if one < two, do: {one, two}, else: {two, one}
      end

    Repo.transaction(fn ->
      (cliques ++ crosses)
      |> Enum.uniq()
      |> Enum.each(fn {low, high} -> upsert_dismissed(account_id, low, high, now) end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp owned_ids(_account_id, []), do: []

  defp owned_ids(account_id, ids) do
    Contact
    |> scope_to_account(account_id)
    |> where([c], c.id in ^ids)
    |> select([c], c.id)
    |> Repo.all()
  end

  defp upsert_dismissed(account_id, low, high, now) do
    case Repo.one(
           from(d in DuplicateCandidate,
             where:
               d.account_id == ^account_id and d.contact_id == ^low and
                 d.duplicate_contact_id == ^high
           )
         ) do
      nil ->
        insert_dismissed(account_id, low, high, now)

      %DuplicateCandidate{status: "merged"} = existing ->
        existing

      existing ->
        existing |> DuplicateCandidate.dismiss_changeset() |> Repo.update!()
    end
  end

  # A detection scan can insert this pair between the read above and this
  # write. `ON CONFLICT DO UPDATE` dismisses that row rather than colliding on
  # the unique index and rolling the whole clique back. The `status != "merged"`
  # guard preserves the same exemption the read path applies: a pair already
  # resolved by an actual merge is not reopened as a dismissal.
  #
  # When that guard excludes the row, Postgres updates nothing and returns no
  # row, which Ecto surfaces as `Ecto.StaleEntryError`. That is the intended
  # outcome — the merged row stands — so it is not a failure of the clique.
  defp insert_dismissed(account_id, low, high, now) do
    on_conflict =
      from(d in DuplicateCandidate,
        where: d.status != "merged",
        update: [set: [status: "dismissed", resolved_at: ^now, updated_at: ^now]]
      )

    %DuplicateCandidate{account_id: account_id}
    |> DuplicateCandidate.changeset(%{
      contact_id: low,
      duplicate_contact_id: high,
      score: 0.0,
      reasons: ["user_rejected"],
      status: "dismissed",
      detected_at: now,
      resolved_at: now
    })
    |> Repo.insert!(
      on_conflict: on_conflict,
      conflict_target: [:account_id, :contact_id, :duplicate_contact_id]
    )
  rescue
    Ecto.StaleEntryError -> :ok
  end
end
