defmodule Kith.DuplicateDetection do
  import Ecto.Query, warn: false
  import Kith.Scope
  alias Kith.Contacts.Address
  alias Kith.Contacts.Contact
  alias Kith.Contacts.ContactField
  alias Kith.Contacts.ContactFieldType
  alias Kith.Contacts.DuplicateCandidate
  alias Kith.DuplicateDetection.Cluster
  alias Kith.Repo

  @default_page_size 20

  def dismiss_candidate(%DuplicateCandidate{} = candidate) do
    invalidate_cluster_count(candidate.account_id)
    candidate |> DuplicateCandidate.dismiss_changeset() |> Repo.update()
  end

  @cluster_count_ttl :timer.minutes(5)

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
  # account's dismissed set grows without limit; loading all of it would make
  # every derivation proportional to the account's whole dismissal history
  # rather than to the work actually pending.
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

  # ── Detection scan ────────────────────────────────────────────────────
  #
  # Extracted verbatim from `Kith.Workers.DuplicateDetectionWorker` so the
  # Monica importer and the `kith.duplicates.automerge` mix task can trigger a
  # fresh scan synchronously, without enqueuing an Oban job. The worker now
  # calls `scan_account/1`; its cron path is unchanged.

  @doc """
  Runs the duplicate-detection scan for one account and upserts the resulting
  `DuplicateCandidate` rows.

  Detection algorithm:

    1. Name similarity via pg_trgm `similarity()` on `display_name` (> 0.5)
    2. Case-insensitive email match across `contact_fields`
    3. E.164 phone match across `contact_fields`
    4. Address match on normalized `line1` + `postal_code`

  Scoring (max-signal + bonus): `email_match` 0.85, `phone_match` 0.75,
  `address_match` 0.60, `name_match` the raw trigram similarity. Final score =
  `max(base scores) + 0.05` per additional signal, capped at 1.0. Pairs below
  0.5 are dropped; existing `pending`/`dismissed` pairs are never re-inserted.

  Returns `:ok`.
  """
  def scan_account(account_id) do
    contact_count =
      Contact
      |> where([c], c.account_id == ^account_id)
      |> where([c], is_nil(c.deleted_at))
      |> Repo.aggregate(:count)

    if contact_count >= 2, do: find_duplicates(account_id)

    :ok
  end

  defp find_duplicates(account_id) do
    name_matches = find_name_matches(account_id)
    email_matches = find_email_matches(account_id)
    phone_matches = find_phone_matches(account_id)
    address_matches = find_address_matches(account_id)

    all_pairs =
      merge_matches(name_matches, email_matches, phone_matches, address_matches)
      |> Enum.filter(fn {_pair, score, _reasons} -> score >= 0.5 end)

    existing =
      DuplicateCandidate
      |> where([d], d.account_id == ^account_id)
      |> where([d], d.status in ["pending", "dismissed"])
      |> select([d], {d.contact_id, d.duplicate_contact_id})
      |> Repo.all()
      |> MapSet.new()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(all_pairs, fn {{id1, id2}, score, reasons} ->
      {contact_id, dup_id} = if id1 < id2, do: {id1, id2}, else: {id2, id1}

      unless MapSet.member?(existing, {contact_id, dup_id}) do
        %DuplicateCandidate{account_id: account_id}
        |> DuplicateCandidate.changeset(%{
          contact_id: contact_id,
          duplicate_contact_id: dup_id,
          score: score,
          reasons: reasons,
          detected_at: now
        })
        |> Repo.insert(on_conflict: :nothing)
      end
    end)
  end

  defp find_name_matches(account_id) do
    query = """
    SELECT c1.id AS id1, c2.id AS id2, similarity(c1.display_name, c2.display_name) AS sim
    FROM contacts c1
    JOIN contacts c2 ON c1.id < c2.id
      AND c1.account_id = c2.account_id
    WHERE c1.account_id = $1
      AND c1.deleted_at IS NULL
      AND c2.deleted_at IS NULL
      AND c1.display_name IS NOT NULL AND c1.display_name != ''
      AND c2.display_name IS NOT NULL AND c2.display_name != ''
      AND similarity(c1.display_name, c2.display_name) > 0.5
    ORDER BY sim DESC
    LIMIT 500
    """

    case Repo.query(query, [account_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id1, id2, sim] ->
          {{id1, id2}, sim, ["name_match"]}
        end)

      _ ->
        []
    end
  end

  defp find_email_matches(account_id) do
    # Case-insensitive email match on TRIMmed values. Trim is required because
    # CardDAV-style imports occasionally leak trailing whitespace; the != ''
    # checks on the trimmed form prevent whitespace-only values from forming a
    # cartesian product across all such rows.
    query =
      from cf1 in ContactField,
        join: cf2 in ContactField,
        on:
          fragment("LOWER(TRIM(?))", cf1.value) == fragment("LOWER(TRIM(?))", cf2.value) and
            cf1.id < cf2.id,
        join: cft1 in ContactFieldType,
        on: cf1.contact_field_type_id == cft1.id,
        join: cft2 in ContactFieldType,
        on: cf2.contact_field_type_id == cft2.id,
        where: cf1.account_id == ^account_id,
        where: cf2.account_id == ^account_id,
        where: fragment("? LIKE 'mailto%'", cft1.protocol),
        where: fragment("? LIKE 'mailto%'", cft2.protocol),
        where: cf1.contact_id != cf2.contact_id,
        where: not is_nil(cf1.value) and fragment("TRIM(?) <> ''", cf1.value),
        where: not is_nil(cf2.value) and fragment("TRIM(?) <> ''", cf2.value),
        select: {cf1.contact_id, cf2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["email_match"]} end)
  end

  defp find_phone_matches(account_id) do
    # Phone values are normalized to E.164 on import (see
    # `Kith.Contacts.PhoneFormatter.normalize/2`), so this becomes a plain
    # equality join.
    query =
      from cf1 in ContactField,
        join: cf2 in ContactField,
        on: cf1.value == cf2.value and cf1.id < cf2.id,
        join: cft1 in ContactFieldType,
        on: cf1.contact_field_type_id == cft1.id,
        join: cft2 in ContactFieldType,
        on: cf2.contact_field_type_id == cft2.id,
        where: cf1.account_id == ^account_id,
        where: cf2.account_id == ^account_id,
        where: fragment("? LIKE 'tel%'", cft1.protocol),
        where: fragment("? LIKE 'tel%'", cft2.protocol),
        where: cf1.contact_id != cf2.contact_id,
        where: not is_nil(cf1.value) and fragment("TRIM(?) <> ''", cf1.value),
        where: not is_nil(cf2.value) and fragment("TRIM(?) <> ''", cf2.value),
        select: {cf1.contact_id, cf2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["phone_match"]} end)
  end

  defp find_address_matches(account_id) do
    # Match on normalized line1 + postal_code
    query =
      from a1 in Address,
        join: a2 in Address,
        on:
          fragment("LOWER(TRIM(?))", a1.line1) == fragment("LOWER(TRIM(?))", a2.line1) and
            fragment("LOWER(TRIM(?))", a1.postal_code) ==
              fragment("LOWER(TRIM(?))", a2.postal_code) and
            a1.id < a2.id,
        where: a1.account_id == ^account_id,
        where: a2.account_id == ^account_id,
        where: a1.contact_id != a2.contact_id,
        where: a1.line1 != "" and not is_nil(a1.line1),
        where: a1.postal_code != "" and not is_nil(a1.postal_code),
        where: a2.line1 != "" and not is_nil(a2.line1),
        where: a2.postal_code != "" and not is_nil(a2.postal_code),
        select: {a1.contact_id, a2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["address_match"]} end)
  end

  defp merge_matches(name_matches, email_matches, phone_matches, address_matches) do
    (name_matches ++ email_matches ++ phone_matches ++ address_matches)
    |> Enum.group_by(fn {pair, _score, _reasons} -> pair end)
    |> Enum.map(&compute_merged_score/1)
  end

  defp compute_merged_score({pair, matches}) do
    reasons = matches |> Enum.flat_map(fn {_, _, r} -> r end) |> Enum.uniq()
    name_sim = Enum.find_value(matches, 0.0, &extract_name_score/1)

    base_scores =
      []
      |> then(fn acc -> if "email_match" in reasons, do: [0.85 | acc], else: acc end)
      |> then(fn acc -> if "phone_match" in reasons, do: [0.75 | acc], else: acc end)
      |> then(fn acc -> if "address_match" in reasons, do: [0.60 | acc], else: acc end)
      |> then(fn acc -> if name_sim > 0.0, do: [name_sim | acc], else: acc end)

    signal_count = length(base_scores)
    max_score = Enum.max(base_scores, fn -> 0.0 end)
    bonus = max(signal_count - 1, 0) * 0.05

    score = min(max_score + bonus, 1.0)

    {pair, Float.round(score, 2), reasons}
  end

  defp extract_name_score({_, score, reasons}) do
    if "name_match" in reasons, do: score
  end
end
