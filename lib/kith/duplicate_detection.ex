defmodule Kith.DuplicateDetection do
  import Ecto.Query, warn: false
  import Kith.Scope
  alias Kith.Contacts.DuplicateCandidate
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

  def dismiss_candidates_for_contact(account_id, contact_id) do
    from(dc in DuplicateCandidate,
      where: dc.account_id == ^account_id,
      where: dc.status == "pending",
      where: dc.contact_id == ^contact_id or dc.duplicate_contact_id == ^contact_id
    )
    |> Repo.update_all(set: [status: "dismissed", resolved_at: DateTime.utc_now()])
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
  """
  def resolve_after_merge(account_id, survivor_id, loser_ids, unchecked_ids) do
    merged_ids = [survivor_id | loser_ids]
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      set_status(account_id, merged_ids, merged_ids, "merged", now)
      set_status(account_id, merged_ids, unchecked_ids, "dismissed", now)
      repoint(account_id, survivor_id, loser_ids)
    end)

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

    winner =
      if existing &&
           Map.fetch!(@status_rank, existing.status) >= Map.fetch!(@status_rank, candidate.status) do
        existing.status
      else
        candidate.status
      end

    attrs = %{
      contact_id: low,
      duplicate_contact_id: high,
      score: candidate.score,
      reasons: candidate.reasons,
      status: winner,
      detected_at: candidate.detected_at,
      resolved_at: candidate.resolved_at
    }

    if existing do
      existing |> DuplicateCandidate.changeset(attrs) |> Repo.update!()
    else
      %DuplicateCandidate{account_id: account_id}
      |> DuplicateCandidate.changeset(attrs)
      |> Repo.insert!()
    end
  end
end
