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
    candidate |> DuplicateCandidate.dismiss_changeset() |> Repo.update()
  end

  def mark_merged(%DuplicateCandidate{} = candidate) do
    candidate |> DuplicateCandidate.merge_changeset() |> Repo.update()
  end

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

  @doc "How many clusters are pending review."
  def cluster_count(account_id), do: account_id |> build_clusters() |> length()

  defp build_clusters(account_id) do
    candidates =
      DuplicateCandidate
      |> scope_to_account(account_id)
      |> where([d], d.status in ["pending", "dismissed"])
      |> Repo.all()

    {pending, dismissed} = Enum.split_with(candidates, &(&1.status == "pending"))

    negatives =
      MapSet.new(dismissed, fn d -> {d.contact_id, d.duplicate_contact_id} end)

    pending
    # Fully deterministic: scores come from a small fixed set, so ties are the
    # common case. Without the id tiebreak, which edge wins would depend on
    # arbitrary row order and clustering would vary between identical runs.
    |> Enum.sort_by(&{-&1.score, &1.contact_id, &1.duplicate_contact_id})
    |> Enum.reduce(%{groups: %{}, of: %{}, next: 0}, &union_pair(&2, &1, negatives))
    |> to_clusters(pending)
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
  # transitivity.
  defp blocked?(acc, group_a, group_b, negatives) do
    members_a = Map.fetch!(acc.groups, group_a)
    members_b = Map.fetch!(acc.groups, group_b)

    Enum.any?(negatives, fn {one, two} ->
      (MapSet.member?(members_a, one) and MapSet.member?(members_b, two)) or
        (MapSet.member?(members_a, two) and MapSet.member?(members_b, one))
    end)
  end

  defp merge_groups(acc, group_a, group_b) do
    members_b = Map.fetch!(acc.groups, group_b)
    members = MapSet.union(Map.fetch!(acc.groups, group_a), members_b)

    of = Enum.reduce(members_b, acc.of, &Map.put(&2, &1, group_a))

    %{acc | groups: acc.groups |> Map.put(group_a, members) |> Map.delete(group_b), of: of}
  end

  defp to_clusters(acc, pending) do
    contacts =
      acc.of
      |> Map.keys()
      |> then(fn ids -> from(c in Contact, where: c.id in ^ids) |> Repo.all() end)
      |> Map.new(&{&1.id, &1})

    acc.groups
    |> Enum.filter(fn {_id, members} -> MapSet.size(members) >= 2 end)
    |> Enum.map(fn {_id, members} -> build_cluster(members, pending, contacts) end)
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
end
