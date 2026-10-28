defmodule Kith.Imports.DuplicateAutomergeTest do
  use Kith.DataCase, async: true

  import Kith.Factory
  import Kith.ContactsFixtures

  alias Kith.Contacts.Contact
  alias Kith.Contacts.DuplicateCandidate
  alias Kith.DuplicateDetection
  alias Kith.Imports.DuplicateAutomerge

  setup do
    seed_reference_data!()
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

  defp contact(account, display, first, last, attrs \\ %{}) do
    insert(
      :contact,
      Map.merge(
        %{account: account, display_name: display, first_name: first, last_name: last},
        attrs
      )
    )
  end

  defp seed_pair(account_id, one, two, score, reasons, status \\ "pending") do
    {low, high} = if one.id < two.id, do: {one.id, two.id}, else: {two.id, one.id}

    Repo.insert!(%DuplicateCandidate{
      account_id: account_id,
      contact_id: low,
      duplicate_contact_id: high,
      score: score,
      reasons: reasons,
      status: status,
      detected_at: DateTime.utc_now(:second)
    })
  end

  defp active_ids(account_id) do
    Contact
    |> where([c], c.account_id == ^account_id and is_nil(c.deleted_at))
    |> select([c], c.id)
    |> Repo.all()
    |> Enum.sort()
  end

  describe "run/2 — case (a): identical display_name, nothing else shared" do
    test "never auto-merges a name-only pair; leaves it pending for manual review", %{
      account: account
    } do
      a = contact(account, "Nadia Khan", "Nadia", "Khan")
      b = contact(account, "Nadia Khan", "Nadia", "Khan")

      assert %{merged: 0, skipped: 0, clusters_merged: 0, left_behind: 0, errors: []} =
               DuplicateAutomerge.run(account.id)

      remaining = active_ids(account.id)
      assert length(remaining) == 2
      assert a.id in remaining
      assert b.id in remaining
      # The detector still flags the pair — it is only held back from auto-merge.
      assert DuplicateDetection.cluster_count(account.id) >= 1
    end
  end

  describe "run/2 — case (b): transitive chain where every edge is strong" do
    test "merges all three members of an all-1.0 name+concrete A–B–C chain", %{account: account} do
      # Distinct display names so the scan adds no edges of its own; the chain
      # is seeded explicitly as A–B and B–C, both at 1.0 and each resting on a
      # concrete signal, with no A–C edge.
      a = contact(account, "Aaa One", "Aaa", "One")
      b = contact(account, "Bbb Two", "Bbb", "Two")
      c = contact(account, "Ccc Three", "Ccc", "Three")

      seed_pair(account.id, a, b, 1.0, ["name_match", "email_match"])
      seed_pair(account.id, b, c, 1.0, ["name_match", "phone_match"])

      assert %{merged: 2, skipped: 0, left_behind: 0, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id)

      assert length(active_ids(account.id)) == 1
    end
  end

  describe "run/2 — saved not-duplicates decisions" do
    defp dismissed_chain(account) do
      a = contact(account, "Aaa One", "Aaa", "One")
      b = contact(account, "Bbb Two", "Bbb", "Two")
      c = contact(account, "Ccc Three", "Ccc", "Three")

      # Insert the tied edges in reverse order: grouping must still prefer
      # A–B by id and never reunite A and C through B.
      seed_pair(account.id, b, c, 1.0, ["phone_match"])
      seed_pair(account.id, a, b, 1.0, ["email_match"])
      seed_pair(account.id, a, c, 1.0, ["email_match"], "dismissed")
      {a, b, c}
    end

    test "a directly dismissed match is not reopened by the scan", %{
      account: account,
      email_type_id: email_type_id
    } do
      a = contact(account, "Amy Poe", "Amy", "Poe")
      b = contact(account, "Amy Poe", "Amy", "Poe")
      contact_field_fixture(a, email_type_id, %{"value" => "amy@example.com"})
      contact_field_fixture(b, email_type_id, %{"value" => "amy@example.com"})
      pair = seed_pair(account.id, a, b, 1.0, ["email_match"], "dismissed")

      for _ <- 1..2 do
        assert %{merged: 0, errors: []} = DuplicateAutomerge.run(account.id)
        assert active_ids(account.id) == [a.id, b.id]
        assert Repo.reload!(pair).status == "dismissed"
      end
    end

    test "a third contact cannot reunite a dismissed pair, including on reruns", %{
      account: account
    } do
      {a, b, c} = dismissed_chain(account)

      assert %{merged: 1, clusters_merged: 1, errors: []} = DuplicateAutomerge.run(account.id)
      assert active_ids(account.id) == [a.id, c.id]
      refute is_nil(Repo.reload!(b).deleted_at)

      assert Repo.get_by!(DuplicateCandidate,
               account_id: account.id,
               contact_id: a.id,
               duplicate_contact_id: c.id
             ).status == "dismissed"

      assert %{merged: 0, errors: []} = DuplicateAutomerge.run(account.id)
      assert active_ids(account.id) == [a.id, c.id]
    end

    test "dry runs honor dismissals and choose tied edges deterministically", %{account: account} do
      {a, b, c} = dismissed_chain(account)

      groups = fn ->
        candidates =
          Repo.all(
            from d in DuplicateCandidate,
              where: d.account_id == ^account.id and d.status == "pending"
          )

        DuplicateDetection.candidate_groups(account.id, candidates)
      end

      expected = [MapSet.new([a.id, b.id]), MapSet.new([c.id])]

      for _ <- 1..2 do
        assert groups.() == expected

        assert %{merged: 1, clusters_merged: 1} =
                 DuplicateAutomerge.run(account.id, dry_run: true)

        assert active_ids(account.id) == [a.id, b.id, c.id]
        assert groups.() == expected
      end
    end

    test "restricted runs honor dismissals without touching contacts outside the set", %{
      account: account
    } do
      {a, b, c} = dismissed_chain(account)
      x = contact(account, "Xxx Four", "Xxx", "Four")
      y = contact(account, "Yyy Five", "Yyy", "Five")
      outside = seed_pair(account.id, x, y, 1.0, ["email_match"])

      assert %{merged: 1, errors: []} =
               DuplicateAutomerge.run(account.id, restrict_ids: [a.id, b.id, c.id])

      assert active_ids(account.id) == [a.id, c.id, x.id, y.id]
      assert Repo.reload!(outside).status == "pending"
    end

    test "another account's dismissal and contacts are untouched", %{account: account} do
      {other_account, _user} = setup_account()
      {x, y, z} = dismissed_chain(other_account)
      a = contact(account, "Aaa One", "Aaa", "One")
      b = contact(account, "Bbb Two", "Bbb", "Two")
      seed_pair(account.id, a, b, 1.0, ["email_match"])

      assert %{merged: 1, errors: []} = DuplicateAutomerge.run(account.id)
      assert active_ids(account.id) == [a.id]
      assert active_ids(other_account.id) == [x.id, y.id, z.id]

      assert Repo.get_by!(DuplicateCandidate,
               account_id: other_account.id,
               contact_id: x.id,
               duplicate_contact_id: z.id
             ).status == "dismissed"
    end
  end

  describe "run/2 — ruling: a non-strong edge leaves its contact behind" do
    test "merges A–B but not the C that hangs off a 0.85 edge, and logs it", %{account: account} do
      a = contact(account, "Aaa One", "Aaa", "One")
      b = contact(account, "Bbb Two", "Bbb", "Two")
      c = contact(account, "Ccc Three", "Ccc", "Three")

      seed_pair(account.id, a, b, 1.0, ["email_match"])
      seed_pair(account.id, b, c, 0.85, ["email_match"])

      assert %{merged: 1, skipped: 0, left_behind: 1, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id)

      remaining = active_ids(account.id)
      assert length(remaining) == 2
      assert c.id in remaining
    end

    test "a name-only edge is never strong, even at 1.0: A–B (name+email) merges, C is left behind",
         %{account: account} do
      a = contact(account, "Aaa One", "Aaa", "One")
      b = contact(account, "Bbb Two", "Bbb", "Two")
      c = contact(account, "Ccc Three", "Ccc", "Three")

      # A–B rests on a concrete signal; B–C is name-only at full score and so is
      # never a strong edge — C hangs off the merged component and is dropped.
      seed_pair(account.id, a, b, 1.0, ["name_match", "email_match"])
      seed_pair(account.id, b, c, 1.0, ["name_match"])

      assert %{merged: 1, skipped: 0, left_behind: 1, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id)

      remaining = active_ids(account.id)
      assert length(remaining) == 2
      assert c.id in remaining
    end
  end

  describe "run/2 — safety guard (d): members disagree on birthdate" do
    test "skips a strong edge whose members carry different birthdates", %{account: account} do
      a = contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1980-01-01]})
      b = contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1990-01-01]})
      seed_pair(account.id, a, b, 1.0, ["name_match", "email_match"])

      assert %{merged: 0, skipped: 1} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 2
    end

    test "merges when only one member has a birthdate", %{account: account} do
      a = contact(account, "Ivy Ross", "Ivy", "Ross", %{birthdate: ~D[1980-01-01]})
      b = contact(account, "Ivy Ross", "Ivy", "Ross")
      seed_pair(account.id, a, b, 1.0, ["name_match", "email_match"])

      assert %{merged: 1, skipped: 0} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 1
    end
  end

  describe "run/2 — restrict_ids" do
    test "never touches contacts outside the id set", %{
      account: account,
      email_type_id: email_type_id
    } do
      a = contact(account, "Amy Poe", "Amy", "Poe")
      b = contact(account, "Amy Poe", "Amy", "Poe")
      contact_field_fixture(a, email_type_id, %{"value" => "amy@example.com"})
      contact_field_fixture(b, email_type_id, %{"value" => "amy@example.com"})
      x = contact(account, "Old Timer", "Old", "Timer")
      y = contact(account, "Old Timer", "Old", "Timer")
      contact_field_fixture(x, email_type_id, %{"value" => "old@example.com"})
      contact_field_fixture(y, email_type_id, %{"value" => "old@example.com"})

      assert %{merged: 1, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id, restrict_ids: [a.id, b.id])

      remaining = active_ids(account.id)
      assert length(remaining) == 3
      assert x.id in remaining
      assert y.id in remaining
    end
  end

  describe "run/2 — restrict_ids: []" do
    test "an empty id set skips the detector scan entirely", %{
      account: account,
      email_type_id: email_type_id
    } do
      a = contact(account, "Amy Poe", "Amy", "Poe")
      b = contact(account, "Amy Poe", "Amy", "Poe")
      contact_field_fixture(a, email_type_id, %{"value" => "amy@example.com"})
      contact_field_fixture(b, email_type_id, %{"value" => "amy@example.com"})

      assert %{merged: 0, skipped: 0, left_behind: 0, clusters_merged: 0, errors: []} =
               DuplicateAutomerge.run(account.id, restrict_ids: [])

      # scan_account/1 would have inserted a candidate for the shared email.
      assert Repo.aggregate(DuplicateCandidate, :count) == 0
      assert length(active_ids(account.id)) == 2
    end
  end

  describe "run/2 — left_behind is reconciled against actual merges" do
    test "a birthdate-skipped strong cluster leaves nothing behind", %{account: account} do
      a = contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1980-01-01]})
      b = contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1990-01-01]})
      c = contact(account, "Ccc Three", "Ccc", "Three")

      seed_pair(account.id, a, b, 1.0, ["name_match", "email_match"])
      seed_pair(account.id, b, c, 1.0, ["name_match"])

      assert %{merged: 0, skipped: 1, left_behind: 0} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 3
    end
  end

  describe "run/2 — dry_run" do
    test "reports the merge and writes nothing at all", %{
      account: account,
      email_type_id: email_type_id
    } do
      a = contact(account, "Rae Lin", "Rae", "Lin")
      b = contact(account, "Rae Lin", "Rae", "Lin")
      contact_field_fixture(a, email_type_id, %{"value" => "rae@example.com"})
      contact_field_fixture(b, email_type_id, %{"value" => "rae@example.com"})

      before_candidates = Repo.aggregate(DuplicateCandidate, :count)

      assert %{merged: 1, clusters_merged: 1, left_behind: 0} =
               DuplicateAutomerge.run(account.id, dry_run: true)

      # Nothing merged, and the detector scan the pass runs is rolled back —
      # zero DuplicateCandidate rows persist.
      assert length(active_ids(account.id)) == 2
      assert Repo.aggregate(DuplicateCandidate, :count) == before_candidates

      assert DuplicateCandidate
             |> where([d], d.account_id == ^account.id)
             |> Repo.aggregate(:count) == 0
    end
  end

  describe "run/2 — min_score" do
    test "default 1.0 leaves a sub-1.0 multi-signal cluster alone", %{
      account: account,
      email_type_id: email_type_id
    } do
      a = contact(account, "Sam Bell", "Sam", "Bell")
      b = contact(account, "Sam Bella", "Sam", "Bella")
      contact_field_fixture(a, email_type_id, %{"value" => "sb@example.com"})
      contact_field_fixture(b, email_type_id, %{"value" => "sb@example.com"})

      assert %{merged: 0, skipped: 0, left_behind: 0} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 2

      # Lowering the floor makes the 0.9 edge a strong edge, so the pair merges.
      assert %{merged: 1} = DuplicateAutomerge.run(account.id, min_score: 0.85)
      assert length(active_ids(account.id)) == 1
    end
  end
end
