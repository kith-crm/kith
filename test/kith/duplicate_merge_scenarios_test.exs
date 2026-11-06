defmodule Kith.DuplicateMergeScenariosTest do
  @moduledoc """
  The two end-to-end scenarios design spec §7 asks for as their own tests: the
  handled cluster (F1–F3) and two people in one cluster (F5).

  Every other test in this area covers one step in isolation. These re-run
  `DuplicateDetectionWorker` *after* a real merge, which is the only thing that
  ties F1's "A–D is not recreated" to the merge that dismissed it — without
  them, a change to `resolve_after_merge/4`'s repointing could break F1 with a
  green suite.
  """
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.Factory
  import Kith.ContactsFixtures

  alias Kith.Accounts.Scope
  alias Kith.Contacts
  alias Kith.Contacts.{Contact, DuplicateCandidate, MergeResolution}
  alias Kith.DuplicateDetection
  alias Kith.Workers.DuplicateDetectionWorker

  setup do
    seed_reference_data!()
    {account, user} = setup_account()

    email_type =
      Repo.one!(
        from(t in Kith.Contacts.ContactFieldType, where: t.protocol == "mailto:", limit: 1)
      )

    %{account: account, scope: Scope.for_user(user), email_type: email_type}
  end

  # Shared email is what makes the worker propose the pairs, so a pair that is
  # *not* recreated later is a pair the dismissal actually suppressed.
  defp contact_with_email(ctx, name, email) do
    contact =
      insert(:contact,
        account: ctx.account,
        first_name: name,
        last_name: "Rivera",
        display_name: "#{name} Rivera"
      )

    insert(:contact_field,
      contact: contact,
      account: ctx.account,
      contact_field_type: ctx.email_type,
      value: email
    )

    contact
  end

  defp run_worker(ctx), do: perform_job(DuplicateDetectionWorker, %{account_id: ctx.account.id})

  # Exactly what `ClusterMerge` submits: a resolution over the checked members
  # only, plus the ids the user unchecked.
  defp merge_checked(ctx, survivor, other_checked, unchecked) do
    members = [survivor | other_checked]
    resolution = MergeResolution.resolve(members, survivor.id)

    Contacts.merge_cluster(ctx.scope, survivor.id, Enum.map(other_checked, & &1.id), %{
      fields: resolution.fields,
      drop: %{},
      unchecked_ids: Enum.map(unchecked, & &1.id)
    })
  end

  defp cluster_member_ids(ctx) do
    ctx.account.id
    |> DuplicateDetection.list_clusters()
    |> Enum.map(fn cluster -> cluster.contacts |> Enum.map(& &1.id) |> Enum.sort() end)
  end

  defp pair_status(a, b) do
    {low, high} = if a.id < b.id, do: {a.id, b.id}, else: {b.id, a.id}

    Repo.one(
      from(d in DuplicateCandidate,
        where: d.contact_id == ^low and d.duplicate_contact_id == ^high,
        select: d.status
      )
    )
  end

  # Scores are the clustering input under test here; producing an exact 0.90 /
  # 0.60 out of the worker's signal arithmetic is a different test's job (see
  # `Kith.Workers.DuplicateDetectionWorkerTest`), so E's two edges are written
  # with the scores the scenario names.
  defp pending_pair(ctx, one, two, score) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    insert(:duplicate_candidate,
      account: ctx.account,
      contact: low,
      duplicate_contact: high,
      score: score,
      status: "pending",
      reasons: ["name_match"]
    )
  end

  describe "the handled-cluster scenario (F1–F3)" do
    setup ctx do
      a = contact_with_email(ctx, "Ana", "shared@example.com")
      b = contact_with_email(ctx, "Ana", "shared@example.com")
      c = contact_with_email(ctx, "Ana", "shared@example.com")
      d = contact_with_email(ctx, "Ana", "shared@example.com")

      run_worker(ctx)

      cluster = DuplicateDetection.get_cluster(ctx.account.id, a.id)

      assert Enum.map(cluster.contacts, & &1.id) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id, d.id])

      {:ok, _survivor} = merge_checked(ctx, a, [b, c], [d])

      Map.merge(ctx, %{a: a, b: b, c: c, d: d})
    end

    test "merging A+B+C with D unchecked dismisses A–D and repoints B–D and C–D", ctx do
      assert pair_status(ctx.a, ctx.d) == "dismissed"

      # B–D and C–D were repointed onto the survivor, so their rows are gone by
      # their old keys and every row still touching D names A.
      assert pair_status(ctx.b, ctx.d) == nil
      assert pair_status(ctx.c, ctx.d) == nil

      touching_d =
        Repo.all(
          from(p in DuplicateCandidate,
            where: p.contact_id == ^ctx.d.id or p.duplicate_contact_id == ^ctx.d.id,
            select: {p.contact_id, p.duplicate_contact_id, p.status}
          )
        )

      {low, high} = if ctx.a.id < ctx.d.id, do: {ctx.a.id, ctx.d.id}, else: {ctx.d.id, ctx.a.id}
      assert touching_d == [{low, high, "dismissed"}]
    end

    test "re-running the worker does not recreate A–D or recluster them", ctx do
      run_worker(ctx)

      assert pair_status(ctx.a, ctx.d) == "dismissed"

      refute Enum.any?(cluster_member_ids(ctx), fn ids ->
               ctx.a.id in ids and ctx.d.id in ids
             end)

      # D is a live contact still — it was excluded, not merged.
      assert Repo.get!(Contact, ctx.d.id).deleted_at == nil
    end

    test "a new contact matching A at 0.90 and D at 0.60 clusters as {A, E}", ctx do
      run_worker(ctx)
      e = contact_with_email(ctx, "Elena", "elena@example.com")

      pending_pair(ctx, ctx.a, e, 0.90)
      pending_pair(ctx, ctx.d, e, 0.60)

      assert cluster_member_ids(ctx) == [Enum.sort([ctx.a.id, e.id])]

      # The weaker edge is not consumed, just not allowed to reunite A and D.
      assert pair_status(ctx.d, e) == "pending"
    end

    test "reversing the scores puts E with D instead, and A is excluded", ctx do
      run_worker(ctx)
      e = contact_with_email(ctx, "Elena", "elena@example.com")

      pending_pair(ctx, ctx.a, e, 0.60)
      pending_pair(ctx, ctx.d, e, 0.90)

      assert cluster_member_ids(ctx) == [Enum.sort([ctx.d.id, e.id])]
      assert pair_status(ctx.a, e) == "pending"
    end
  end

  describe "the two-people scenario (F5)" do
    test "D–E survive the merge and derive as their own cluster", ctx do
      a = contact_with_email(ctx, "Ana", "shared@example.com")
      b = contact_with_email(ctx, "Ana", "shared@example.com")
      c = contact_with_email(ctx, "Ana", "shared@example.com")
      d = contact_with_email(ctx, "Ana", "shared@example.com")
      e = contact_with_email(ctx, "Ana", "shared@example.com")

      run_worker(ctx)

      cluster = DuplicateDetection.get_cluster(ctx.account.id, a.id)

      assert Enum.map(cluster.contacts, & &1.id) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id, d.id, e.id])

      {:ok, _survivor} = merge_checked(ctx, a, [b, c], [d, e])

      # Pairs between two unchecked members are left alone (spec F6's rule,
      # exercised here by the merge path).
      assert pair_status(d, e) == "pending"
      assert pair_status(a, d) == "dismissed"
      assert pair_status(a, e) == "dismissed"

      run_worker(ctx)

      assert cluster_member_ids(ctx) == [Enum.sort([d.id, e.id])]

      # And that cluster merges on its own, without ever reclustering with A.
      {:ok, _} = merge_checked(ctx, d, [e], [])

      run_worker(ctx)

      assert cluster_member_ids(ctx) == []
      assert Repo.get!(Contact, e.id).deleted_at != nil
      assert Repo.get!(Contact, d.id).deleted_at == nil
    end
  end
end
