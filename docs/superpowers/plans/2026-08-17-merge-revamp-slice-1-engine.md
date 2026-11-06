# Merge Revamp — Slice 1: Resolver, Engine and Bug Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-contact merge engine with an N-way `merge_cluster/4` backed by a shared resolution module, fixing the two data-loss bugs, with no user-visible UI change.

**Architecture:** A field registry (`MergeFields`) declares what is mergeable and how. A pure resolver (`MergeResolution`) turns a list of member contacts into a complete field map plus conflict and attribution metadata for later UI use. The engine (`Contacts.merge_cluster/4`) takes that map, validates every value against the members, and applies it inside one `Ecto.Multi`. The existing wizard and REST API keep working through a thin `merge_contacts/3` shim, so nothing user-facing changes in this slice.

**Tech Stack:** Elixir, Ecto, PostgreSQL, Oban, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-17-duplicate-merge-revamp-design.md`

## Global Constraints

- Account-scoped multitenancy: every query goes through the account. Members must all belong to `scope.account.id`.
- Soft-delete: losers get `deleted_at` set; they are never hard-deleted.
- Never add `Co-Authored-By` lines to commits.
- Run `mix test` before every commit and ensure 0 failures.
- `mix format` after each task; the repo uses `Phoenix.LiveView.HTMLFormatter` for `.heex`.
- Oban is disabled in test env; assert enqueued jobs with `Oban.Testing`.
- One deviation from the spec, deliberate: §3 writes the resolver as `resolve(members)`. It is implemented as `resolve(members, survivor_id)` because the Immich default rule and the `first_met_through_id` self-reference clear both need to know which member survives.

## File Structure

| File | Responsibility |
|---|---|
| `lib/kith/contacts/merge_fields.ex` (create) | Declares which contact fields are mergeable and how each is treated. No logic beyond classification. |
| `lib/kith/contacts/merge_resolution.ex` (create) | Pure function: members → resolved field map + conflicts + attributions. No DB writes. |
| `lib/kith/contacts/merge.ex` (create) | The `Ecto.Multi` engine. Called by `Contacts.merge_cluster/4`. Kept out of `contacts.ex`, which is already 2224 lines. |
| `lib/kith/contacts.ex` (modify) | Thin delegation: `merge_cluster/4` → `Merge.run/4`, and `merge_contacts/3` becomes a shim. |
| `lib/kith/duplicate_detection.ex` (modify) | Pair resolution and repointing helpers used by the engine. |
| `lib/kith_web/controllers/api/contact_controller.ex:218` (modify) | Adapt the API merge action to the resolver + engine. |
| `test/kith/contacts/merge_fields_test.exs` (create) | Registry classification and the non-clearable derivation guard. |
| `test/kith/contacts/merge_resolution_test.exs` (create) | Every resolution rule. |
| `test/kith/contacts_merge_test.exs` (modify) | Extended for N-way, the six missing remaps, drop, pairs. |

---

### Task 1: Field registry

**Files:**
- Create: `lib/kith/contacts/merge_fields.ex`
- Test: `test/kith/contacts/merge_fields_test.exs`

**Interfaces:**
- Consumes: `Kith.Contacts.Contact` (existing schema).
- Produces: `MergeFields.choice_fields/0`, `policy_fields/0`, `array_fields/0`, `immich_fields/0`, `all/0`, `non_clearable/0`, `non_clearable?/1` — all returning lists of atoms except the last, which returns a boolean.

- [ ] **Step 1: Write the failing test**

Create `test/kith/contacts/merge_fields_test.exs`:

```elixir
defmodule Kith.Contacts.MergeFieldsTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts.MergeFields

  describe "classification" do
    test "display_name is never mergeable" do
      refute :display_name in MergeFields.all()
    end

    test "the fields the old wizard exposed are all choice fields" do
      for field <- [
            :first_name,
            :last_name,
            :nickname,
            :birthdate,
            :description,
            :occupation,
            :company,
            :avatar
          ] do
        assert field in MergeFields.choice_fields(), "#{field} missing"
      end
    end

    test "the fields the old wizard hid are now covered" do
      for field <- [
            :middle_name,
            :gender_id,
            :currency_id,
            :first_met_at,
            :first_met_where,
            :first_met_through_id
          ] do
        assert field in MergeFields.choice_fields(), "#{field} missing"
      end
    end

    test "policy, array and immich fields are separate from choice fields" do
      assert :favorite in MergeFields.policy_fields()
      assert :aliases in MergeFields.array_fields()
      assert :immich_person_id in MergeFields.immich_fields()

      refute :favorite in MergeFields.choice_fields()
      refute :aliases in MergeFields.choice_fields()
      refute :immich_person_id in MergeFields.choice_fields()
    end

    test "all/0 is the union of the four groups" do
      expected =
        MergeFields.choice_fields() ++
          MergeFields.policy_fields() ++
          MergeFields.array_fields() ++ MergeFields.immich_fields()

      assert Enum.sort(MergeFields.all()) == Enum.sort(expected)
    end
  end

  describe "non_clearable" do
    test "matches the contact update changeset's required fields" do
      required =
        %Kith.Contacts.Contact{}
        |> Kith.Contacts.Contact.update_changeset(%{})
        |> Map.fetch!(:required)

      assert Enum.sort(MergeFields.non_clearable()) == Enum.sort(required)
    end

    test "first_name cannot be cleared" do
      assert MergeFields.non_clearable?(:first_name)
      refute MergeFields.non_clearable?(:nickname)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts/merge_fields_test.exs`
Expected: FAIL with `module Kith.Contacts.MergeFields is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith/contacts/merge_fields.ex`:

```elixir
defmodule Kith.Contacts.MergeFields do
  @moduledoc """
  Declares which `Kith.Contacts.Contact` fields participate in a merge and how
  each is treated.

  Four groups:

    * `choice_fields` — ordinary scalars the user picks between.
    * `policy_fields` — booleans and their companions, resolved by policy
      rather than by choice (see `Kith.Contacts.MergeResolution`).
    * `array_fields` — array columns resolved as a deduplicated union.
    * `immich_fields` — integration state that moves as one unit.

  `display_name` is deliberately absent: it is computed by
  `Contact.compute_display_name/1` and recomputed asynchronously by
  `Kith.Workers.DisplayNameRecomputeWorker`.
  """

  alias Kith.Contacts.Contact

  @choice_fields ~w(
    first_name middle_name last_name nickname
    birthdate birthdate_year_unknown
    description avatar occupation company
    gender_id currency_id
    first_met_at first_met_year_unknown first_met_where
    first_met_through_id first_met_additional_info
  )a

  @policy_fields ~w(favorite is_archived deceased deceased_at)a
  @array_fields ~w(aliases)a
  @immich_fields ~w(immich_person_id immich_person_url immich_status immich_last_synced_at)a

  @doc "Scalars the user picks between."
  def choice_fields, do: @choice_fields

  @doc "Fields resolved by policy rather than by user choice."
  def policy_fields, do: @policy_fields

  @doc "Array columns resolved as a deduplicated union."
  def array_fields, do: @array_fields

  @doc "Immich integration state, moved as a single unit."
  def immich_fields, do: @immich_fields

  @doc "Every mergeable field."
  def all, do: @choice_fields ++ @policy_fields ++ @array_fields ++ @immich_fields

  @doc """
  Fields that cannot be set to `:clear`, derived from the contact update
  changeset's `validate_required/2` list rather than maintained by hand.
  """
  def non_clearable do
    %Contact{}
    |> Contact.update_changeset(%{})
    |> Map.fetch!(:required)
  end

  @doc "Whether `field` may be cleared."
  def non_clearable?(field), do: field in non_clearable()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts/merge_fields_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge_fields.ex test/kith/contacts/merge_fields_test.exs
git commit -m "feat(contacts): add merge field registry"
```

---

### Task 2: Resolver — scalar fields

**Files:**
- Create: `lib/kith/contacts/merge_resolution.ex`
- Test: `test/kith/contacts/merge_resolution_test.exs`

**Interfaces:**
- Consumes: `MergeFields.choice_fields/0`.
- Produces: `MergeResolution.resolve(members, survivor_id)` returning
  `%MergeResolution{fields: map, conflicts: map, attributions: map}`.
  `fields` maps field atom → concrete value or `:clear`.
  `conflicts` maps field atom → list of `%{value: term, member_ids: [integer], count: integer}`, present only for contested fields.
  `attributions` maps field atom → `:all_agree | {:only, contact_id} | {:some, count} | :none`.

- [ ] **Step 1: Write the failing test**

Create `test/kith/contacts/merge_resolution_test.exs`:

```elixir
defmodule Kith.Contacts.MergeResolutionTest do
  use Kith.DataCase, async: false

  alias Kith.Contacts.MergeResolution
  alias Kith.ContactsFixtures
  alias Kith.AccountsFixtures

  setup do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{account_id: user.account_id}
  end

  defp contact(account_id, attrs), do: ContactsFixtures.contact_fixture(account_id, attrs)

  describe "scalar fields" do
    test "no member holds a value — field is cleared, no attribution", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", occupation: nil})
      b = contact(ctx.account_id, %{first_name: "Sarah", occupation: nil})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.occupation == :clear
      assert res.attributions.occupation == :none
      refute Map.has_key?(res.conflicts, :occupation)
    end

    test "every member agrees — value kept, attributed to all", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah"})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.first_name == "Sarah"
      assert res.attributions.first_name == :all_agree
    end

    test "only one member holds a value — gap is filled", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", middle_name: nil})
      b = contact(ctx.account_id, %{first_name: "Sarah", middle_name: "Jiyoung"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.middle_name == "Jiyoung"
      assert res.attributions.middle_name == {:only, b.id}
      refute Map.has_key?(res.conflicts, :middle_name)
    end

    test "whitespace-only differences are not a conflict", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})
      b = contact(ctx.account_id, %{first_name: "Sarah", company: "  Figma  "})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.company == "Figma"
      assert res.attributions.company == :all_agree
    end

    test "disagreement is a conflict, defaulting to the most-held value", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})
      b = contact(ctx.account_id, %{first_name: "Sarah", company: "Stripe"})
      c = contact(ctx.account_id, %{first_name: "Sarah", company: "Stripe"})

      res = MergeResolution.resolve([a, b, c], a.id)

      assert res.fields.company == "Stripe"
      assert res.attributions.company == {:some, 2}

      candidates = res.conflicts.company
      assert length(candidates) == 2
      stripe = Enum.find(candidates, &(&1.value == "Stripe"))
      assert stripe.count == 2
      assert Enum.sort(stripe.member_ids) == Enum.sort([b.id, c.id])
    end

    test "a tied conflict breaks toward the most recently updated member", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})
      b = contact(ctx.account_id, %{first_name: "Sarah", company: "Stripe"})

      # Make b unambiguously newer.
      b =
        b
        |> Ecto.Changeset.change(%{updated_at: DateTime.add(a.updated_at, 3600, :second)})
        |> Repo.update!()

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.company == "Stripe"
    end

    test "resolving a single member is a no-op copy", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})

      res = MergeResolution.resolve([a], a.id)

      assert res.fields.first_name == "Sarah"
      assert res.fields.company == "Figma"
      assert res.conflicts == %{}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts/merge_resolution_test.exs`
Expected: FAIL with `module Kith.Contacts.MergeResolution is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith/contacts/merge_resolution.ex`:

```elixir
defmodule Kith.Contacts.MergeResolution do
  @moduledoc """
  Turns a set of member contacts into the complete field map a merge will apply.

  Pure: reads the structs it is given and writes nothing. This is the single
  implementation of merge resolution — the cluster LiveView calls it to render,
  the REST API adapter calls it to build its payload, and the engine never calls
  it at all. That separation is what makes a merge apply exactly what the user
  approved: the engine validates a concrete map rather than re-deriving one at
  transaction time.

  Resolution is recomputed from scratch whenever the member selection changes;
  explicit user choices are not carried across a change.
  """

  alias Kith.Contacts.MergeFields

  defstruct fields: %{}, conflicts: %{}, attributions: %{}

  @type t :: %__MODULE__{
          fields: %{atom() => term() | :clear},
          conflicts: %{atom() => [%{value: term(), member_ids: [integer()], count: integer()}]},
          attributions: %{atom() => :all_agree | {:only, integer()} | {:some, integer()} | :none}
        }

  @doc """
  Resolves `members` into a complete field map.

  `survivor_id` must be the id of one of `members`. It is needed by rules that
  are relative to the surviving record rather than to the set as a whole.
  """
  def resolve(members, _survivor_id) when is_list(members) and members != [] do
    Enum.reduce(MergeFields.choice_fields(), %__MODULE__{}, fn field, acc ->
      put_resolution(acc, field, resolve_scalar(members, field))
    end)
  end

  defp put_resolution(acc, field, {value, attribution, candidates}) do
    acc = %{
      acc
      | fields: Map.put(acc.fields, field, value),
        attributions: Map.put(acc.attributions, field, attribution)
    }

    if candidates == [] do
      acc
    else
      %{acc | conflicts: Map.put(acc.conflicts, field, candidates)}
    end
  end

  # Returns {resolved_value, attribution, conflict_candidates}
  defp resolve_scalar(members, field) do
    held =
      members
      |> Enum.map(fn member -> {member.id, normalize(Map.fetch!(member, field))} end)
      |> Enum.reject(fn {_id, value} -> is_nil(value) end)

    case held |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        {:clear, :none, []}

      [only] ->
        {only, attribution(members, held), []}

      _many ->
        candidates = candidates(held)
        {default_value(members, candidates), attribution(members, held), candidates}
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value

  defp attribution(members, held) do
    case length(held) do
      0 -> :none
      1 -> {:only, held |> hd() |> elem(0)}
      n when n == length(members) -> :all_agree
      n -> {:some, n}
    end
  end

  defp candidates(held) do
    held
    |> Enum.group_by(fn {_id, value} -> value end, fn {id, _value} -> id end)
    |> Enum.map(fn {value, ids} -> %{value: value, member_ids: ids, count: length(ids)} end)
  end

  # Most-held value wins; ties break toward the most recently updated member
  # holding it.
  defp default_value(members, candidates) do
    updated_at = Map.new(members, &{&1.id, &1.updated_at})

    candidates
    |> Enum.max_by(fn %{member_ids: ids, count: count} ->
      newest =
        ids
        |> Enum.map(&Map.fetch!(updated_at, &1))
        |> Enum.max(DateTime)
        |> DateTime.to_unix()

      {count, newest}
    end)
    |> Map.fetch!(:value)
  end
end
```

`survivor_id` is unused at this stage — hence the underscore. Task 3 introduces
the two rules that need it (the Immich default and the `first_met_through_id`
self-reference clear) and drops the underscore then.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts/merge_resolution_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge_resolution.ex test/kith/contacts/merge_resolution_test.exs
git commit -m "feat(contacts): resolve scalar fields across merge members"
```

---

### Task 3: Resolver — arrays, associations, policy flags and Immich

**Files:**
- Modify: `lib/kith/contacts/merge_resolution.ex`
- Test: `test/kith/contacts/merge_resolution_test.exs`

**Interfaces:**
- Consumes: `MergeResolution.resolve/2` from Task 2.
- Produces: the same struct, with `fields` additionally covering `aliases`, the four policy fields and the four Immich fields, and with `first_met_through_id` cleared when it points at a merged member.

- [ ] **Step 1: Write the failing test**

Append these describe blocks to `test/kith/contacts/merge_resolution_test.exs`:

```elixir
  describe "array fields" do
    test "aliases are unioned and deduplicated", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", aliases: ["Sarah K.", "SK"]})
      b = contact(ctx.account_id, %{first_name: "Sarah", aliases: ["SK", "김지영"]})

      res = MergeResolution.resolve([a, b], a.id)

      assert Enum.sort(res.fields.aliases) == Enum.sort(["Sarah K.", "SK", "김지영"])
    end

    test "no aliases anywhere resolves to an empty list", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah"})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.aliases == []
    end
  end

  describe "association ids" do
    test "gender_id resolves like any other scalar", ctx do
      gender = Repo.one!(from(g in Kith.Contacts.Gender, limit: 1))
      a = contact(ctx.account_id, %{first_name: "Sarah", gender_id: nil})
      b = contact(ctx.account_id, %{first_name: "Sarah", gender_id: gender.id})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.gender_id == gender.id
    end

    test "first_met_through pointing at a merged member is cleared", ctx do
      b = contact(ctx.account_id, %{first_name: "Sarah"})
      a = contact(ctx.account_id, %{first_name: "Sarah", first_met_through_id: b.id})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.first_met_through_id == :clear
    end

    test "first_met_through pointing outside the cluster is kept", ctx do
      outsider = contact(ctx.account_id, %{first_name: "Dana"})
      a = contact(ctx.account_id, %{first_name: "Sarah", first_met_through_id: outsider.id})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.first_met_through_id == outsider.id
    end
  end

  describe "policy fields" do
    test "favorite is true if any member is favorited", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", favorite: false})
      b = contact(ctx.account_id, %{first_name: "Sarah", favorite: true})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.favorite == true
    end

    test "is_archived is false if any member is active", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", is_archived: true})
      b = contact(ctx.account_id, %{first_name: "Sarah", is_archived: false})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.is_archived == false
    end

    test "deceased_at takes the earliest non-nil date", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", deceased: true, deceased_at: ~D[2024-05-01]})
      b = contact(ctx.account_id, %{first_name: "Sarah", deceased: true, deceased_at: ~D[2023-02-11]})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.deceased == true
      assert res.fields.deceased_at == ~D[2023-02-11]
    end

    test "deceased with no dates anywhere leaves deceased_at nil", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", deceased: true, deceased_at: nil})
      b = contact(ctx.account_id, %{first_name: "Sarah", deceased: false})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.deceased == true
      assert res.fields.deceased_at == :clear
    end
  end

  describe "immich fields" do
    test "the survivor's link wins when it has one", ctx do
      a =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          immich_person_id: "survivor-person",
          immich_status: "linked"
        })

      b =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          immich_person_id: "loser-person",
          immich_status: "linked"
        })

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.immich_person_id == "survivor-person"
    end

    test "an unlinked survivor adopts the only linked member's whole group", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", immich_person_id: nil})

      b =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          immich_person_id: "loser-person",
          immich_person_url: "https://immich.example/people/loser-person",
          immich_status: "linked"
        })

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.immich_person_id == "loser-person"
      assert res.fields.immich_person_url == "https://immich.example/people/loser-person"
      assert res.fields.immich_status == "linked"
    end

    test "with several linked members the most recently synced wins", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", immich_person_id: nil})

      b =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          immich_person_id: "older",
          immich_status: "linked",
          immich_last_synced_at: ~U[2025-01-01 00:00:00Z]
        })

      c =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          immich_person_id: "newer",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-01-01 00:00:00Z]
        })

      res = MergeResolution.resolve([a, b, c], a.id)

      assert res.fields.immich_person_id == "newer"
    end

    test "nobody linked leaves the group cleared", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah"})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.immich_person_id == :clear
    end
  end
```

Add `import Ecto.Query` to the top of the test module, below `use Kith.DataCase`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts/merge_resolution_test.exs`
Expected: FAIL — `res.fields.aliases` raises `KeyError` because only choice fields are resolved so far.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/contacts/merge_resolution.ex`, replace `resolve/2` and add the new
private functions below it:

```elixir
  def resolve(members, survivor_id) when is_list(members) and members != [] do
    member_ids = MapSet.new(members, & &1.id)

    MergeFields.choice_fields()
    |> Enum.reduce(%__MODULE__{}, fn field, acc ->
      put_resolution(acc, field, resolve_scalar(members, field))
    end)
    |> clear_self_reference(member_ids)
    |> resolve_arrays(members)
    |> resolve_policy_fields(members)
    |> resolve_immich(members, survivor_id)
  end

  # A contact cannot be met through a record it just absorbed.
  defp clear_self_reference(acc, member_ids) do
    case Map.get(acc.fields, :first_met_through_id) do
      id when is_integer(id) ->
        if MapSet.member?(member_ids, id) do
          %{acc | fields: Map.put(acc.fields, :first_met_through_id, :clear)}
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp resolve_arrays(acc, members) do
    Enum.reduce(MergeFields.array_fields(), acc, fn field, acc ->
      union =
        members
        |> Enum.flat_map(&(Map.fetch!(&1, field) || []))
        |> Enum.uniq()

      %{acc | fields: Map.put(acc.fields, field, union)}
    end)
  end

  defp resolve_policy_fields(acc, members) do
    favorite = Enum.any?(members, & &1.favorite)
    is_archived = not Enum.any?(members, &(not &1.is_archived))
    deceased = Enum.any?(members, & &1.deceased)

    deceased_at =
      members
      |> Enum.filter(& &1.deceased)
      |> Enum.map(& &1.deceased_at)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> :clear
        dates -> Enum.min(dates, Date)
      end

    fields =
      acc.fields
      |> Map.put(:favorite, favorite)
      |> Map.put(:is_archived, is_archived)
      |> Map.put(:deceased, deceased)
      |> Map.put(:deceased_at, deceased_at)

    %{acc | fields: fields}
  end

  # The four Immich columns move together: an id from one record paired with
  # another record's sync timestamp is corrupt state.
  defp resolve_immich(acc, members, survivor_id) do
    linked = Enum.filter(members, &(not is_nil(&1.immich_person_id)))
    survivor = Enum.find(members, &(&1.id == survivor_id))

    source =
      cond do
        survivor && survivor.immich_person_id -> survivor
        linked == [] -> nil
        true -> Enum.max_by(linked, &sync_key/1)
      end

    fields =
      Enum.reduce(MergeFields.immich_fields(), acc.fields, fn field, fields ->
        value = if source, do: Map.fetch!(source, field), else: nil
        Map.put(fields, field, value || :clear)
      end)

    %{acc | fields: fields}
  end

  defp sync_key(%{immich_last_synced_at: nil}), do: 0
  defp sync_key(%{immich_last_synced_at: at}), do: DateTime.to_unix(at)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts/merge_resolution_test.exs`
Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge_resolution.ex test/kith/contacts/merge_resolution_test.exs
git commit -m "feat(contacts): resolve arrays, associations, flags and immich state"
```

---

### Task 4: Engine skeleton — lock, validate, apply scalars, soft-delete

**Files:**
- Create: `lib/kith/contacts/merge.ex`
- Modify: `lib/kith/contacts.ex` (add `merge_cluster/4` delegation)
- Test: `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: `MergeFields.non_clearable?/1`, `MergeResolution` struct shape.
- Produces: `Kith.Contacts.merge_cluster(scope, survivor_id, loser_ids, resolution)` returning `{:ok, %Contact{}}` or `{:error, reason}` where reason is one of `:not_found`, `:trashed`, `:different_accounts`, `:survivor_in_losers`, `:no_losers`, `{:unknown_value, field}`, `{:not_clearable, field}`. `resolution` is a plain map `%{fields: map, drop: map}`.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts_merge_test.exs`:

```elixir
  describe "merge_cluster/4 validation" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)
      %{scope: scope}
    end

    defp resolution(fields \\ %{}), do: %{fields: fields, drop: %{}}

    test "merges three contacts into one survivor", ctx do
      c =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          nickname: "Al"
        })

      {:ok, survivor} =
        Contacts.merge_cluster(
          ctx.scope,
          ctx.contact_a.id,
          [ctx.contact_b.id, c.id],
          resolution(%{first_name: "Alice", nickname: "Al", company: "New Corp"})
        )

      assert survivor.id == ctx.contact_a.id
      assert survivor.nickname == "Al"
      assert survivor.company == "New Corp"

      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at != nil
      assert Repo.get!(Kith.Contacts.Contact, c.id).deleted_at != nil
    end

    test "clears a field set to :clear", ctx do
      {:ok, survivor} =
        Contacts.merge_cluster(
          ctx.scope,
          ctx.contact_a.id,
          [ctx.contact_b.id],
          resolution(%{occupation: :clear})
        )

      assert survivor.occupation == nil
    end

    test "rejects clearing a required field", ctx do
      assert {:error, {:not_clearable, :first_name}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{first_name: :clear})
               )
    end

    test "rejects a value no member holds", ctx do
      assert {:error, {:unknown_value, :company}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{company: "Never Corp"})
               )
    end

    test "rejects an empty loser list", ctx do
      assert {:error, :no_losers} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [], resolution())
    end

    test "rejects the survivor appearing among the losers", ctx do
      assert {:error, :survivor_in_losers} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_a.id],
                 resolution()
               )
    end

    test "rejects a contact from another account", ctx do
      other_user = Kith.AccountsFixtures.user_fixture()

      stranger =
        Kith.ContactsFixtures.contact_fixture(other_user.account_id, %{first_name: "Zed"})

      assert {:error, :different_accounts} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [stranger.id],
                 resolution()
               )
    end

    test "rejects an already-trashed member", ctx do
      {:ok, _} =
        ctx.contact_b
        |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
        |> Repo.update()

      assert {:error, :trashed} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution()
               )
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts_merge_test.exs`
Expected: FAIL with `function Kith.Contacts.merge_cluster/4 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/kith/contacts/merge.ex`:

```elixir
defmodule Kith.Contacts.Merge do
  @moduledoc """
  The N-way contact merge engine.

  Applies a resolution it is handed; it never derives one. Everything the merge
  writes was computed by `Kith.Contacts.MergeResolution` and approved by the
  caller, so a concurrent edit between resolution and submission fails
  validation rather than silently changing the result.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kith.Contacts.{Contact, MergeFields}
  alias Kith.Repo

  @doc """
  Merges `loser_ids` into `survivor_id` inside one transaction.

  `resolution` is `%{fields: %{atom => value | :clear}, drop: %{atom => [id]}}`.
  """
  def run(scope, survivor_id, loser_ids, resolution) do
    with {:ok, members} <- lock_and_load(scope, survivor_id, loser_ids),
         survivor = Enum.find(members, &(&1.id == survivor_id)),
         :ok <- validate_fields(members, resolution) do
      losers = Enum.reject(members, &(&1.id == survivor_id))

      Multi.new()
      |> Multi.run(:survivor, fn _repo, _changes ->
        apply_fields(survivor, resolution)
      end)
      |> Multi.run(:soft_delete_losers, fn repo, _changes ->
        now = DateTime.utc_now(:second)
        ids = Enum.map(losers, & &1.id)

        {count, _} =
          repo.update_all(from(c in Contact, where: c.id in ^ids), set: [deleted_at: now])

        {:ok, count}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{survivor: survivor}} -> {:ok, survivor}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp lock_and_load(scope, survivor_id, loser_ids) do
    account_id = scope.account.id
    ids = [survivor_id | loser_ids]

    cond do
      loser_ids == [] ->
        {:error, :no_losers}

      survivor_id in loser_ids ->
        {:error, :survivor_in_losers}

      true ->
        # FOR UPDATE, not just a liveness check: two sessions merging
        # overlapping clusters must serialise rather than interleave.
        members =
          from(c in Contact, where: c.id in ^ids, lock: "FOR UPDATE")
          |> Repo.all()

        cond do
          length(members) != length(Enum.uniq(ids)) -> {:error, :not_found}
          Enum.any?(members, &(&1.account_id != account_id)) -> {:error, :different_accounts}
          Enum.any?(members, &(&1.deleted_at != nil)) -> {:error, :trashed}
          true -> {:ok, members}
        end
    end
  end

  defp validate_fields(members, %{fields: fields}) do
    Enum.reduce_while(fields, :ok, fn {field, value}, :ok ->
      cond do
        value == :clear and MergeFields.non_clearable?(field) ->
          {:halt, {:error, {:not_clearable, field}}}

        value == :clear ->
          {:cont, :ok}

        held_by_member?(members, field, value) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:unknown_value, field}}}
      end
    end)
  end

  # Array and policy fields are computed rather than picked, so they are not
  # required to match a single member's stored value.
  defp held_by_member?(_members, field, _value)
       when field in [:favorite, :is_archived, :deceased, :deceased_at, :aliases],
       do: true

  defp held_by_member?(members, field, value) do
    Enum.any?(members, fn member ->
      stored = Map.fetch!(member, field)
      stored == value or (is_binary(stored) and String.trim(stored) == value)
    end)
  end

  defp apply_fields(survivor, %{fields: fields}) do
    changes =
      Map.new(fields, fn
        {field, :clear} -> {field, nil}
        {field, value} -> {field, value}
      end)

    survivor
    |> Contact.update_changeset(changes)
    |> Repo.update()
  end
end
```

In `lib/kith/contacts.ex`, add to the alias block (`Kith.Contacts.{...}`) the
entry `Merge`, then add this function immediately above the existing
`def merge_contacts(` definition at line 1699:

```elixir
  @doc """
  Merges `loser_ids` into `survivor_id`, applying `resolution`.

  See `Kith.Contacts.MergeResolution` for how a resolution is produced.
  """
  def merge_cluster(scope, survivor_id, loser_ids, resolution) do
    Merge.run(scope, survivor_id, loser_ids, resolution)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts_merge_test.exs`
Expected: PASS — the 8 new tests plus the existing `merge_contacts/3` tests still green.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge.ex lib/kith/contacts.ex test/kith/contacts_merge_test.exs
git commit -m "feat(contacts): add N-way merge engine with locking and validation"
```

---

### Task 5: Remap every owned record, including the six Bug 1 misses

**Files:**
- Modify: `lib/kith/contacts/merge.ex`
- Test: `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: `Merge.run/4` from Task 4.
- Produces: no new public function; `run/4` now moves every record owned by a loser onto the survivor.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts_merge_test.exs`:

```elixir
  describe "merge_cluster/4 remapping" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)
      %{scope: scope}
    end

    test "moves the six record types the old engine orphaned", ctx do
      account_id = ctx.account_id
      loser_id = ctx.contact_b.id

      Repo.insert!(%Kith.Contacts.Debt{
        account_id: account_id,
        contact_id: loser_id,
        amount: Decimal.new("25.00"),
        direction: "owed_to_user",
        status: "outstanding"
      })

      Repo.insert!(%Kith.Contacts.Gift{
        account_id: account_id,
        contact_id: loser_id,
        name: "Book",
        direction: "given",
        status: "given"
      })

      Repo.insert!(%Kith.Contacts.Pet{
        account_id: account_id,
        contact_id: loser_id,
        name: "Mochi"
      })

      Repo.insert!(%Kith.Tasks.Task{
        account_id: account_id,
        contact_id: loser_id,
        title: "Call back"
      })

      Repo.insert!(%Kith.Conversations.Conversation{
        account_id: account_id,
        contact_id: loser_id,
        happened_at: ~D[2026-01-05]
      })

      Repo.insert!(%Kith.Contacts.ImmichCandidate{
        account_id: account_id,
        contact_id: loser_id,
        immich_person_id: "person-1"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [loser_id], %{
          fields: %{},
          drop: %{}
        })

      for schema <- [
            Kith.Contacts.Debt,
            Kith.Contacts.Gift,
            Kith.Contacts.Pet,
            Kith.Tasks.Task,
            Kith.Conversations.Conversation,
            Kith.Contacts.ImmichCandidate
          ] do
        assert Repo.aggregate(
                 from(r in schema, where: r.contact_id == ^survivor.id),
                 :count
               ) == 1,
               "#{inspect(schema)} was not remapped"

        assert Repo.aggregate(
                 from(r in schema, where: r.contact_id == ^loser_id),
                 :count
               ) == 0,
               "#{inspect(schema)} left behind on the loser"
      end
    end

    test "repoints inbound first_met_through references", ctx do
      admirer =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Dana",
          first_met_through_id: ctx.contact_b.id
        })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.get!(Kith.Contacts.Contact, admirer.id).first_met_through_id == survivor.id
    end

    test "moves notes and addresses from every loser", ctx do
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Alice"})

      Kith.ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)
      Kith.ContactsFixtures.note_fixture(c, ctx.user.id)
      Kith.ContactsFixtures.address_fixture(c)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^survivor.id),
               :count
             ) == 2

      assert Repo.aggregate(
               from(a in Kith.Contacts.Address, where: a.contact_id == ^survivor.id),
               :count
             ) == 1
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts_merge_test.exs -k "remapping"`
Expected: FAIL — `Kith.Contacts.Debt was not remapped`, because `run/4` does no remapping yet.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/contacts/merge.ex`, add the schema list near the top of the module,
below the aliases:

```elixir
  # Every schema owning a contact_id that must follow the survivor. The six
  # after `Reminder` are the ones the previous two-contact engine silently
  # orphaned (Bug 1 in the design spec).
  @owned_schemas [
    Kith.Contacts.Note,
    Kith.Contacts.Address,
    Kith.Contacts.ContactField,
    Kith.Contacts.Document,
    Kith.Contacts.Photo,
    Kith.Activities.Call,
    Kith.Activities.LifeEvent,
    Kith.Reminders.Reminder,
    Kith.Reminders.ReminderInstance,
    Kith.Contacts.Debt,
    Kith.Contacts.Gift,
    Kith.Contacts.Pet,
    Kith.Tasks.Task,
    Kith.Conversations.Conversation,
    Kith.Contacts.ImmichCandidate
  ]
```

Then insert a remap step into the `Multi` in `run/4`, between `:survivor` and
`:soft_delete_losers`:

```elixir
      |> Multi.run(:remap_owned, fn repo, _changes ->
        loser_ids = Enum.map(losers, & &1.id)

        Enum.each(@owned_schemas, fn schema ->
          repo.update_all(
            from(r in schema, where: r.contact_id in ^loser_ids),
            set: [contact_id: survivor.id]
          )
        end)

        {:ok, length(@owned_schemas)}
      end)
      |> Multi.run(:remap_activity_contacts, fn repo, _changes ->
        loser_ids = Enum.map(losers, & &1.id)

        # Drop join rows that would collide with one the survivor already has,
        # then move the rest.
        repo.query!(
          """
          DELETE FROM activity_contacts
          WHERE contact_id = ANY($1)
            AND activity_id IN (SELECT activity_id FROM activity_contacts WHERE contact_id = $2)
          """,
          [loser_ids, survivor.id]
        )

        repo.update_all(
          from(ac in "activity_contacts", where: ac.contact_id in ^loser_ids),
          set: [contact_id: survivor.id]
        )

        {:ok, :done}
      end)
      |> Multi.run(:remap_inbound_first_met, fn repo, _changes ->
        loser_ids = Enum.map(losers, & &1.id)

        {count, _} =
          repo.update_all(
            from(c in Contact, where: c.first_met_through_id in ^loser_ids),
            set: [first_met_through_id: survivor.id]
          )

        {:ok, count}
      end)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge.ex test/kith/contacts_merge_test.exs
git commit -m "fix(contacts): remap debts, gifts, pets, tasks, conversations and immich candidates on merge"
```

---

### Task 6: Deduplication and relationships

**Files:**
- Modify: `lib/kith/contacts/merge.ex`
- Test: `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: `Merge.run/4` from Task 5.
- Produces: no new public function; duplicate contact fields, tags, photos and relationships collapse after remapping.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts_merge_test.exs`:

```elixir
  describe "merge_cluster/4 deduplication" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)
      email_type = Repo.one!(from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1))
      %{scope: scope, email_type: email_type}
    end

    test "identical contact fields collapse to one", ctx do
      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
        value: "sarah@example.com"
      })

      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
        value: "sarah@example.com"
      })

      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
        value: "other@example.com"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      values =
        from(f in Kith.Contacts.ContactField,
          where: f.contact_id == ^survivor.id,
          select: f.value
        )
        |> Repo.all()
        |> Enum.sort()

      assert values == ["other@example.com", "sarah@example.com"]
    end

    test "a tag on both members is kept once", ctx do
      {:ok, tag} = Contacts.create_tag(ctx.account_id, %{name: "Design"})
      {:ok, _} = Contacts.add_tag_to_contact(ctx.contact_a, tag)
      {:ok, _} = Contacts.add_tag_to_contact(ctx.contact_b, tag)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      count =
        from(ct in "contact_tags", where: ct.contact_id == ^survivor.id, select: count())
        |> Repo.one()

      assert count == 1
    end

    test "a relationship between two merged members is removed, not self-referential", ctx do
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(ctx.contact_a, ctx.contact_b, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(r in Kith.Contacts.Relationship,
                 where: r.contact_id == ^survivor.id and r.related_contact_id == ^survivor.id
               ),
               :count
             ) == 0
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts_merge_test.exs -k "deduplication"`
Expected: FAIL — the contact-fields test finds three values, and the relationship test finds one self-referential row.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/contacts/merge.ex`, add a dedupe step to the `Multi` immediately
after `:remap_inbound_first_met`:

```elixir
      |> Multi.run(:dedupe_owned, fn repo, _changes ->
        # Contact fields: same type and value collapse to the lowest id.
        repo.query!(
          """
          DELETE FROM contact_fields
          WHERE id IN (
            SELECT cf.id FROM contact_fields cf
            WHERE cf.contact_id = $1
              AND EXISTS (
                SELECT 1 FROM contact_fields other
                WHERE other.contact_id = $1
                  AND other.contact_field_type_id = cf.contact_field_type_id
                  AND other.value = cf.value
                  AND other.id < cf.id
              )
          )
          """,
          [survivor.id]
        )

        # Tags: the join table has no id, so dedupe on (contact_id, tag_id).
        repo.query!(
          """
          DELETE FROM contact_tags a
          USING contact_tags b
          WHERE a.contact_id = $1
            AND b.contact_id = $1
            AND a.tag_id = b.tag_id
            AND a.ctid > b.ctid
          """,
          [survivor.id]
        )

        # Photos: identical content collapses.
        repo.query!(
          """
          DELETE FROM photos
          WHERE id IN (
            SELECT p.id FROM photos p
            WHERE p.contact_id = $1
              AND p.content_hash IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM photos other
                WHERE other.contact_id = $1
                  AND other.content_hash = p.content_hash
                  AND other.id < p.id
              )
          )
          """,
          [survivor.id]
        )

        {:ok, :done}
      end)
      |> Multi.run(:remap_relationships, fn repo, _changes ->
        loser_ids = Enum.map(losers, & &1.id)
        remap_relationships(repo, survivor.id, loser_ids)
      end)
```

Add this private function at the bottom of the module:

```elixir
  # Relationships are directional and unique per (pair, type), so both
  # directions need collision handling before the move, and any relationship
  # that ends up pointing the survivor at itself is dropped.
  defp remap_relationships(repo, survivor_id, loser_ids) do
    repo.query!(
      """
      DELETE FROM relationships
      WHERE contact_id = ANY($1)
        AND (
          related_contact_id = $2
          OR (related_contact_id, relationship_type_id) IN (
            SELECT related_contact_id, relationship_type_id
            FROM relationships WHERE contact_id = $2
          )
        )
      """,
      [loser_ids, survivor_id]
    )

    repo.update_all(
      from(r in Kith.Contacts.Relationship, where: r.contact_id in ^loser_ids),
      set: [contact_id: survivor_id]
    )

    repo.query!(
      """
      DELETE FROM relationships
      WHERE related_contact_id = ANY($1)
        AND (
          contact_id = $2
          OR (contact_id, relationship_type_id) IN (
            SELECT contact_id, relationship_type_id
            FROM relationships WHERE related_contact_id = $2
          )
        )
      """,
      [loser_ids, survivor_id]
    )

    repo.update_all(
      from(r in Kith.Contacts.Relationship, where: r.related_contact_id in ^loser_ids),
      set: [related_contact_id: survivor_id]
    )

    repo.delete_all(
      from(r in Kith.Contacts.Relationship,
        where: r.contact_id == ^survivor_id and r.related_contact_id == ^survivor_id
      )
    )

    {:ok, :done}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge.ex test/kith/contacts_merge_test.exs
git commit -m "feat(contacts): deduplicate fields, tags, photos and relationships after merge"
```

---

### Task 7: Drop list, last_talked_to, job cancellation, display name, audit

**Files:**
- Modify: `lib/kith/contacts/merge.ex`
- Test: `test/kith/contacts_merge_test.exs`

**Interfaces:**
- Consumes: `Merge.run/4` from Task 6.
- Produces: `run/4` now honours `resolution.drop`, sets `last_talked_to`, cancels losers' Oban jobs, enqueues `DisplayNameRecomputeWorker` for the survivor, and writes one `:contact_merged` audit entry. `run/4` gains an `:actor` requirement: `scope.user` is used as the audit actor.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts_merge_test.exs`:

```elixir
  describe "merge_cluster/4 side effects" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)
      email_type = Repo.one!(from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1))
      %{scope: scope, email_type: email_type}
    end

    test "dropped records are removed and recorded in the audit entry", ctx do
      keep =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
          value: "keep@example.com"
        })

      drop =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
          value: "drop@example.com"
        })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{contact_fields: [drop.id]}
        })

      values =
        from(f in Kith.Contacts.ContactField,
          where: f.contact_id == ^survivor.id,
          select: f.value
        )
        |> Repo.all()

      assert values == ["keep@example.com"]
      assert Repo.get(Kith.Contacts.ContactField, keep.id)
      refute Repo.get(Kith.Contacts.ContactField, drop.id)

      log =
        Repo.one!(
          from(l in Kith.AuditLogs.AuditLog,
            where: l.event == "contact_merged",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert [dropped] = log.metadata["dropped"]
      assert dropped["type"] == "contact_fields"
      assert dropped["value"] == "drop@example.com"
      assert dropped["owner_id"] == ctx.contact_b.id
    end

    test "rejects a dropped id belonging to no member", ctx do
      stranger =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Zed"})

      field =
        Kith.ContactsFixtures.contact_field_fixture(stranger, ctx.email_type.id, %{
          value: "zed@example.com"
        })

      assert {:error, {:unknown_drop, :contact_fields}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{},
                 drop: %{contact_fields: [field.id]}
               })
    end

    test "last_talked_to takes the maximum across members", ctx do
      older = ~U[2025-01-01 00:00:00Z]
      newer = ~U[2026-06-01 00:00:00Z]

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [last_talked_to: older]
      )

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [last_talked_to: newer]
      )

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert DateTime.compare(survivor.last_talked_to, newer) == :eq
    end

    test "enqueues a display name recompute for the survivor", ctx do
      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert_enqueued(
        worker: Kith.Workers.DisplayNameRecomputeWorker,
        args: %{contact_id: survivor.id}
      )
    end

    test "a rejected merge changes nothing at all", ctx do
      Kith.ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)

      assert {:error, {:unknown_value, :company}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{company: "Never Corp"},
                 drop: %{}
               })

      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at == nil

      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^ctx.contact_b.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(l in Kith.AuditLogs.AuditLog, where: l.event == "contact_merged"),
               :count
             ) == 0
    end

    test "writes one audit entry naming every loser", ctx do
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Alice"})

      {:ok, _survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
          fields: %{},
          drop: %{}
        })

      logs =
        from(l in Kith.AuditLogs.AuditLog, where: l.event == "contact_merged") |> Repo.all()

      assert length(logs) == 1
      assert Enum.sort(hd(logs).metadata["loser_ids"]) == Enum.sort([ctx.contact_b.id, c.id])
    end
  end
```

Add `use Oban.Testing, repo: Kith.Repo` directly below `use Kith.DataCase` at
the top of `test/kith/contacts_merge_test.exs`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts_merge_test.exs -k "side effects"`
Expected: FAIL — the dropped field is still present and no audit log row exists.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/contacts/merge.ex`, add these aliases at the top:

```elixir
  alias Kith.AuditLogs
  alias Kith.Contacts.{Address, Contact, ContactField, MergeFields}
  alias Kith.Workers.DisplayNameRecomputeWorker
```

Add the drop-target map below `@owned_schemas`:

```elixir
  # Which schema backs each key of `resolution.drop`. Tags are the exception:
  # `contact_tags` is a bare join table, so its ids are tag ids.
  @drop_schemas %{
    contact_fields: ContactField,
    addresses: Address
  }
```

Extend `run/4`: add `validate_drop/2` to the `with` chain, and append these
steps to the `Multi` after `:remap_relationships` and before
`:soft_delete_losers`:

```elixir
      |> Multi.run(:collect_dropped, fn repo, _changes ->
        {:ok, describe_dropped(repo, resolution)}
      end)
      |> Multi.run(:apply_drop, fn repo, _changes ->
        Enum.each(resolution.drop || %{}, fn
          {_key, []} ->
            :ok

          {:tags, tag_ids} ->
            repo.delete_all(
              from(ct in "contact_tags",
                where: ct.contact_id == ^survivor.id and ct.tag_id in ^tag_ids
              )
            )

          {key, ids} ->
            schema = Map.fetch!(@drop_schemas, key)
            repo.delete_all(from(r in schema, where: r.id in ^ids))
        end)

        {:ok, :done}
      end)
      |> Multi.run(:last_talked_to, fn repo, %{survivor: survivor} ->
        latest =
          members
          |> Enum.map(& &1.last_talked_to)
          |> Enum.reject(&is_nil/1)
          |> case do
            [] -> nil
            dates -> Enum.max(dates, DateTime)
          end

        if latest && latest != survivor.last_talked_to do
          survivor |> Ecto.Changeset.change(%{last_talked_to: latest}) |> repo.update()
        else
          {:ok, survivor}
        end
      end)
      |> Multi.run(:cancel_jobs, fn _repo, _changes ->
        Enum.each(losers, &Kith.Reminders.cancel_all_for_contact(&1.id, scope.account.id))
        {:ok, :done}
      end)
```

And append these two steps after `:soft_delete_losers`:

```elixir
      |> Multi.run(:recompute_display_name, fn _repo, _changes ->
        %{contact_id: survivor.id}
        |> DisplayNameRecomputeWorker.new()
        |> Oban.insert()
      end)
      |> Multi.run(:audit, fn _repo, changes ->
        AuditLogs.log_event(scope.account.id, scope.user, :contact_merged,
          contact_id: survivor.id,
          contact_name: survivor.display_name,
          metadata: %{
            survivor_id: survivor.id,
            loser_ids: Enum.map(losers, & &1.id),
            fields: inspect_fields(resolution),
            dropped: changes.collect_dropped
          }
        )
      end)
```

Add these private functions:

```elixir
  defp validate_drop(members, %{drop: drop}) when is_map(drop) do
    member_ids = Enum.map(members, & &1.id)

    Enum.reduce_while(drop, :ok, fn
      {_key, []}, :ok ->
        {:cont, :ok}

      {:tags, _ids}, :ok ->
        {:cont, :ok}

      {key, ids}, :ok ->
        schema = Map.fetch!(@drop_schemas, key)

        owned =
          from(r in schema, where: r.id in ^ids and r.contact_id in ^member_ids, select: r.id)
          |> Repo.all()

        if Enum.sort(owned) == Enum.sort(ids) do
          {:cont, :ok}
        else
          {:halt, {:error, {:unknown_drop, key}}}
        end
    end)
  end

  defp validate_drop(_members, _resolution), do: :ok

  # Captured before deletion so the audit trail survives the rows it describes.
  defp describe_dropped(repo, %{drop: drop}) when is_map(drop) do
    Enum.flat_map(drop, fn
      {_key, []} ->
        []

      {:tags, ids} ->
        Enum.map(ids, &%{type: "tags", value: to_string(&1), owner_id: nil})

      {key, ids} ->
        schema = Map.fetch!(@drop_schemas, key)

        from(r in schema, where: r.id in ^ids, select: {r.value, r.contact_id})
        |> repo.all()
        |> Enum.map(fn {value, owner_id} ->
          %{type: to_string(key), value: value, owner_id: owner_id}
        end)
    end)
  end

  defp describe_dropped(_repo, _resolution), do: []

  defp inspect_fields(%{fields: fields}) do
    Map.new(fields, fn {field, value} -> {to_string(field), inspect(value)} end)
  end
```

Update the `with` in `run/4` to include the drop validation:

```elixir
    with {:ok, members} <- lock_and_load(scope, survivor_id, loser_ids),
         survivor = Enum.find(members, &(&1.id == survivor_id)),
         :ok <- validate_fields(members, resolution),
         :ok <- validate_drop(members, resolution) do
```

**Change what `run/4` returns.** The `:last_talked_to` step produces a newer
survivor struct than the `:survivor` step, so returning the latter would hand
back a contact whose `last_talked_to` is stale. Replace the final `case` clause:

```elixir
      |> case do
        {:ok, %{last_talked_to: survivor}} -> {:ok, survivor}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
```

For the same reason, the `:audit` step must read the survivor from `changes`
rather than closing over the stale outer binding — its function head becomes
`fn _repo, changes ->` and it uses `changes.last_talked_to` wherever the audit
metadata references the survivor's `display_name`.

Note `describe_dropped/2` selects `r.value`, which exists on `ContactField` but
not on `Address`. Give `Address` its own clause by matching on the key before
the generic one:

```elixir
      {:addresses, ids} ->
        from(a in Address, where: a.id in ^ids, select: {a.line1, a.contact_id})
        |> repo.all()
        |> Enum.map(fn {line1, owner_id} ->
          %{type: "addresses", value: line1, owner_id: owner_id}
        end)
```

Place that clause immediately after the `{:tags, ids}` clause.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/contacts_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/contacts/merge.ex test/kith/contacts_merge_test.exs
git commit -m "feat(contacts): apply drop list, last talked to, job cancellation and audit on merge"
```

---

### Task 8: Candidate pair resolution and repointing

**Files:**
- Modify: `lib/kith/duplicate_detection.ex`
- Modify: `lib/kith/contacts/merge.ex`
- Test: `test/kith/duplicate_detection_test.exs`

**Interfaces:**
- Consumes: `Merge.run/4` from Task 7.
- Produces: `DuplicateDetection.resolve_after_merge(account_id, survivor_id, loser_ids, unchecked_ids)` returning `:ok`. Called from the engine's `Multi`. Sets pairs wholly inside the merged set to `merged`, pairs from a merged member to an unchecked member to `dismissed`, repoints every remaining pair referencing a loser onto the survivor, and leaves unchecked-to-unchecked pairs untouched.
- `merge_cluster/4`'s `resolution` map gains an optional `:unchecked_ids` key (default `[]`).

- [ ] **Step 1: Write the failing test**

Append to `test/kith/duplicate_detection_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/duplicate_detection_test.exs -k "resolve_after_merge"`
Expected: FAIL with `function Kith.DuplicateDetection.resolve_after_merge/4 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/kith/duplicate_detection.ex`:

```elixir
  @status_rank %{"pending" => 0, "dismissed" => 1, "merged" => 2}

  @doc """
  Settles candidate pairs after a merge.

  Three rules, from the design spec §2:

    * both endpoints merged → `merged`
    * one merged, one unchecked → `dismissed` (the user reviewed and rejected it)
    * both unchecked → untouched

  Then every remaining pair referencing a loser is repointed onto the survivor,
  because the survivor now *is* that contact. Without repointing, a dismissal
  recorded against a loser evaporates when the loser is trashed and the rejected
  match returns on the next scan.
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
  # (account_id, contact_id, duplicate_contact_id) and the contact_id ordering
  # check constraint both reject an in-place rewrite.
  defp repoint(account_id, survivor_id, []) when is_integer(survivor_id), do: :ok

  defp repoint(account_id, survivor_id, loser_ids) do
    rows =
      from(d in DuplicateCandidate,
        where: d.account_id == ^account_id,
        where: d.contact_id in ^loser_ids or d.duplicate_contact_id in ^loser_ids
      )
      |> Repo.all()

    Repo.delete_all(
      from(d in DuplicateCandidate,
        where: d.account_id == ^account_id,
        where: d.contact_id in ^loser_ids or d.duplicate_contact_id in ^loser_ids
      )
    )

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
    two = if row.duplicate_contact_id in loser_ids, do: survivor_id, else: row.duplicate_contact_id

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
```

Then wire it into the engine. In `lib/kith/contacts/merge.ex`, add this step to
the `Multi` immediately after `:soft_delete_losers`:

```elixir
      |> Multi.run(:resolve_pairs, fn _repo, _changes ->
        Kith.DuplicateDetection.resolve_after_merge(
          scope.account.id,
          survivor.id,
          Enum.map(losers, & &1.id),
          Map.get(resolution, :unchecked_ids, [])
        )

        {:ok, :done}
      end)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith/duplicate_detection_test.exs`
Expected: PASS, 6 new tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith/duplicate_detection.ex lib/kith/contacts/merge.ex test/kith/duplicate_detection_test.exs
git commit -m "feat(duplicates): resolve and repoint candidate pairs after a merge"
```

---

### Task 9: Adapt the API and shim the old wizard

**Files:**
- Modify: `lib/kith/contacts.ex:1699` (replace `merge_contacts/3` body with a shim)
- Modify: `lib/kith_web/controllers/api/contact_controller.ex:218`
- Modify: `lib/kith_web/live/contact_live/merge.ex:174` (remove the blanket dismissal)
- Test: `test/kith/contacts_merge_test.exs`, `test/kith_web/controllers/api/contact_controller_test.exs`

**Interfaces:**
- Consumes: `MergeResolution.resolve/2`, `Contacts.merge_cluster/4`.
- Produces: `Contacts.merge_contacts(survivor_id, non_survivor_id, field_choices \\ %{})` keeps its arity and return shape `{:ok, %Contact{}}`, now implemented over the new engine.

- [ ] **Step 1: Write the failing test**

Append to `test/kith/contacts_merge_test.exs`:

```elixir
  describe "merge_contacts/3 shim" do
    test "still honours non_survivor field choices", ctx do
      {:ok, survivor} =
        Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id, %{
          "company" => "non_survivor"
        })

      assert survivor.company == "New Corp"
    end

    test "fills a gap on the survivor from the loser", ctx do
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [middle_name: nil]
      )

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [middle_name: "Jo"]
      )

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert survivor.middle_name == "Jo"
    end

    test "never overrides an existing survivor value by default", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert survivor.company == "Old Corp"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith/contacts_merge_test.exs -k "shim"`
Expected: FAIL on the gap-filling test — the old engine leaves `middle_name` nil.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith/contacts.ex`, replace the whole `merge_contacts/3` function
(currently lines 1699–1866) and its now-unused private helpers
`update_survivor_fields/3`, `merge_last_talked_to/3`, `remap_relationships/3`,
`fetch_active_contact/1`, `validate_merge/2` and `most_recent_date/2` with:

```elixir
  @doc """
  Merges `non_survivor_id` into `survivor_id`.

  Retained for the existing wizard and REST API. `field_choices` uses the old
  `%{"field" => "survivor" | "non_survivor"}` shape; everything not named is
  resolved by `Kith.Contacts.MergeResolution`, which fills gaps on the survivor
  without overriding values it already has.
  """
  def merge_contacts(survivor_id, non_survivor_id, field_choices \\ %{}) do
    with {:ok, survivor} <- fetch_mergeable(survivor_id),
         {:ok, loser} <- fetch_mergeable(non_survivor_id) do
      scope = Kith.Accounts.Scope.for_account_id(survivor.account_id)
      resolution = MergeResolution.resolve([survivor, loser], survivor.id)
      fields = apply_legacy_choices(resolution.fields, survivor, loser, field_choices)

      merge_cluster(scope, survivor.id, [loser.id], %{fields: fields, drop: %{}})
    end
  end

  defp fetch_mergeable(id) do
    case Repo.get(Contact, id) do
      nil -> {:error, :not_found}
      %Contact{deleted_at: nil} = contact -> {:ok, contact}
      %Contact{} -> {:error, :trashed}
    end
  end

  defp apply_legacy_choices(fields, survivor, loser, choices) do
    Enum.reduce(choices, fields, fn {field_string, source}, acc ->
      field = String.to_existing_atom(field_string)

      if field in MergeFields.choice_fields() do
        contact = if source == "non_survivor", do: loser, else: survivor
        Map.put(acc, field, Map.fetch!(contact, field) || :clear)
      else
        acc
      end
    end)
  end
```

Add `MergeFields` and `MergeResolution` to the `Kith.Contacts.{...}` alias block.

`Kith.Accounts.Scope.for_account_id/1` does not exist yet. Add it to
`lib/kith/accounts/scope.ex`:

```elixir
  @doc """
  Builds a scope for background and adapter callers that have an account id but
  no user. `user` is nil, so callers needing an audit actor must supply one.
  """
  def for_account_id(account_id) do
    %__MODULE__{user: nil, account: Kith.Repo.get!(Kith.Accounts.Account, account_id)}
  end
```

Because `scope.user` may now be nil, guard the audit step in
`lib/kith/contacts/merge.ex` — replace the `:audit` step body's first line with:

```elixir
        if scope.user do
          AuditLogs.log_event(scope.account.id, scope.user, :contact_merged,
```

and close the `if` with `else {:ok, :skipped} end` around the existing call.

In `lib/kith_web/controllers/api/contact_controller.ex`, replace the body of
`merge/2` (line 218) so it uses the scope it already has:

```elixir
  def merge(conn, %{"survivor_id" => survivor_id, "non_survivor_id" => non_survivor_id}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    with true <- Policy.can?(user, :update, :contact),
         :ok <- validate_merge_ids(survivor_id, non_survivor_id),
         survivor when not is_nil(survivor) <- Contacts.get_contact(account_id, survivor_id),
         loser when not is_nil(loser) <- Contacts.get_contact(account_id, non_survivor_id),
         resolution = Kith.Contacts.MergeResolution.resolve([survivor, loser], survivor.id),
         {:ok, merged} <-
           Contacts.merge_cluster(scope, survivor.id, [loser.id], %{
             fields: resolution.fields,
             drop: %{}
           }) do
      json(conn, %{data: ContactJSON.data(merged)})
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, :same_ids} -> {:error, :bad_request, "Cannot merge a contact with itself."}
      {:error, reason} -> {:error, :bad_request, "Merge failed: #{inspect(reason)}"}
    end
  end
```

In `lib/kith_web/live/contact_live/merge.ex`, delete these two lines (currently
174–175) — pair resolution is now the engine's job, and the blanket dismissal is
Bug 2:

```elixir
        DuplicateDetection.dismiss_candidates_for_contact(account_id, contact_a.id)
        DuplicateDetection.dismiss_candidates_for_contact(account_id, contact_b.id)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test`
Expected: PASS across the whole suite. If `test/kith_web/live/contact_live/` has
a merge test asserting the old dismissal behaviour, update it to assert the new
rules from Task 8 instead.

- [ ] **Step 5: Commit**

```bash
mix format
mix credo --strict
mix test
git add lib/kith/contacts.ex lib/kith/accounts/scope.ex lib/kith/contacts/merge.ex lib/kith_web/controllers/api/contact_controller.ex lib/kith_web/live/contact_live/merge.ex test/
git commit -m "refactor(contacts): route legacy merge paths through the new engine"
```

---

## Slice 1 completion checklist

- [ ] `mix precommit` passes.
- [ ] Spec scenarios covered by this slice: D1–D10, F4, G1, G3, Bug 1, Bug 2.
- [ ] D9 (concurrent merges) has its locking implemented in Task 4 but no
      automated test — `FOR UPDATE` contention needs two connections, which the
      Ecto sandbox does not give us. Verify by hand: open two `iex -S mix`
      sessions against the dev database and call `merge_cluster/4` on
      overlapping clusters; the second must block, then fail validation on the
      now-trashed member rather than merging.
- [ ] No UI change is visible: the duplicates page and the merge wizard behave as
      before, except that merging no longer dismisses pairs the user never saw.

## Not in this slice

Slice 2 (clusters and the new screen) and slice 3 (manual merge and cleanup) are
separate plans. `list_clusters/2`, the negative-edge builder, the cluster
LiveView, contacts-index multi-select and the deletion of `ContactLive.Merge`
and `ContactLive.Duplicates` all belong there.
