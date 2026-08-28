defmodule Kith.DuplicateDetectionTest do
  use Kith.DataCase, async: true

  import Kith.Factory

  alias Kith.DuplicateDetection

  describe "dismiss_candidate/1" do
    test "sets status to dismissed and resolved_at" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)

      candidate =
        insert(:duplicate_candidate, account: account, contact: c1, duplicate_contact: c2)

      assert {:ok, dismissed} = DuplicateDetection.dismiss_candidate(candidate)
      assert dismissed.status == "dismissed"
      assert dismissed.resolved_at != nil
    end
  end

  describe "resolve_after_merge/4" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()
      account_id = user.account_id

      names = [a: "Ann", b: "Bea", c: "Cal", d: "Dee", e: "Eve"]

      contacts =
        Map.new(names, fn {key, name} ->
          {key, Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: name})}
        end)

      %{user: user, account_id: account_id, contacts: contacts}
    end

    defp pair!(account_id, one, two, status \\ "pending") do
      {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

      Repo.insert!(%Kith.Contacts.DuplicateCandidate{
        account_id: account_id,
        contact_id: low.id,
        duplicate_contact_id: high.id,
        score: 0.9,
        status: status,
        detected_at: DateTime.utc_now(:second)
      })
    end

    defp status_of(account_id, one, two) do
      {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

      Repo.one(
        from(d in Kith.Contacts.DuplicateCandidate,
          where:
            d.account_id == ^account_id and d.contact_id == ^low.id and
              d.duplicate_contact_id == ^high.id,
          select: d.status
        )
      )
    end

    test "pairs inside the merged set become merged", ctx do
      %{a: a, b: b} = ctx.contacts
      pair!(ctx.account_id, a, b)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      assert status_of(ctx.account_id, a, b) == "merged"
    end

    test "pairs from a merged member to an unchecked member become dismissed", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, a, d)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [d.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
    end

    test "pairs between two unchecked members are untouched", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, d, e)

      :ok =
        Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [d.id, e.id])

      assert status_of(ctx.account_id, d, e) == "pending"
    end

    test "a loser's dismissal is repointed onto the survivor", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, b, d, "dismissed")

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [d.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
      assert status_of(ctx.account_id, b, d) == nil
    end

    # `d` is deliberately NOT unchecked: set_status/5 then leaves both a-d and
    # b-d alone, so the two rows still hold *different* statuses by the time
    # repoint/3 collapses b-d onto a-d and @status_rank has to choose. Passing
    # `d` as unchecked would flatten both to "dismissed" first and the ranking
    # would never be exercised.
    test "repointing keeps the strongest status on collision", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, a, d, "merged")
      pair!(ctx.account_id, b, d, "pending")

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      assert status_of(ctx.account_id, a, d) == "merged"
    end

    test "the winning row keeps its own score, reasons and detected_at", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)

      existing = pair!(ctx.account_id, a, d, "merged")
      losing = pair!(ctx.account_id, b, d, "pending")

      detected = ~U[2025-06-01 00:00:00Z]

      Repo.update_all(
        from(x in Kith.Contacts.DuplicateCandidate, where: x.id == ^existing.id),
        set: [score: 0.42, reasons: ["existing"], detected_at: detected]
      )

      Repo.update_all(
        from(x in Kith.Contacts.DuplicateCandidate, where: x.id == ^losing.id),
        set: [score: 0.11, reasons: ["repointed"], detected_at: ~U[2026-06-01 00:00:00Z]]
      )

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      {low, high} = if a.id < d.id, do: {a.id, d.id}, else: {d.id, a.id}

      row =
        Repo.one!(
          from(x in Kith.Contacts.DuplicateCandidate,
            where:
              x.account_id == ^ctx.account_id and x.contact_id == ^low and
                x.duplicate_contact_id == ^high
          )
        )

      assert row.status == "merged"
      assert row.score == 0.42
      assert row.reasons == ["existing"]
      assert DateTime.compare(row.detected_at, detected) == :eq
    end

    test "pairs in an unrelated cluster are untouched", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, d, e)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      assert status_of(ctx.account_id, d, e) == "pending"
    end

    test "another account's pending pair is untouched", ctx do
      %{a: a, b: b} = ctx.contacts

      other_user = Kith.AccountsFixtures.user_fixture()
      other_account_id = other_user.account_id
      other_x = Kith.ContactsFixtures.contact_fixture(other_account_id, %{first_name: "Xan"})
      other_y = Kith.ContactsFixtures.contact_fixture(other_account_id, %{first_name: "Yaz"})
      pair!(other_account_id, other_x, other_y)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      assert status_of(other_account_id, other_x, other_y) == "pending"
    end

    test "two losers repointing to the same third contact collide without raising", ctx do
      %{a: a, b: b, c: c, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, a, c)
      pair!(ctx.account_id, b, c)
      pair!(ctx.account_id, b, d, "dismissed")
      pair!(ctx.account_id, c, d)

      :ok =
        Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id, c.id], [d.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
      assert status_of(ctx.account_id, b, d) == nil
      assert status_of(ctx.account_id, c, d) == nil
      assert status_of(ctx.account_id, b, c) == "merged"
    end

    test "every merged row has at least one trashed endpoint", ctx do
      %{a: a, b: b} = ctx.contacts
      pair!(ctx.account_id, a, b)

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^b.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      merged_rows =
        from(d in Kith.Contacts.DuplicateCandidate,
          where: d.status == "merged",
          join: c1 in Kith.Contacts.Contact,
          on: c1.id == d.contact_id,
          join: c2 in Kith.Contacts.Contact,
          on: c2.id == d.duplicate_contact_id,
          select: {c1.deleted_at, c2.deleted_at}
        )
        |> Repo.all()

      assert merged_rows != []
      assert Enum.all?(merged_rows, fn {one, two} -> one != nil or two != nil end)
    end
  end

  describe "list_clusters/2" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()
      account_id = user.account_id

      contacts =
        Map.new([a: "Ann", b: "Bea", c: "Cal", d: "Dee", e: "Eve"], fn {key, name} ->
          {key, Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: name})}
        end)

      %{user: user, account_id: account_id, contacts: contacts}
    end

    defp candidate!(account_id, one, two, opts \\ []) do
      {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

      Repo.insert!(%Kith.Contacts.DuplicateCandidate{
        account_id: account_id,
        contact_id: low.id,
        duplicate_contact_id: high.id,
        score: Keyword.get(opts, :score, 0.9),
        reasons: Keyword.get(opts, :reasons, ["email_match"]),
        status: Keyword.get(opts, :status, "pending"),
        detected_at: DateTime.utc_now(:second)
      })
    end

    defp member_ids(cluster), do: cluster.contacts |> Enum.map(& &1.id) |> Enum.sort()

    test "transitive pairs collapse into one cluster", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, b, c)

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert member_ids(cluster) == Enum.sort([a.id, b.id, c.id])
    end

    test "disjoint pairs stay separate", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, d, e)

      clusters = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert length(clusters) == 2
    end

    test "clusters are ordered by their highest score", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b, score: 0.6)
      candidate!(ctx.account_id, d, e, score: 0.95)

      [first, second] = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert first.max_score == 0.95
      assert second.max_score == 0.6
    end

    test "a cluster carries the union of its pair reasons", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      candidate!(ctx.account_id, a, b, reasons: ["email_match"])
      candidate!(ctx.account_id, b, c, reasons: ["phone_match", "email_match"])

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert Enum.sort(cluster.reasons) == ["email_match", "phone_match"]
    end

    test "the key is the lowest member id", ctx do
      %{a: a, b: b} = ctx.contacts
      candidate!(ctx.account_id, a, b)

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert cluster.key == Enum.min([a.id, b.id])
    end

    test "a dismissed pair blocks a transitive union", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      # A and C were reviewed and rejected; B links to both.
      candidate!(ctx.account_id, a, c, status: "dismissed")
      candidate!(ctx.account_id, a, b, score: 0.9)
      candidate!(ctx.account_id, b, c, score: 0.6)

      clusters = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert [cluster] = clusters
      assert member_ids(cluster) == Enum.sort([a.id, b.id])
      refute c.id in member_ids(cluster)
    end

    test "the stronger edge wins when a dismissal blocks the weaker", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      candidate!(ctx.account_id, a, c, status: "dismissed")
      candidate!(ctx.account_id, a, b, score: 0.6)
      candidate!(ctx.account_id, b, c, score: 0.9)

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert member_ids(cluster) == Enum.sort([b.id, c.id])
    end

    test "tied scores cluster deterministically", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      # A and C were dismissed, so (a,b) and (b,c) compete for B: only one can
      # win. With equal scores, the id-based tiebreak in the sort key decides
      # which one — (a,b) sorts first because a.id < b.id. Inserted in
      # reverse (b,c) then (a,b) order so DB/insertion order alone cannot
      # produce that result — only the explicit id tiebreak can.
      candidate!(ctx.account_id, a, c, status: "dismissed")
      candidate!(ctx.account_id, b, c, score: 0.85)
      candidate!(ctx.account_id, a, b, score: 0.85)

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert member_ids(cluster) == Enum.sort([a.id, b.id])

      first = Kith.DuplicateDetection.list_clusters(ctx.account_id) |> Enum.map(&member_ids/1)

      for _ <- 1..5 do
        assert Enum.map(Kith.DuplicateDetection.list_clusters(ctx.account_id), &member_ids/1) ==
                 first
      end
    end

    test "paginates over clusters, not pairs", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b, score: 0.95)
      candidate!(ctx.account_id, d, e, score: 0.6)

      assert [one] = Kith.DuplicateDetection.list_clusters(ctx.account_id, limit: 1)
      assert one.max_score == 0.95

      assert [two] = Kith.DuplicateDetection.list_clusters(ctx.account_id, limit: 1, offset: 1)
      assert two.max_score == 0.6
    end

    test "clusters never cross accounts", ctx do
      %{a: a, b: b} = ctx.contacts
      candidate!(ctx.account_id, a, b)

      other_user = Kith.AccountsFixtures.user_fixture()
      other_account_id = other_user.account_id

      other_x = Kith.ContactsFixtures.contact_fixture(other_account_id, %{first_name: "Xan"})
      other_y = Kith.ContactsFixtures.contact_fixture(other_account_id, %{first_name: "Yan"})
      candidate!(other_account_id, other_x, other_y)

      clusters = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert [cluster] = clusters
      assert member_ids(cluster) == Enum.sort([a.id, b.id])
      refute other_x.id in member_ids(cluster)
      refute other_y.id in member_ids(cluster)
    end

    test "cluster_count/1 counts derived clusters", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, d, e)

      assert Kith.DuplicateDetection.cluster_count(ctx.account_id) == 2
    end

    # cluster_count/1 is the sidebar badge and is cached per account, so every
    # write path has to drop the entry. Without that, dismissing a cluster
    # leaves the badge claiming it is still waiting for review.
    test "cluster_count/1 reflects a dismissal made after it was first read", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, d, e)

      assert Kith.DuplicateDetection.cluster_count(ctx.account_id) == 2

      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [])

      assert Kith.DuplicateDetection.cluster_count(ctx.account_id) == 1
    end

    # A dismissed pair only matters if both its endpoints are in the pending
    # set, which is what `blocking_dismissed/2` relies on to stay bounded.
    test "a dismissal against a contact with no pending pair changes nothing", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, a, d, status: "dismissed")

      before = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert Kith.DuplicateDetection.cluster_count(ctx.account_id) == 1
      assert [cluster] = before
      assert Enum.sort(member_ids(cluster)) == Enum.sort([a.id, b.id])
    end

    test "equal max_score breaks the tie by ascending key", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b, score: 0.8)
      candidate!(ctx.account_id, d, e, score: 0.8)

      [first, second] = Kith.DuplicateDetection.list_clusters(ctx.account_id)

      assert first.max_score == second.max_score
      assert first.key < second.key
    end
  end

  describe "get_cluster/2 and trashed members" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()

      contacts =
        Map.new([a: "Ann", b: "Bea", c: "Cal"], fn {key, name} ->
          {key, Kith.ContactsFixtures.contact_fixture(user.account_id, %{first_name: name})}
        end)

      %{user: user, account_id: user.account_id, contacts: contacts}
    end

    test "any member id resolves to the cluster", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, b, c)

      for member <- [a, b, c] do
        cluster = Kith.DuplicateDetection.get_cluster(ctx.account_id, member.id)
        assert cluster
        assert member.id in Enum.map(cluster.contacts, & &1.id)
      end
    end

    test "a contact in no cluster returns nil", ctx do
      assert Kith.DuplicateDetection.get_cluster(ctx.account_id, ctx.contacts.a.id) == nil
    end

    test "a trashed member is excluded and a one-member cluster disappears", ctx do
      %{a: a, b: b} = ctx.contacts
      candidate!(ctx.account_id, a, b)

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^b.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      assert Kith.DuplicateDetection.list_clusters(ctx.account_id) == []
      assert Kith.DuplicateDetection.get_cluster(ctx.account_id, a.id) == nil
    end

    test "a trashed member is dropped but a three-member cluster survives", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, b, c)

      Repo.update_all(from(x in Kith.Contacts.Contact, where: x.id == ^c.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      assert [cluster] = Kith.DuplicateDetection.list_clusters(ctx.account_id)
      assert Enum.map(cluster.contacts, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    end
  end

  describe "default_primary/1" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()
      %{user: user, account_id: user.account_id}
    end

    test "picks the member with the most attached records", ctx do
      thin = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Thin"})
      rich = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Rich"})

      Kith.ContactsFixtures.note_fixture(rich, ctx.user.id)
      Kith.ContactsFixtures.note_fixture(rich, ctx.user.id)
      Kith.ContactsFixtures.address_fixture(rich)
      Kith.ContactsFixtures.note_fixture(thin, ctx.user.id)

      assert Kith.DuplicateDetection.default_primary([thin, rich]).id == rich.id
    end

    test "breaks ties toward the earliest created", ctx do
      older = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Older"})
      newer = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Newer"})

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^older.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      older = Repo.get!(Kith.Contacts.Contact, older.id)

      assert Kith.DuplicateDetection.default_primary([newer, older]).id == older.id
    end
  end

  describe "dismiss_selection/3" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()

      contacts =
        Map.new([a: "Ann", b: "Bea", c: "Cal", d: "Dee", e: "Eve"], fn {key, name} ->
          {key, Kith.ContactsFixtures.contact_fixture(user.account_id, %{first_name: name})}
        end)

      %{account_id: user.account_id, contacts: contacts}
    end

    test "writes the full clique over the selected members", ctx do
      %{a: a, b: b, c: c} = ctx.contacts
      # A chain: only two pairs exist, but all three combinations must end up
      # dismissed or a later contact could reunite A and C by transitivity.
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, b, c)

      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id, c.id], [])

      assert status_of(ctx.account_id, a, b) == "dismissed"
      assert status_of(ctx.account_id, b, c) == "dismissed"
      assert status_of(ctx.account_id, a, c) == "dismissed"
    end

    test "dismisses selected-to-unchecked but never unchecked-to-unchecked", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      candidate!(ctx.account_id, a, b)
      candidate!(ctx.account_id, a, d)
      candidate!(ctx.account_id, d, e)

      :ok =
        Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [d.id, e.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
      assert status_of(ctx.account_id, b, d) == "dismissed"
      assert status_of(ctx.account_id, d, e) == "pending"
    end

    test "leaves a merged pair alone rather than downgrading it to dismissed", ctx do
      %{a: a, b: b} = ctx.contacts
      candidate!(ctx.account_id, a, b, status: "merged")

      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [])

      assert status_of(ctx.account_id, a, b) == "merged"
    end

    test "is idempotent over a pair it has already dismissed", ctx do
      %{a: a, b: b} = ctx.contacts

      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [])
      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [])

      assert status_of(ctx.account_id, a, b) == "dismissed"

      assert Repo.aggregate(
               from(d in Kith.Contacts.DuplicateCandidate,
                 where: d.account_id == ^ctx.account_id
               ),
               :count
             ) == 1
    end

    # Blind spot: these tests all run on one sandboxed connection, so none of
    # them reaches the `ON CONFLICT` branch in `insert_dismissed/4`. That branch
    # fires only when a detection scan inserts the pair between this function's
    # read and its write, which needs two real connections to provoke. What is
    # covered here is that both outcomes the branch has to preserve — a fresh
    # pair becomes "dismissed", a merged pair stays "merged" — hold on the read
    # path, and that a repeat call does not duplicate a row.

    test "rejects a selected id belonging to another account and writes nothing for it", ctx do
      %{a: a, b: b} = ctx.contacts
      other_user = Kith.AccountsFixtures.user_fixture()
      foreign = Kith.ContactsFixtures.contact_fixture(other_user.account_id, %{first_name: "Fox"})

      candidate!(ctx.account_id, a, b)

      :ok =
        Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id, foreign.id], [])

      count =
        Repo.aggregate(
          from(d in Kith.Contacts.DuplicateCandidate,
            where: d.contact_id == ^foreign.id or d.duplicate_contact_id == ^foreign.id
          ),
          :count
        )

      assert count == 0
    end

    test "rejects an unchecked id belonging to another account and writes nothing for it", ctx do
      %{a: a, b: b} = ctx.contacts
      other_user = Kith.AccountsFixtures.user_fixture()
      foreign = Kith.ContactsFixtures.contact_fixture(other_user.account_id, %{first_name: "Fox"})

      :ok = Kith.DuplicateDetection.dismiss_selection(ctx.account_id, [a.id, b.id], [foreign.id])

      count =
        Repo.aggregate(
          from(d in Kith.Contacts.DuplicateCandidate,
            where: d.contact_id == ^foreign.id or d.duplicate_contact_id == ^foreign.id
          ),
          :count
        )

      assert count == 0
    end
  end

  describe "scan_account/1" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      {account, _user} = setup_account()

      email_type_id =
        Repo.one!(
          from(t in "contact_field_types",
            where: t.protocol == "mailto:",
            select: t.id,
            limit: 1
          )
        )

      %{account: account, email_type_id: email_type_id}
    end

    defp pending_for(account_id) do
      Kith.Contacts.DuplicateCandidate
      |> where([d], d.account_id == ^account_id and d.status == "pending")
      |> Repo.all()
    end

    test "writes a name_match candidate for near-identical display names", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "John Smith",
        first_name: "John",
        last_name: "Smith"
      )

      insert(:contact,
        account: account,
        display_name: "John Smithe",
        first_name: "John",
        last_name: "Smithe"
      )

      assert :ok = DuplicateDetection.scan_account(account.id)

      assert [candidate] = pending_for(account.id)
      assert "name_match" in candidate.reasons
      assert candidate.score >= 0.5
    end

    test "scores an identical display_name pair at 1.0", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "Mary Jones",
        first_name: "Mary",
        last_name: "Jones"
      )

      insert(:contact,
        account: account,
        display_name: "Mary Jones",
        first_name: "Mary",
        last_name: "Jones"
      )

      assert :ok = DuplicateDetection.scan_account(account.id)

      assert [candidate] = pending_for(account.id)
      assert candidate.reasons == ["name_match"]
      assert candidate.score == 1.0
    end

    test "writes an email_match candidate for a shared address", %{
      account: account,
      email_type_id: email_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Aaa Bbb",
          first_name: "Aaa",
          last_name: "Bbb"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Ccc Ddd",
          first_name: "Ccc",
          last_name: "Ddd"
        )

      Kith.ContactsFixtures.contact_field_fixture(c1, email_type_id, %{
        "value" => "shared@example.com"
      })

      Kith.ContactsFixtures.contact_field_fixture(c2, email_type_id, %{
        "value" => "shared@example.com"
      })

      assert :ok = DuplicateDetection.scan_account(account.id)

      assert [candidate] = pending_for(account.id)
      assert "email_match" in candidate.reasons
    end

    test "is a no-op below two contacts", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "Solo Person",
        first_name: "Solo",
        last_name: "Person"
      )

      assert :ok = DuplicateDetection.scan_account(account.id)
      assert pending_for(account.id) == []
    end
  end
end
