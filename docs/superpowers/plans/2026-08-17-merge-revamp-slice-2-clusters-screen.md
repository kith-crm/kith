# Merge Revamp — Slice 2: Clusters and the Merge Screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the pairwise duplicates queue and the three-step merge wizard with a cluster list and a single-screen cluster merge, built on slice 1's resolver and engine.

**Architecture:** Clusters are derived, not stored — `list_clusters/2` runs a greedy union over pending candidate pairs where dismissed pairs act as negative edges that block a union. A summary module gathers the multi-valued records and history counts the screen shows. The `ClusterMerge` LiveView holds member selection and field overrides in assigns, recomputes resolution on every selection change, and submits a complete resolution to `merge_cluster/4`.

**Tech Stack:** Elixir, Ecto, Phoenix LiveView, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-17-duplicate-merge-revamp-design.md`

**Depends on:** `2026-08-17-merge-revamp-slice-1-engine.md` must be complete and merged. This plan calls `Kith.Contacts.MergeResolution.resolve/2`, `Kith.Contacts.merge_cluster/4` and `Kith.DuplicateDetection.resolve_after_merge/4`.

## Global Constraints

- Account-scoped multitenancy: every query goes through `scope.account.id`.
- Never add `Co-Authored-By` lines to commits.
- Run `mix test` before every commit and ensure 0 failures.
- `mix format` after each task; `.heex` uses the `Phoenix.LiveView.HTMLFormatter` plugin.
- LiveView routes live in the `:require_authenticated_user` live session in `lib/kith_web/router.ex`.
- Authorization uses `Kith.Policy.can?(user, :update, :contact)`. A `viewer` must be refused.
- One deviation from the spec, deliberate and better: §1 states the negative-edge check costs O(|C₁|×|C₂|) per edge. The implementation below checks each dismissed pair against the two groups instead, which is O(|negatives|) per edge.

### Carried over from slice 1 — read before building the drop list

Slice 1's engine landed with a caller contract that only documentation enforces, and this slice is
the first caller that can violate it. Both items were found in slice 1's reviews and deliberately
left for here.

- **A drop list must name EVERY row backing a dropped value.** The engine's `:dedupe_owned` step
  runs before `:apply_drop`. If the survivor and a loser both hold the same contact-field value and
  the user unchecks it, dedupe keeps whichever row has the lower id: if that is the survivor's, the
  drop deletes it and the value is gone (correct); if it is the loser's, the drop's id matches
  nothing and **the excluded value silently comes back**, roughly half the time, depending on row
  ids. See the `## Contract` section of `Kith.Contacts.Merge`'s moduledoc. Reordering the Multi
  steps makes it worse, not better. Two ways out — decide before Task 8: (a) the LiveView expands
  each unchecked value to every member row backing it, or (b) the engine grows value-based dropping
  for the dedupe keys, which is the sturdier fix since it cannot be forgotten by a future caller.
  Option (b) is a slice-1 file change and needs its own test.

- **Never let the user pick a raw Immich field value.** Slice 1 exempted the four Immich columns
  from the engine's held-by-member validation, because the group is resolved as a unit and can
  legitimately synthesise `immich_status: "unlinked"` when no member is linked. That means the
  engine no longer rejects an Immich value no member holds: a bogus `immich_status` would sail past
  validation and hit the bare DB CHECK `contacts_immich_status_values`, raising a `Postgrex.Error`
  that escapes the error contract entirely (there is no `validate_inclusion` for it on
  `Contact.update_changeset/2`). The §4 Immich row must therefore submit a chosen MEMBER, with the
  LiveView copying that member's whole four-field group — never free-form field values.

- **Do not offer a member's id as a `first_met_through_id` value.** The engine now enforces spec D4
  by silently coercing a `first_met_through_id` that names any merged member to `:clear`. If the
  Identity section's segmented control lists the loser as a candidate value, the user can click it,
  the merge will succeed, and the field will come back empty with no explanation. Filter member ids
  out of that row's options (and out of its attribution), or render the row as "cleared — a contact
  cannot be met through a record it just absorbed".

- **`Kith.Accounts.Scope.system_for_account_id/1` is not an authorization scope.** It fabricates a
  full-privilege scope with `user: nil` for the legacy two-contact shim. Do not use it in this
  slice: the cluster screen has a real `current_scope`, and passing a userless scope would also
  silently skip the engine's audit entry.

## File Structure

| File | Responsibility |
|---|---|
| `lib/kith/duplicate_detection/cluster.ex` (create) | The derived cluster struct. Data only. |
| `lib/kith/duplicate_detection.ex` (modify) | `list_clusters/2`, `get_cluster/2`, `cluster_count/1`, `default_primary/1`, `dismiss_selection/3`. |
| `lib/kith/contacts/merge_summary.ex` (create) | Multi-valued records and history counts for a member set. Read-only. |
| `lib/kith/contacts/merge_resolution.ex` (modify) | Adds `candidates_for/2` so the UI can open any field as a choice. |
| `lib/kith_web/live/contact_live/cluster_merge.ex` (create) | The merge screen. |
| `lib/kith_web/live/contact_live/index.ex` (modify) | `:duplicates` action lists clusters. |
| `lib/kith_web/live/contact_live/index.html.heex:378-478` (modify) | Cluster rows replace pair cards. |
| `lib/kith_web/router.ex` (modify) | Adds the cluster route. |

---

### Task 1: Cluster derivation

**Files:**
- Create: `lib/kith/duplicate_detection/cluster.ex`
- Modify: `lib/kith/duplicate_detection.ex`
- Test: `test/kith/duplicate_detection_test.exs`

**Interfaces:**
- Produces: `%Kith.DuplicateDetection.Cluster{key: integer, contacts: [Contact.t()], pairs: [DuplicateCandidate.t()], max_score: float, reasons: [String.t()]}` and `DuplicateDetection.list_clusters(account_id, opts)` returning a list of clusters ordered by `max_score` descending, then `key` ascending. `opts` accepts `:limit` (default 20) and `:offset` (default 0).

- [ ] **Step 1: Write the failing test**

Append to `test/kith/duplicate_detection_test.exs`:

```elixir
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
      candidate!(ctx.account_id, a, b, score: 0.85)
      candidate!(ctx.account_id, b, c, score: 0.85)

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
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/duplicate_detection_test.exs -k "list_clusters"`
Expected: FAIL with `function Kith.DuplicateDetection.list_clusters/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith/duplicate_detection/cluster.ex`:

```elixir
defmodule Kith.DuplicateDetection.Cluster do
  @moduledoc """
  A derived group of contacts that detection believes are the same person.

  Clusters have no database row — they are computed from `duplicate_candidates`
  on every read, so they cannot drift from the pairs that justify them. `key` is
  the lowest member contact id and is used for routing.
  """

  defstruct [:key, :contacts, :pairs, :max_score, :reasons]

  @type t :: %__MODULE__{
          key: integer(),
          contacts: [Kith.Contacts.Contact.t()],
          pairs: [Kith.Contacts.DuplicateCandidate.t()],
          max_score: float(),
          reasons: [String.t()]
        }
end
```

Append to `lib/kith/duplicate_detection.ex` (and add
`alias Kith.DuplicateDetection.Cluster` plus `alias Kith.Contacts.Contact` at the
top):

```elixir
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/duplicate_detection_test.exs`
Expected: PASS, 9 new tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/duplicate_detection/cluster.ex lib/kith/duplicate_detection.ex test/kith/duplicate_detection_test.exs
git commit -m "feat(duplicates): derive clusters with dismissed pairs as negative edges"
```

---

### Task 2: Cluster lookup, trashed filtering, primary and selection dismissal

**Files:**
- Modify: `lib/kith/duplicate_detection.ex`
- Test: `test/kith/duplicate_detection_test.exs`

**Interfaces:**
- Produces:
  - `get_cluster(account_id, contact_id)` → `%Cluster{}` or `nil`. Accepts **any** member id, not only the key.
  - `default_primary(contacts)` → `%Contact{}`, the member with the most attached records, tie-broken by earliest `inserted_at`.
  - `dismiss_selection(account_id, selected_ids, unchecked_ids)` → `:ok`. Writes the full clique over `selected_ids` as `dismissed`, plus every selected↔unchecked pair; leaves unchecked↔unchecked alone.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/duplicate_detection_test.exs`:

```elixir
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
      assert status_of(ctx.account_id, d, e) == "pending"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/duplicate_detection_test.exs -k "get_cluster"`
Expected: FAIL with `function Kith.DuplicateDetection.get_cluster/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/duplicate_detection.ex`, filter trashed members inside
`build_clusters/1`. Replace the `candidates` binding with:

```elixir
    candidates =
      DuplicateCandidate
      |> scope_to_account(account_id)
      |> where([d], d.status in ["pending", "dismissed"])
      |> join(:inner, [d], one in Contact, on: one.id == d.contact_id)
      |> join(:inner, [d, _one], two in Contact, on: two.id == d.duplicate_contact_id)
      |> where([d, one, two], is_nil(one.deleted_at) and is_nil(two.deleted_at))
      |> select([d], d)
      |> Repo.all()
```

Then add these functions:

```elixir
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
  records, tie-broken by earliest creation.

  Moving the fewest rows is the cheap part; the real reason is that the richest,
  oldest record is the id external clients (CardDAV, Immich) are already pinned
  to.
  """
  def default_primary(contacts) do
    ids = Enum.map(contacts, & &1.id)
    counts = attached_counts(ids)

    Enum.max_by(contacts, fn contact ->
      {Map.get(counts, contact.id, 0), -DateTime.to_unix(contact.inserted_at)}
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
  """
  def dismiss_selection(account_id, selected_ids, unchecked_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cliques =
      for one <- selected_ids, two <- selected_ids, one < two, do: {one, two}

    crosses =
      for one <- selected_ids, two <- unchecked_ids, one != two do
        if one < two, do: {one, two}, else: {two, one}
      end

    (cliques ++ crosses)
    |> Enum.uniq()
    |> Enum.each(fn {low, high} -> upsert_dismissed(account_id, low, high, now) end)

    :ok
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
        |> Repo.insert!()

      %DuplicateCandidate{status: "merged"} = existing ->
        existing

      existing ->
        existing |> DuplicateCandidate.dismiss_changeset() |> Repo.update!()
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/duplicate_detection_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/duplicate_detection.ex test/kith/duplicate_detection_test.exs
git commit -m "feat(duplicates): add cluster lookup, primary selection and clique dismissal"
```

---

### Task 3: Merge summary — multi-valued records and history counts

**Files:**
- Create: `lib/kith/contacts/merge_summary.ex`
- Test: `test/kith/contacts/merge_summary_test.exs`

**Interfaces:**
- Produces: `MergeSummary.build(members)` returning
  `%{contact_fields: [entry], addresses: [entry], tags: [entry], aliases: [entry], history: %{atom => integer}}`
  where `entry` is `%{id: term, label: String.t(), value: String.t(), owner_id: integer, duplicate?: boolean}`.
  For tags, `id` is the tag id. For aliases, `id` is the string itself.

- [ ] **Step 1: Write the failing test**

Create `test/kith/contacts/merge_summary_test.exs`:

```elixir
defmodule Kith.Contacts.MergeSummaryTest do
  use Kith.DataCase, async: false

  import Ecto.Query

  alias Kith.Contacts.MergeSummary
  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()

    email_type =
      Repo.one!(
        from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
      )

    a = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Sarah"})
    b = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Sarah"})

    %{user: user, account_id: user.account_id, email_type: email_type, a: a, b: b}
  end

  test "combines contact fields and marks the repeat as a duplicate", ctx do
    ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{value: "s@example.com"})
    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{value: "s@example.com"})
    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{value: "other@example.com"})

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert length(summary.contact_fields) == 3
    assert Enum.count(summary.contact_fields, & &1.duplicate?) == 1

    kept = Enum.reject(summary.contact_fields, & &1.duplicate?)
    assert Enum.sort(Enum.map(kept, & &1.value)) == ["other@example.com", "s@example.com"]
  end

  test "the first occurrence is kept and the later one marked duplicate", ctx do
    first = ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{value: "s@example.com"})
    second = ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{value: "s@example.com"})

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.find(summary.contact_fields, &(&1.id == first.id)).duplicate? == false
    assert Enum.find(summary.contact_fields, &(&1.id == second.id)).duplicate? == true
  end

  test "addresses dedupe on line1 and postal code", ctx do
    ContactsFixtures.address_fixture(ctx.a, %{line1: "1 Main St", postal_code: "94110"})
    ContactsFixtures.address_fixture(ctx.b, %{line1: "  1 main st ", postal_code: "94110"})

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.count(summary.addresses, & &1.duplicate?) == 1
  end

  test "aliases are unioned across members", ctx do
    Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
      set: [aliases: ["Sarah K."]]
    )

    Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
      set: [aliases: ["Sarah K.", "SK"]]
    )

    a = Repo.get!(Kith.Contacts.Contact, ctx.a.id)
    b = Repo.get!(Kith.Contacts.Contact, ctx.b.id)

    summary = MergeSummary.build([a, b])

    assert Enum.map(summary.aliases, & &1.value) |> Enum.sort() == ["SK", "Sarah K."]
  end

  test "history counts every type across every member", ctx do
    ContactsFixtures.note_fixture(ctx.a, ctx.user.id)
    ContactsFixtures.note_fixture(ctx.b, ctx.user.id)
    ContactsFixtures.document_fixture(ctx.b)

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert summary.history.notes == 2
    assert summary.history.documents == 1
    assert summary.history.calls == 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts/merge_summary_test.exs`
Expected: FAIL with `module Kith.Contacts.MergeSummary is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith/contacts/merge_summary.ex`:

```elixir
defmodule Kith.Contacts.MergeSummary do
  @moduledoc """
  Gathers the multi-valued records and history counts a merge screen shows.

  Read-only. Duplicates are marked rather than removed so the screen can show
  what the merge will collapse instead of silently dropping it.
  """

  import Ecto.Query, warn: false

  alias Kith.Contacts.{Address, ContactField, Contact, Document, Note, Photo}
  alias Kith.Repo

  @history [
    notes: Note,
    documents: Document,
    photos: Photo,
    calls: Kith.Activities.Call,
    life_events: Kith.Activities.LifeEvent,
    reminders: Kith.Reminders.Reminder,
    gifts: Kith.Contacts.Gift,
    debts: Kith.Contacts.Debt,
    pets: Kith.Contacts.Pet,
    tasks: Kith.Tasks.Task,
    conversations: Kith.Conversations.Conversation,
    relationships: Kith.Contacts.Relationship
  ]

  @doc "Builds the summary for `members`."
  def build(members) do
    ids = Enum.map(members, & &1.id)

    %{
      contact_fields: contact_fields(ids),
      addresses: addresses(ids),
      tags: tags(ids),
      aliases: aliases(members),
      history: history(ids)
    }
  end

  defp contact_fields(ids) do
    from(f in ContactField,
      where: f.contact_id in ^ids,
      join: t in assoc(f, :contact_field_type),
      order_by: [asc: f.id],
      select: {f, t.label}
    )
    |> Repo.all()
    |> Enum.map(fn {field, label} ->
      %{
        id: field.id,
        label: label,
        value: field.value,
        owner_id: field.contact_id,
        key: {field.contact_field_type_id, normalize(field.value)}
      }
    end)
    |> mark_duplicates()
  end

  defp addresses(ids) do
    from(a in Address, where: a.contact_id in ^ids, order_by: [asc: a.id])
    |> Repo.all()
    |> Enum.map(fn address ->
      %{
        id: address.id,
        label: address.label || "Address",
        value: Enum.join(Enum.reject([address.line1, address.city], &is_nil/1), ", "),
        owner_id: address.contact_id,
        key: {normalize(address.line1), normalize(address.postal_code)}
      }
    end)
    |> mark_duplicates()
  end

  defp tags(ids) do
    from(ct in "contact_tags",
      join: t in Kith.Contacts.Tag,
      on: t.id == ct.tag_id,
      where: ct.contact_id in ^ids,
      order_by: [asc: t.name],
      select: {ct.contact_id, t.id, t.name}
    )
    |> Repo.all()
    |> Enum.map(fn {owner_id, tag_id, name} ->
      %{id: tag_id, label: "Tag", value: name, owner_id: owner_id, key: tag_id}
    end)
    |> mark_duplicates()
  end

  defp aliases(members) do
    members
    |> Enum.flat_map(fn member ->
      Enum.map(member.aliases || [], &%{
        id: &1,
        label: "Alias",
        value: &1,
        owner_id: member.id,
        key: &1
      })
    end)
    |> mark_duplicates()
  end

  defp history(ids) do
    counts =
      Map.new(@history, fn {key, schema} ->
        {key, Repo.aggregate(from(r in schema, where: r.contact_id in ^ids), :count)}
      end)

    activities =
      from(ac in "activity_contacts", where: ac.contact_id in ^ids, select: count())
      |> Repo.one()

    Map.put(counts, :activities, activities)
  end

  # The first occurrence of a key wins; later ones are what the merge collapses.
  defp mark_duplicates(entries) do
    {marked, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn entry, seen ->
        duplicate? = MapSet.member?(seen, entry.key)
        {entry |> Map.put(:duplicate?, duplicate?) |> Map.delete(:key),
         MapSet.put(seen, entry.key)}
      end)

    marked
  end

  defp normalize(nil), do: nil
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end
```

If `Kith.Contacts.Address` has no `label` field, drop the `address.label ||`
fallback and use `"Address"` directly — check the schema before writing.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts/merge_summary_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge_summary.ex test/kith/contacts/merge_summary_test.exs
git commit -m "feat(contacts): summarise multi-valued records and history for a merge"
```

---

### Task 4: Candidate values for any field

**Files:**
- Modify: `lib/kith/contacts/merge_resolution.ex`
- Test: `test/kith/contacts/merge_resolution_test.exs`

**Interfaces:**
- Produces: `MergeResolution.candidates_for(members, field)` returning
  `[%{value: term, member_ids: [integer], count: integer}]` for **any** choice field, including one where every member agrees. This is what lets the screen open a resolved row as a choice.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts/merge_resolution_test.exs`:

```elixir
  describe "candidates_for/2" do
    test "a resolved field still offers its single value", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah"})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      assert [%{value: "Sarah", count: 2}] =
               MergeResolution.candidates_for([a, b], :first_name)
    end

    test "an empty field offers nothing", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", occupation: nil})
      b = contact(ctx.account_id, %{first_name: "Sarah", occupation: nil})

      assert MergeResolution.candidates_for([a, b], :occupation) == []
    end

    test "a contested field offers every value, most-held first", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})
      b = contact(ctx.account_id, %{first_name: "Sarah", company: "Stripe"})
      c = contact(ctx.account_id, %{first_name: "Sarah", company: "Stripe"})

      assert [%{value: "Stripe", count: 2}, %{value: "Figma", count: 1}] =
               MergeResolution.candidates_for([a, b, c], :company)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts/merge_resolution_test.exs -k "candidates_for"`
Expected: FAIL with `function Kith.Contacts.MergeResolution.candidates_for/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/kith/contacts/merge_resolution.ex`:

```elixir
  @doc """
  Every distinct value `members` hold for `field`, most-held first.

  Unlike `conflicts`, this is populated even when the members agree — the screen
  uses it to open an already-resolved row as a choice.
  """
  def candidates_for(members, field) do
    members
    |> Enum.map(fn member -> {member.id, normalize(Map.fetch!(member, field))} end)
    |> Enum.reject(fn {_id, value} -> is_nil(value) end)
    |> candidates()
    |> Enum.sort_by(& &1.count, :desc)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts/merge_resolution_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge_resolution.ex test/kith/contacts/merge_resolution_test.exs
git commit -m "feat(contacts): expose candidate values for any mergeable field"
```

---

### Task 5: Duplicates index lists clusters

**Files:**
- Modify: `lib/kith_web/live/contact_live/index.ex:60-71,255-280`
- Modify: `lib/kith_web/live/contact_live/index.html.heex:378-478`
- Test: `test/kith_web/live/contact_live/duplicates_index_test.exs` (create)

**Interfaces:**
- Consumes: `DuplicateDetection.list_clusters/2`, `cluster_count/1`.
- Produces: the `:duplicates` action assigns `:clusters` (list of `%Cluster{}`), `:clusters_total`, `:clusters_has_more`. The old `:candidates`, `:duplicates_total`, `:duplicates_has_more` assigns and the `dismiss` / `load_more_duplicates` handlers are removed.

- [ ] **Step 1: Write the failing test**

Create `test/kith_web/live/contact_live/duplicates_index_test.exs`:

```elixir
defmodule KithWeb.ContactLive.DuplicatesIndexTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user, account_id: user.account_id}
  end

  defp candidate!(account_id, one, two, score \\ 0.9) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: score,
      reasons: ["email_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    })
  end

  test "four duplicates render as one cluster entry", ctx do
    [a, b, c, d] =
      for name <- ~w(Ann Bea Cal Dee) do
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: name})
      end

    candidate!(ctx.account_id, a, b)
    candidate!(ctx.account_id, b, c)
    candidate!(ctx.account_id, c, d)

    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "1 possible duplicate"
    assert html =~ "4 contacts"

    for name <- ~w(Ann Bea Cal Dee), do: assert(html =~ name)
  end

  test "each cluster links to its cluster screen", ctx do
    a = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Ann"})
    b = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Bea"})
    candidate!(ctx.account_id, a, b)

    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "/contacts/duplicates/cluster/#{min(a.id, b.id)}"
  end

  test "shows the empty state when nothing is pending", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "No duplicates found"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/duplicates_index_test.exs`
Expected: FAIL — the page renders pair cards, so `4 contacts` is absent.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith_web/live/contact_live/index.ex`, replace the `apply_action` clause
for `:duplicates` (line 62) with:

```elixir
  defp apply_action(socket, :duplicates, _params) do
    account_id = socket.assigns.current_scope.account.id
    clusters = DuplicateDetection.list_clusters(account_id, limit: @duplicates_page_size)
    total = DuplicateDetection.cluster_count(account_id)

    socket
    |> assign(:page_title, "Duplicate Contacts")
    |> assign(:clusters, clusters)
    |> assign(:clusters_total, total)
    |> assign(:clusters_has_more, length(clusters) >= @duplicates_page_size)
  end
```

Replace the `mount/3` assigns `:duplicates_total` and `:duplicates_has_more`
(lines 36–37) with:

```elixir
     |> assign(:clusters, [])
     |> assign(:clusters_total, 0)
     |> assign(:clusters_has_more, false)
```

Delete the `dismiss` handler (around line 255) and replace the
`load_more_duplicates` handler (line 267) with:

```elixir
  def handle_event("load_more_duplicates", _params, socket) do
    account_id = socket.assigns.current_scope.account.id

    more =
      DuplicateDetection.list_clusters(account_id,
        limit: @duplicates_page_size,
        offset: length(socket.assigns.clusters)
      )

    {:noreply,
     socket
     |> assign(:clusters, socket.assigns.clusters ++ more)
     |> assign(:clusters_has_more, length(more) >= @duplicates_page_size)}
  end
```

In `lib/kith_web/live/contact_live/index.html.heex`, replace lines 378–478 (the
whole duplicates panel) with:

```heex
    <%!-- Duplicates panel --%>
    <%= if @live_action == :duplicates do %>
      <div class="flex items-center justify-between">
        <p class="text-sm text-[var(--color-text-secondary)]">
          {@clusters_total} possible duplicate{if @clusters_total != 1, do: "s"} found
        </p>
        <button
          phx-click="scan"
          class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
        >
          <.icon name="hero-magnifying-glass" class="size-4" /> Scan Now
        </button>
      </div>

      <%= if @clusters == [] do %>
        <KithUI.empty_state
          icon="hero-check-circle"
          title="No duplicates found"
          message="Your contacts look clean! Run a scan to check for potential duplicates."
        />
      <% else %>
        <div class="space-y-4">
          <.link
            :for={cluster <- @clusters}
            navigate={~p"/contacts/duplicates/cluster/#{cluster.key}"}
            class="block rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm p-4 hover:border-[var(--color-border-focus)] transition-colors"
          >
            <div class="flex items-center justify-between mb-3">
              <div class="flex items-center gap-2">
                <span class="inline-flex items-center rounded-full bg-[var(--color-accent-subtle)] text-[var(--color-accent)] px-2 py-0.5 text-xs font-medium">
                  {round(cluster.max_score * 100)}% match
                </span>
                <span class="text-xs text-[var(--color-text-tertiary)]">
                  {Enum.join(cluster.reasons, ", ")}
                </span>
              </div>
              <span class="text-sm font-medium text-[var(--color-text-secondary)]">
                {length(cluster.contacts)} contacts
              </span>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <span
                :for={contact <- cluster.contacts}
                class="inline-flex items-center gap-2 rounded-full border border-[var(--color-border-subtle)] ps-1 pe-3 py-1"
              >
                <KithUI.avatar name={contact.display_name} src={avatar_url(contact)} size={:sm} />
                <span class="text-sm text-[var(--color-text-primary)]">
                  {contact.display_name}
                </span>
              </span>
            </div>
          </.link>

          <div :if={@clusters_has_more} class="flex justify-center pt-2 pb-4">
            <button
              phx-click="load_more_duplicates"
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-4 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] border border-[var(--color-border)] transition-colors cursor-pointer"
            >
              Load more
            </button>
          </div>
        </div>
      <% end %>
    <% end %>
```

The nav badge in `user_auth.ex:233` keeps using `pending_count/1` (pairs). Leave
it — a badge counting pairs while the page counts clusters is confusing, so
change that call to `DuplicateDetection.cluster_count(account_id)` in the same
edit.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/duplicates_index_test.exs`
Expected: PASS, 3 tests. The route does not exist yet, so the link assertion
checks the string only — `~p` will raise if the route is missing, so add the
route now (Task 8 wires the LiveView; adding the route early is fine):

In `lib/kith_web/router.ex`, inside the `:require_authenticated_user` live
session, below the `/contacts/duplicates` line:

```elixir
      live "/contacts/duplicates/cluster/:id", ContactLive.ClusterMerge, :show
```

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/index.ex lib/kith_web/live/contact_live/index.html.heex lib/kith_web/router.ex lib/kith_web/user_auth.ex test/kith_web/live/contact_live/duplicates_index_test.exs
git commit -m "feat(duplicates): list clusters instead of pairs"
```

---

### Task 6: Cluster merge screen — rendering

**Files:**
- Create: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Consumes: `DuplicateDetection.get_cluster/2`, `default_primary/1`, `MergeResolution.resolve/2`, `candidates_for/2`, `MergeSummary.build/1`, `MergeFields`.
- Produces: `KithWeb.ContactLive.ClusterMerge` at `/contacts/duplicates/cluster/:id`. Assigns: `:cluster`, `:members`, `:selected_ids` (MapSet), `:primary_id`, `:overrides` (map), `:resolution`, `:summary`, `:dropped` (MapSet of `{type, id}`), `:error`.

- [ ] **Step 1: Write the failing test**

Create `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
defmodule KithWeb.ContactLive.ClusterMergeTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    account_id = user.account_id

    a =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Sarah",
        last_name: "Kim",
        company: "Figma"
      })

    b =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Sarah",
        last_name: "Kim",
        company: "Stripe",
        middle_name: "Jiyoung"
      })

    candidate!(account_id, a, b)

    %{conn: log_in_user(conn, user), user: user, account_id: account_id, a: a, b: b}
  end

  defp candidate!(account_id, one, two) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: 0.9,
      reasons: ["email_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    })
  end

  defp cluster_path(a, b), do: "/contacts/duplicates/cluster/#{min(a.id, b.id)}"

  test "renders every member with a checkbox", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Merge 2 contacts"
    assert html =~ ~s(phx-value-id="#{ctx.a.id}")
    assert html =~ ~s(phx-value-id="#{ctx.b.id}")
  end

  test "renders an agreed field with its attribution and no choice", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "all 2 agree"
    assert html =~ "Sarah"
  end

  test "renders a gap-filled field attributed to its only source", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Jiyoung"
    assert html =~ "only"
  end

  test "renders a contested field as a choice and flags the section", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Figma"
    assert html =~ "Stripe"
    assert html =~ "1 needs a decision"
  end

  test "a section with a conflict is open, one without is folded", ctx do
    {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert has_element?(live, "details#section-identity[open]")
    refute has_element?(live, "details#section-contact-details[open]")
  end

  test "required fields offer no Leave empty option", ctx do
    {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    refute has_element?(live, "button[phx-value-field='first_name'][phx-value-index='clear']")
  end

  test "an unknown contact id renders not found", ctx do
    assert {:error, {:live_redirect, %{to: "/contacts"}}} =
             live(ctx.conn, "/contacts/duplicates/cluster/0")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: FAIL — `KithWeb.ContactLive.ClusterMerge` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith_web/live/contact_live/cluster_merge.ex`:

```elixir
defmodule KithWeb.ContactLive.ClusterMerge do
  @moduledoc """
  Reviews and merges a cluster of duplicate contacts on one screen.

  All state is derived from the member selection: unchecking a member re-runs
  `MergeResolution` over the remaining members and discards any explicit field
  choices, so what is on screen is always a resolution of exactly the checked
  set.
  """

  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.{MergeFields, MergeResolution, MergeSummary}
  alias Kith.DuplicateDetection
  alias Kith.Policy

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :error, nil)}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    scope = socket.assigns.current_scope

    cond do
      not Policy.can?(scope.user, :update, :contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to merge contacts")
         |> push_navigate(to: ~p"/contacts")}

      cluster = DuplicateDetection.get_cluster(scope.account.id, String.to_integer(id)) ->
        {:noreply, load_cluster(socket, cluster)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "No duplicate cluster found for that contact")
         |> push_navigate(to: ~p"/contacts")}
    end
  end

  defp load_cluster(socket, cluster) do
    members = cluster.contacts
    primary = DuplicateDetection.default_primary(members)

    socket
    |> assign(:page_title, "Merge duplicates")
    |> assign(:cluster, cluster)
    |> assign(:members, members)
    |> assign(:selected_ids, MapSet.new(members, & &1.id))
    |> assign(:primary_id, primary.id)
    |> assign(:overrides, %{})
    |> assign(:dropped, MapSet.new())
    |> assign(:error, nil)
    |> recompute()
  end

  # Everything downstream of the selection is derived, never patched in place.
  defp recompute(socket) do
    selected = selected_members(socket)
    primary_id = ensure_primary(socket, selected)

    socket
    |> assign(:primary_id, primary_id)
    |> assign(:resolution, MergeResolution.resolve(selected, primary_id))
    |> assign(:summary, MergeSummary.build(selected))
  end

  defp selected_members(socket) do
    Enum.filter(socket.assigns.members, &MapSet.member?(socket.assigns.selected_ids, &1.id))
  end

  defp ensure_primary(socket, selected) do
    if Enum.any?(selected, &(&1.id == socket.assigns.primary_id)) do
      socket.assigns.primary_id
    else
      case selected do
        [] -> nil
        members -> DuplicateDetection.default_primary(members).id
      end
    end
  end

  # ── Rendering helpers ──────────────────────────────────────────────────

  defp effective(assigns, field) do
    Map.get(assigns.overrides, field, Map.get(assigns.resolution.fields, field))
  end

  defp conflict?(assigns, field), do: Map.has_key?(assigns.resolution.conflicts, field)

  defp conflict_count(assigns) do
    Enum.count(MergeFields.choice_fields(), &conflict?(assigns, &1))
  end

  defp candidates(assigns, field) do
    MergeResolution.candidates_for(selected_from_assigns(assigns), field)
  end

  defp selected_from_assigns(assigns) do
    Enum.filter(assigns.members, &MapSet.member?(assigns.selected_ids, &1.id))
  end

  defp attribution_text(assigns, field) do
    total = MapSet.size(assigns.selected_ids)

    case Map.get(assigns.resolution.attributions, field) do
      :all_agree -> "all #{total} agree"
      {:only, id} -> "only #{member_name(assigns, id)} has this"
      {:some, n} -> "#{n} of #{total}"
      _ -> nil
    end
  end

  defp member_name(assigns, id) do
    case Enum.find(assigns.members, &(&1.id == id)) do
      nil -> "unknown"
      contact -> contact.display_name
    end
  end

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_id", "") |> String.replace("_", " ")
  end

  defp display(nil), do: nil
  defp display(:clear), do: nil
  defp display(%Date{} = date), do: Date.to_iso8601(date)
  defp display(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp display(true), do: "Yes"
  defp display(false), do: "No"
  defp display(list) when is_list(list), do: Enum.join(list, ", ")
  defp display(value), do: to_string(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="max-w-4xl mx-auto space-y-4">
        <div :if={@error} class="rounded-[var(--radius-md)] border-s-4 border-[var(--color-danger)] bg-[var(--color-danger-subtle)] p-3 text-sm">
          {@error}
          <.link navigate={~p"/contacts/duplicates/cluster/#{@cluster.key}"} class="underline ms-2">
            Reload
          </.link>
        </div>

        <UI.card>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <p class="font-semibold text-[var(--color-text-primary)]">
                {length(@members)} possible duplicates · {MapSet.size(@selected_ids)} selected
              </p>
              <p class="text-sm text-[var(--color-text-tertiary)]">
                Matched on {Enum.join(@cluster.reasons, ", ")}. Uncheck anyone who isn't this person.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap gap-2 mt-4">
            <label
              :for={member <- @members}
              class={[
                "flex items-center gap-2 rounded-full border ps-2 pe-3 py-1.5 cursor-pointer transition-colors",
                if(member.id == @primary_id,
                  do: "border-[var(--color-accent)] bg-[var(--color-accent-subtle)]",
                  else: "border-[var(--color-border)]"
                ),
                not MapSet.member?(@selected_ids, member.id) && "opacity-50"
              ]}
            >
              <input
                type="checkbox"
                checked={MapSet.member?(@selected_ids, member.id)}
                phx-click="toggle-member"
                phx-value-id={member.id}
              />
              <KithUI.avatar name={member.display_name} src={avatar_url(member)} size={:sm} />
              <span class="text-sm">
                {member.display_name}
                <span :if={member.id == @primary_id} class="text-xs text-[var(--color-accent)] ms-1">
                  primary
                </span>
              </span>
              <button
                :if={member.id != @primary_id && MapSet.member?(@selected_ids, member.id)}
                type="button"
                phx-click="set-primary"
                phx-value-id={member.id}
                class="text-xs text-[var(--color-text-tertiary)] hover:text-[var(--color-accent)]"
              >
                make primary
              </button>
            </span>
            </label>
          </div>
        </UI.card>

        <details id="section-identity" open={conflict_count(assigns) > 0} class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]">
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Identity</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {length(MergeFields.choice_fields())} fields · click any value to change it
              </span>
              <span
                :if={conflict_count(assigns) > 0}
                class="rounded-full bg-[var(--color-danger-subtle)] text-[var(--color-danger)] px-2 py-0.5 text-xs font-medium"
              >
                {conflict_count(assigns)} need{if conflict_count(assigns) == 1, do: "s"} a decision
              </span>
            </span>
          </summary>

          <div
            :for={field <- MergeFields.choice_fields()}
            class={[
              "grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]",
              conflict?(assigns, field) && "bg-[var(--color-danger-subtle)]"
            ]}
          >
            <div class="text-sm text-[var(--color-text-secondary)] capitalize">
              {humanize(field)}
            </div>

            <div :if={conflict?(assigns, field)} class="flex flex-wrap items-center gap-2">
              <button
                :for={{candidate, index} <- Enum.with_index(candidates(assigns, field))}
                type="button"
                phx-click="choose-field"
                phx-value-field={field}
                phx-value-index={index}
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm text-start",
                  if(effective(assigns, field) == candidate.value,
                    do: "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                {display(candidate.value)}
                <span class="block text-[10px] opacity-70">{candidate.count} record(s)</span>
              </button>
            </div>

            <div :if={not conflict?(assigns, field)} class="flex items-center gap-3 text-sm">
              <span :if={display(effective(assigns, field))}>
                {display(effective(assigns, field))}
              </span>
              <span
                :if={is_nil(display(effective(assigns, field)))}
                class="italic text-[var(--color-text-disabled)]"
              >
                Not set on any contact
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {attribution_text(assigns, field)}
              </span>
            </div>
          </div>
        </details>

        <details id="section-contact-details" class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]">
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Contact details</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {length(@summary.contact_fields)} fields, {length(@summary.addresses)} addresses,
                {length(@summary.tags)} tags combined
              </span>
            </span>
          </summary>

          <div :for={{label, entries} <- [{"Fields", @summary.contact_fields}, {"Addresses", @summary.addresses}, {"Tags", @summary.tags}, {"Aliases", @summary.aliases}]}
               class="px-4 py-3 border-t border-[var(--color-border-subtle)]">
            <p class="text-sm text-[var(--color-text-secondary)] mb-2">{label}</p>
            <label :for={entry <- entries} class="flex items-center gap-2 text-sm py-0.5">
              <input
                type="checkbox"
                disabled={entry.duplicate?}
                checked={not entry.duplicate? and not MapSet.member?(@dropped, {label, entry.id})}
                phx-click="toggle-value"
                phx-value-type={label}
                phx-value-id={entry.id}
              />
              <span class={entry.duplicate? && "line-through text-[var(--color-text-disabled)]"}>
                {entry.value}
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {if entry.duplicate?, do: "duplicate · dropped", else: member_name(assigns, entry.owner_id)}
              </span>
            </label>
            <p :if={entries == []} class="text-sm text-[var(--color-text-disabled)] italic">None</p>
          </div>
        </details>

        <details id="section-history" class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]">
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Carried over as-is</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {@summary.history |> Map.values() |> Enum.sum()} records move to the primary
              </span>
            </span>
          </summary>
          <div class="flex flex-wrap gap-2 p-4 border-t border-[var(--color-border-subtle)]">
            <span
              :for={{key, count} <- Enum.sort_by(@summary.history, &elem(&1, 0))}
              :if={count > 0}
              class="rounded-[var(--radius-sm)] border border-[var(--color-border-subtle)] bg-[var(--color-surface-sunken)] px-2.5 py-1 text-xs"
            >
              <strong>{count}</strong> {String.replace(to_string(key), "_", " ")}
            </span>
          </div>
        </details>

        <UI.card>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <p class="text-sm text-[var(--color-text-tertiary)] max-w-md">
              {MapSet.size(@selected_ids) - 1} contact(s) move to trash and stay recoverable for 30 days.
              <span :if={MapSet.size(@selected_ids) < length(@members)}>
                Unchecked contacts will be marked as not duplicates and won't be suggested again.
              </span>
            </p>
            <div class="flex gap-2">
              <UI.button variant="secondary" phx-click="not-duplicates">Not duplicates</UI.button>
              <UI.button phx-click="merge" disabled={MapSet.size(@selected_ids) < 2}>
                Merge {MapSet.size(@selected_ids)} contacts
              </UI.button>
            </div>
          </div>
        </UI.card>
      </div>
    </Layouts.app>
    """
  end
end
```

Remove the stray `</span>` before `</label>` in the member strip if the compiler
flags it — the label wraps checkbox, avatar, name and the make-primary button.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: FAIL on the event tests only (Task 7 adds handlers); the rendering
tests pass. Add `@impl true def handle_event(_, _, socket), do: {:noreply, socket}`
temporarily if LiveView raises on the missing callback, and delete it in Task 7.

- [ ] **Step 5: Commit**

```bash
mix format
mix test test/kith_web/live/contact_live/cluster_merge_test.exs
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): render the cluster merge screen"
```

---

### Task 7: Cluster merge screen — interactions

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Produces: `handle_event/3` clauses for `"toggle-member"`, `"set-primary"`, `"choose-field"`, `"toggle-value"`.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "interactions" do
    test "unchecking a member recomputes the result", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html =
        live
        |> element("input[phx-click='toggle-member'][phx-value-id='#{ctx.b.id}']")
        |> render_click()

      assert html =~ "Merge 1 contacts" or html =~ "1 selected"
      refute html =~ "Jiyoung"
    end

    test "choosing a conflicting value marks it selected", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html =
        live
        |> element("button[phx-value-field='company'][phx-value-index='1']")
        |> render_click()

      assert html =~ "Figma"
    end

    test "changing the selection discards an explicit choice", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          company: "Stripe"
        })

      candidate!(ctx.account_id, ctx.b, c)

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-value-field='company'][phx-value-index='1']")
      |> render_click()

      html =
        live
        |> element("input[phx-click='toggle-member'][phx-value-id='#{c.id}']")
        |> render_click()

      # Back to the computed default rather than the override.
      assert html =~ "Stripe"
    end

    test "unchecking a value removes it from the merge", ctx do
      email_type =
        Kith.Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      field = ContactsFixtures.contact_field_fixture(ctx.b, email_type.id, %{value: "x@y.com"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html =
        live
        |> element("input[phx-click='toggle-value'][phx-value-id='#{field.id}']")
        |> render_click()

      assert html =~ "x@y.com"
    end

    test "making another member primary moves the badge", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html =
        live
        |> element("button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
        |> render_click()

      assert html =~ "primary"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "interactions"`
Expected: FAIL — no matching `handle_event/3` clause.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/kith_web/live/contact_live/cluster_merge.ex`, replacing any
temporary catch-all handler:

```elixir
  @impl true
  def handle_event("toggle-member", %{"id" => id}, socket) do
    id = String.to_integer(id)

    selected =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply,
     socket
     |> assign(:selected_ids, selected)
     # Selection changed, so every derived value is stale — including choices
     # the user made, which may no longer be held by any selected member.
     |> assign(:overrides, %{})
     |> assign(:dropped, MapSet.new())
     |> recompute()}
  end

  def handle_event("set-primary", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:primary_id, String.to_integer(id)) |> recompute()}
  end

  def handle_event("choose-field", %{"field" => field, "index" => index}, socket) do
    field = String.to_existing_atom(field)
    index = String.to_integer(index)

    selected =
      Enum.filter(socket.assigns.members, &MapSet.member?(socket.assigns.selected_ids, &1.id))

    case Enum.at(MergeResolution.candidates_for(selected, field), index) do
      nil ->
        {:noreply, socket}

      candidate ->
        {:noreply,
         assign(socket, :overrides, Map.put(socket.assigns.overrides, field, candidate.value))}
    end
  end

  def handle_event("toggle-value", %{"type" => type, "id" => id}, socket) do
    key = {type, cast_entry_id(id)}

    dropped =
      if MapSet.member?(socket.assigns.dropped, key) do
        MapSet.delete(socket.assigns.dropped, key)
      else
        MapSet.put(socket.assigns.dropped, key)
      end

    {:noreply, assign(socket, :dropped, dropped)}
  end

  defp cast_entry_id(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): wire cluster merge screen interactions"
```

---

### Task 8: Submitting a merge and a rejection

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Consumes: `Contacts.merge_cluster/4`, `DuplicateDetection.dismiss_selection/3`.
- Produces: `handle_event/3` clauses for `"merge"` and `"not-duplicates"`.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "submitting" do
    test "merging redirects to the survivor and trashes the rest", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      loser_id = if survivor_id == ctx.a.id, do: ctx.b.id, else: ctx.a.id

      assert Kith.Repo.get!(Kith.Contacts.Contact, loser_id).deleted_at != nil
    end

    test "merging with a member unchecked dismisses that pair", ctx do
      c = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Sarah", last_name: "Kim"})
      candidate!(ctx.account_id, ctx.b, c)

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("input[phx-click='toggle-member'][phx-value-id='#{c.id}']")
      |> render_click()

      assert {:error, {:redirect, _}} =
               live |> element("button[phx-click='merge']") |> render_click()

      statuses =
        Kith.Repo.all(
          from(d in Kith.Contacts.DuplicateCandidate,
            where: d.contact_id == ^min(ctx.b.id, c.id) and d.duplicate_contact_id == ^max(ctx.b.id, c.id),
            select: d.status
          )
        )

      assert statuses == ["dismissed"]
    end

    test "not duplicates dismisses the cluster and returns to the list", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert {:error, {:redirect, %{to: "/contacts/duplicates"}}} =
               live |> element("button[phx-click='not-duplicates']") |> render_click()

      assert Kith.DuplicateDetection.list_clusters(ctx.account_id) == []
    end

    test "a member merged elsewhere produces an inline error, not a partial merge", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Another session trashes a member behind our back.
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      html = live |> element("button[phx-click='merge']") |> render_click()

      assert html =~ "changed since you opened"
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.a.id).deleted_at == nil
    end

    test "a viewer cannot open the screen", ctx do
      viewer = AccountsFixtures.user_fixture(%{role: "viewer"})

      assert {:error, {:live_redirect, %{to: "/contacts"}}} =
               live(log_in_user(build_conn(), viewer), cluster_path(ctx.a, ctx.b))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "submitting"`
Expected: FAIL — no `"merge"` handler.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/kith_web/live/contact_live/cluster_merge.ex`:

```elixir
  def handle_event("merge", _params, socket) do
    selected = selected_members(socket)
    survivor_id = socket.assigns.primary_id
    loser_ids = selected |> Enum.map(& &1.id) |> Enum.reject(&(&1 == survivor_id))

    resolution = %{
      fields: Map.merge(socket.assigns.resolution.fields, socket.assigns.overrides),
      drop: build_drop(socket),
      unchecked_ids: unchecked_ids(socket)
    }

    case Contacts.merge_cluster(socket.assigns.current_scope, survivor_id, loser_ids, resolution) do
      {:ok, survivor} ->
        {:noreply,
         socket
         |> put_flash(:info, "Merged #{length(loser_ids) + 1} contacts")
         |> redirect(to: ~p"/contacts/#{survivor.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("not-duplicates", _params, socket) do
    DuplicateDetection.dismiss_selection(
      socket.assigns.current_scope.account.id,
      socket.assigns.selected_ids |> MapSet.to_list(),
      unchecked_ids(socket)
    )

    {:noreply,
     socket
     |> put_flash(:info, "Marked as not duplicates")
     |> redirect(to: ~p"/contacts/duplicates")}
  end

  defp unchecked_ids(socket) do
    socket.assigns.members
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(socket.assigns.selected_ids, &1))
  end

  # The screen groups dropped values by its own section labels; the engine wants
  # them keyed by entity type.
  defp build_drop(socket) do
    Enum.reduce(socket.assigns.dropped, %{}, fn {type, id}, acc ->
      case drop_key(type) do
        nil -> acc
        key -> Map.update(acc, key, [id], &[id | &1])
      end
    end)
  end

  defp drop_key("Fields"), do: :contact_fields
  defp drop_key("Addresses"), do: :addresses
  defp drop_key("Tags"), do: :tags
  defp drop_key(_), do: nil

  defp error_message(:trashed),
    do: "One of these contacts changed since you opened this page."

  defp error_message(:not_found),
    do: "One of these contacts changed since you opened this page."

  defp error_message({:unknown_value, field}),
    do: "The #{humanize(field)} you picked changed since you opened this page."

  defp error_message(reason), do: "Merge failed: #{inspect(reason)}"
```

Aliases are unchecked through the `"Aliases"` label but carried in `fields`
rather than `drop`, so extend the merge payload: after building `resolution`,
subtract dropped aliases from the resolved array:

```elixir
    dropped_aliases =
      for {"Aliases", value} <- socket.assigns.dropped, do: value

    resolution =
      update_in(resolution.fields[:aliases], fn
        list when is_list(list) -> list -- dropped_aliases
        other -> other
      end)
```

Place that immediately after the `resolution = %{...}` assignment and before the
`case`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test`
Expected: PASS across the suite.

- [ ] **Step 5: Commit**

```bash
mix format
mix credo --strict
mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): submit cluster merges and rejections"
```

---

### Task 9: The Immich row

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Consumes: `MergeFields.immich_fields/0`, the resolver's Immich rules from slice 1 Task 3.
- Produces: `handle_event/3` clause for `"choose-immich"`. The Identity section renders one Immich row listing linked members by name and sync date.

The Identity section iterates `MergeFields.choice_fields()`, which deliberately
excludes the Immich group, so without this task the four Immich columns are
resolved but never shown — B10 would be unmet.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "immich" do
    setup ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [
          immich_person_id: "person-a",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-01-01 00:00:00Z]
        ]
      )

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [
          immich_person_id: "person-b",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-02-01 00:00:00Z]
        ]
      )

      ctx
    end

    test "renders one row naming each linked member, not four id rows", ctx do
      {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert html =~ "Photo library"
      refute html =~ "person-a"
      refute html =~ "immich_person_id"
    end

    test "offers an unlink option and one option per linked member", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='#{ctx.a.id}']")
      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='#{ctx.b.id}']")
      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='none']")
    end

    test "choosing a member adopts that member's whole group", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      survivor = Kith.Repo.get!(Kith.Contacts.Contact, survivor_id)

      assert survivor.immich_person_id == "person-b"
      assert survivor.immich_status == "linked"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "immich"`
Expected: FAIL — `Photo library` is absent because no Immich row is rendered.

- [ ] **Step 3: Write minimal implementation**

Add these helpers to `lib/kith_web/live/contact_live/cluster_merge.ex`:

```elixir
  defp linked_members(assigns) do
    assigns
    |> selected_from_assigns()
    |> Enum.filter(&(not is_nil(&1.immich_person_id)))
  end

  # Which member's Immich group is currently winning, so the row can highlight
  # it without exposing the opaque person id.
  defp immich_source_id(assigns) do
    case Map.get(assigns.overrides, :__immich__, :default) do
      :default ->
        chosen = Map.get(assigns.resolution.fields, :immich_person_id)

        case Enum.find(linked_members(assigns), &(&1.immich_person_id == chosen)) do
          nil -> :none
          member -> member.id
        end

      other ->
        other
    end
  end

  defp immich_sync_label(nil), do: "never synced"
  defp immich_sync_label(at), do: "synced #{Calendar.strftime(at, "%d %b %Y")}"
```

Add this row to the Identity section's template, immediately after the
`:for={field <- MergeFields.choice_fields()}` block and inside the same
`<details>`:

```heex
          <div
            :if={linked_members(assigns) != []}
            class="grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]"
          >
            <div class="text-sm text-[var(--color-text-secondary)]">Photo library</div>
            <div class="flex flex-wrap items-center gap-2">
              <button
                :for={member <- linked_members(assigns)}
                type="button"
                phx-click="choose-immich"
                phx-value-id={member.id}
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm text-start",
                  if(immich_source_id(assigns) == member.id,
                    do: "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                {member.display_name}
                <span class="block text-[10px] opacity-70">
                  {immich_sync_label(member.immich_last_synced_at)}
                </span>
              </button>
              <button
                type="button"
                phx-click="choose-immich"
                phx-value-id="none"
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm",
                  if(immich_source_id(assigns) == :none,
                    do: "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                Not linked
              </button>
            </div>
          </div>
```

Add the event handler, beside the other `handle_event/3` clauses:

```elixir
  def handle_event("choose-immich", %{"id" => "none"}, socket) do
    overrides =
      Enum.reduce(MergeFields.immich_fields(), socket.assigns.overrides, fn field, acc ->
        Map.put(acc, field, :clear)
      end)

    {:noreply, assign(socket, :overrides, Map.put(overrides, :__immich__, :none))}
  end

  def handle_event("choose-immich", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      member ->
        # All four columns move together or the survivor ends up with one
        # record's person id and another's sync timestamp.
        overrides =
          Enum.reduce(MergeFields.immich_fields(), socket.assigns.overrides, fn field, acc ->
            Map.put(acc, field, Map.fetch!(member, field) || :clear)
          end)

        {:noreply, assign(socket, :overrides, Map.put(overrides, :__immich__, id))}
    end
  end
```

`:__immich__` is bookkeeping for the UI, not a contact field, so strip it before
submitting. In the `"merge"` handler, change the `fields` line to:

```elixir
      fields:
        socket.assigns.resolution.fields
        |> Map.merge(Map.delete(socket.assigns.overrides, :__immich__)),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): render immich links as one editable row"
```

---

## Slice 2 completion checklist

- [ ] `mix precommit` passes.
- [ ] Spec scenarios covered: A1–A6, B1–B10, C1–C5, F1–F3, F5–F6, G2.
- [ ] The old wizard at `/contacts/:id/merge` still exists and still works. It is
      deleted in slice 3.
- [ ] Manual check: open a real four-member cluster in the browser and confirm
      the Identity section opens itself while Contact details stays folded.
