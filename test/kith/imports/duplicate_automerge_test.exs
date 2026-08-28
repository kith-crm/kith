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

  defp seed_pair(account_id, one, two, score, reasons) do
    {low, high} = if one.id < two.id, do: {one.id, two.id}, else: {two.id, one.id}

    Repo.insert!(%DuplicateCandidate{
      account_id: account_id,
      contact_id: low,
      duplicate_contact_id: high,
      score: score,
      reasons: reasons,
      status: "pending",
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

  describe "run/2 — divergence case (a): identical display_name, nothing else shared" do
    test "merges the pair and clears the cluster", %{account: account} do
      a = contact(account, "Nadia Khan", "Nadia", "Khan")
      b = contact(account, "Nadia Khan", "Nadia", "Khan")

      assert %{merged: 1, skipped: 0, clusters_merged: 1, errors: []} =
               DuplicateAutomerge.run(account.id)

      remaining = active_ids(account.id)
      assert length(remaining) == 1
      assert hd(remaining) in [a.id, b.id]
      assert DuplicateDetection.cluster_count(account.id) == 0
    end
  end

  describe "run/2 — divergence case (b): transitive chain via different signals" do
    test "merges all three members", %{account: account, email_type_id: email_type_id} do
      a = contact(account, "Kim Lee", "Kim", "Lee")
      b = contact(account, "Kim Lee", "Kim", "Lee")
      c = contact(account, "Zoe Fox", "Zoe", "Fox")

      # B–C linked only by a shared email; A–C share nothing.
      contact_field_fixture(b, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c, email_type_id, %{"value" => "shared@example.com"})

      assert %{merged: 2, skipped: 0, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id)

      remaining = active_ids(account.id)
      assert length(remaining) == 1
      assert hd(remaining) in [a.id, b.id, c.id]
    end
  end

  describe "run/2 — safety guard (c): a fuzzy name-only pair blocks the cluster" do
    test "skips and logs, merging nothing", %{account: account} do
      a = contact(account, "Dana Park", "Dana", "Park")
      b = contact(account, "Dana Park", "Dana", "Park")
      c = contact(account, "Cara Diaz", "Cara", "Diaz")

      # A deliberate fuzzy (name-only, sim < 1.0) link from A to C. The scan
      # adds the exact A–B match at 1.0, pulling C into the same cluster.
      seed_pair(account.id, a, c, 0.7, ["name_match"])

      assert %{merged: 0, skipped: 1, clusters_merged: 0} =
               DuplicateAutomerge.run(account.id)

      assert active_ids(account.id) == Enum.sort([a.id, b.id, c.id])
    end
  end

  describe "run/2 — safety guard (d): members disagree on birthdate" do
    test "skips", %{account: account} do
      contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1980-01-01]})
      contact(account, "Evan Cole", "Evan", "Cole", %{birthdate: ~D[1990-01-01]})

      assert %{merged: 0, skipped: 1} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 2
    end

    test "merges when only one member has a birthdate", %{account: account} do
      contact(account, "Ivy Ross", "Ivy", "Ross", %{birthdate: ~D[1980-01-01]})
      contact(account, "Ivy Ross", "Ivy", "Ross")

      assert %{merged: 1, skipped: 0} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 1
    end
  end

  describe "run/2 — restrict_ids" do
    test "never touches contacts outside the id set", %{account: account} do
      a = contact(account, "Amy Poe", "Amy", "Poe")
      b = contact(account, "Amy Poe", "Amy", "Poe")
      x = contact(account, "Old Timer", "Old", "Timer")
      y = contact(account, "Old Timer", "Old", "Timer")

      assert %{merged: 1, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id, restrict_ids: [a.id, b.id])

      remaining = active_ids(account.id)
      assert length(remaining) == 3
      assert x.id in remaining
      assert y.id in remaining
    end
  end

  describe "run/2 — dry_run" do
    test "reports the merge without writing", %{account: account} do
      contact(account, "Rae Lin", "Rae", "Lin")
      contact(account, "Rae Lin", "Rae", "Lin")

      before_candidates = Repo.aggregate(DuplicateCandidate, :count)

      assert %{merged: 1, clusters_merged: 1} =
               DuplicateAutomerge.run(account.id, dry_run: true)

      assert length(active_ids(account.id)) == 2

      pending =
        DuplicateCandidate
        |> where([d], d.account_id == ^account.id and d.status == "pending")
        |> Repo.aggregate(:count)

      # scan_account still runs and inserts the candidate; nothing is resolved.
      assert pending == 1
      assert Repo.aggregate(DuplicateCandidate, :count) >= before_candidates
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

      assert %{merged: 0, skipped: 0} = DuplicateAutomerge.run(account.id)
      assert length(active_ids(account.id)) == 2

      # Lowering the bar merges it (email_match keeps it off the fuzzy guard).
      assert %{merged: 1} = DuplicateAutomerge.run(account.id, min_score: 0.85)
      assert length(active_ids(account.id)) == 1
    end
  end
end
