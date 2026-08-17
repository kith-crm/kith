defmodule Kith.DuplicateDetectionTest do
  use Kith.DataCase, async: true

  import Kith.Factory

  alias Kith.DuplicateDetection

  describe "list_candidates/2" do
    test "returns pending candidates by default" do
      {account, _user} = setup_account()
      contact1 = insert(:contact, account: account)
      contact2 = insert(:contact, account: account)

      candidate =
        insert(:duplicate_candidate,
          account: account,
          contact: contact1,
          duplicate_contact: contact2,
          status: "pending"
        )

      assert [returned] = DuplicateDetection.list_candidates(account.id)
      assert returned.id == candidate.id
    end

    test "filters by status" do
      {account, _user} = setup_account()
      contact1 = insert(:contact, account: account)
      contact2 = insert(:contact, account: account)
      contact3 = insert(:contact, account: account)

      insert(:duplicate_candidate,
        account: account,
        contact: contact1,
        duplicate_contact: contact2,
        status: "pending"
      )

      dismissed =
        insert(:duplicate_candidate,
          account: account,
          contact: contact1,
          duplicate_contact: contact3,
          status: "dismissed",
          resolved_at: DateTime.utc_now(:second)
        )

      assert [returned] = DuplicateDetection.list_candidates(account.id, status: "dismissed")
      assert returned.id == dismissed.id
    end

    test "does not return candidates from another account" do
      {account1, _user1} = setup_account()
      {account2, _user2} = setup_account()
      c1 = insert(:contact, account: account1)
      c2 = insert(:contact, account: account1)
      c3 = insert(:contact, account: account2)
      c4 = insert(:contact, account: account2)

      insert(:duplicate_candidate, account: account1, contact: c1, duplicate_contact: c2)
      insert(:duplicate_candidate, account: account2, contact: c3, duplicate_contact: c4)

      assert [candidate] = DuplicateDetection.list_candidates(account1.id)
      assert candidate.account_id == account1.id
    end

    test "orders by score descending" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)
      c3 = insert(:contact, account: account)

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c2,
        score: 0.7
      )

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c3,
        score: 0.95
      )

      candidates = DuplicateDetection.list_candidates(account.id)
      scores = Enum.map(candidates, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "preloads contact and duplicate_contact" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)

      insert(:duplicate_candidate, account: account, contact: c1, duplicate_contact: c2)

      assert [candidate] = DuplicateDetection.list_candidates(account.id)
      assert candidate.contact.id == c1.id
      assert candidate.duplicate_contact.id == c2.id
    end
  end

  describe "get_candidate!/2" do
    test "returns candidate by id scoped to account" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)

      candidate =
        insert(:duplicate_candidate, account: account, contact: c1, duplicate_contact: c2)

      fetched = DuplicateDetection.get_candidate!(account.id, candidate.id)
      assert fetched.id == candidate.id
    end

    test "raises for candidate in another account" do
      {account1, _user1} = setup_account()
      {account2, _user2} = setup_account()
      c1 = insert(:contact, account: account1)
      c2 = insert(:contact, account: account1)

      candidate =
        insert(:duplicate_candidate, account: account1, contact: c1, duplicate_contact: c2)

      assert_raise Ecto.NoResultsError, fn ->
        DuplicateDetection.get_candidate!(account2.id, candidate.id)
      end
    end

    test "preloads contact and duplicate_contact" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)

      candidate =
        insert(:duplicate_candidate, account: account, contact: c1, duplicate_contact: c2)

      fetched = DuplicateDetection.get_candidate!(account.id, candidate.id)
      assert fetched.contact.id == c1.id
      assert fetched.duplicate_contact.id == c2.id
    end
  end

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

  describe "mark_merged/1" do
    test "sets status to merged and resolved_at" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)

      candidate =
        insert(:duplicate_candidate, account: account, contact: c1, duplicate_contact: c2)

      assert {:ok, merged} = DuplicateDetection.mark_merged(candidate)
      assert merged.status == "merged"
      assert merged.resolved_at != nil
    end
  end

  describe "pending_count/1" do
    test "returns count of pending candidates" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)
      c3 = insert(:contact, account: account)

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c2,
        status: "pending"
      )

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c3,
        status: "pending"
      )

      assert DuplicateDetection.pending_count(account.id) == 2
    end

    test "excludes non-pending candidates" do
      {account, _user} = setup_account()
      c1 = insert(:contact, account: account)
      c2 = insert(:contact, account: account)
      c3 = insert(:contact, account: account)

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c2,
        status: "pending"
      )

      insert(:duplicate_candidate,
        account: account,
        contact: c1,
        duplicate_contact: c3,
        status: "dismissed",
        resolved_at: DateTime.utc_now(:second)
      )

      assert DuplicateDetection.pending_count(account.id) == 1
    end

    test "returns 0 when no pending candidates" do
      {account, _user} = setup_account()
      assert DuplicateDetection.pending_count(account.id) == 0
    end

    test "does not count candidates from another account" do
      {account1, _user1} = setup_account()
      {account2, _user2} = setup_account()

      c1 = insert(:contact, account: account2)
      c2 = insert(:contact, account: account2)
      insert(:duplicate_candidate, account: account2, contact: c1, duplicate_contact: c2)

      assert DuplicateDetection.pending_count(account1.id) == 0
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

    test "repointing keeps the strongest status on collision", ctx do
      %{a: a, b: b, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, a, d, "dismissed")
      pair!(ctx.account_id, b, d)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [d.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
    end

    test "pairs in an unrelated cluster are untouched", ctx do
      %{a: a, b: b, d: d, e: e} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, d, e)

      :ok = Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id], [])

      assert status_of(ctx.account_id, d, e) == "pending"
    end

    test "two losers repointing to the same third contact collide without raising", ctx do
      %{a: a, b: b, c: c, d: d} = ctx.contacts
      pair!(ctx.account_id, a, b)
      pair!(ctx.account_id, a, c)
      pair!(ctx.account_id, b, d, "dismissed")
      pair!(ctx.account_id, c, d)

      :ok =
        Kith.DuplicateDetection.resolve_after_merge(ctx.account_id, a.id, [b.id, c.id], [d.id])

      assert status_of(ctx.account_id, a, d) == "dismissed"
      assert status_of(ctx.account_id, b, d) == nil
      assert status_of(ctx.account_id, c, d) == nil
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
end
