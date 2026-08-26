defmodule Kith.Contacts.MergeResolutionTest do
  use Kith.DataCase, async: false

  import Ecto.Query

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

    test "a conflict tied on count and updated_at breaks toward the lowest member id", ctx do
      # candidates() groups by Map.group_by, whose resulting map iterates in
      # Erlang term order of the *values* (lexicographic for strings) —
      # independent of member-list order or member id. "Alpha" always sorts
      # ahead of "Zeta", so Enum.max_by/2's first-wins tie-break would hand a
      # tie to "Alpha" regardless of which member holds it. Assigning "Alpha"
      # to the higher-id member and "Zeta" to the lower-id one means that
      # picking the alphabetically-first value would give the WRONG (higher
      # id) winner — so only the explicit `-lowest_id` term in
      # default_value/2's sort key can make this assertion pass.
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Zeta"})
      b = contact(ctx.account_id, %{first_name: "Sarah", company: "Alpha"})

      # a is created first so a.id < b.id.
      assert a.id < b.id

      # Force identical updated_at so only the id tie-break can decide.
      same_time = DateTime.utc_now() |> DateTime.truncate(:second)

      a = a |> Ecto.Changeset.change(%{updated_at: same_time}) |> Repo.update!()
      b = b |> Ecto.Changeset.change(%{updated_at: same_time}) |> Repo.update!()

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.company == a.company
    end

    test "resolving a single member is a no-op copy", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", company: "Figma"})

      res = MergeResolution.resolve([a], a.id)

      assert res.fields.first_name == "Sarah"
      assert res.fields.company == "Figma"
      assert res.conflicts == %{}
    end
  end

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
      a =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          deceased: true,
          deceased_at: ~D[2024-05-01]
        })

      b =
        contact(ctx.account_id, %{
          first_name: "Sarah",
          deceased: true,
          deceased_at: ~D[2023-02-11]
        })

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

  describe "coupled date/flag resolution" do
    setup do
      Kith.ContactsFixtures.seed_reference_data!()
      user = Kith.AccountsFixtures.user_fixture()
      %{account_id: user.account_id}
    end

    test "the flag travels with the date that won", %{account_id: account_id} do
      known =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1985-04-12],
          birthdate_year_unknown: false
        })

      placeholder =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1900-04-12],
          birthdate_year_unknown: true
        })

      fields = MergeResolution.resolve([known, placeholder], known.id).fields

      # Whichever date the tie-break picked, its own flag must come with it.
      case fields.birthdate do
        ~D[1985-04-12] -> assert fields.birthdate_year_unknown == false
        ~D[1900-04-12] -> assert fields.birthdate_year_unknown == true
      end
    end

    test "gap-filling a date brings its flag along", %{account_id: account_id} do
      empty = Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: "A"})

      holder =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1900-06-15],
          birthdate_year_unknown: true
        })

      fields = MergeResolution.resolve([empty, holder], empty.id).fields

      assert fields.birthdate == ~D[1900-06-15]
      assert fields.birthdate_year_unknown == true
    end

    test "no member holds the date, so the flag is false rather than :clear",
         %{account_id: account_id} do
      a = Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: "A"})
      b = Kith.ContactsFixtures.contact_fixture(account_id, %{first_name: "A"})

      fields = MergeResolution.resolve([a, b], a.id).fields

      assert fields.birthdate == :clear
      assert fields.birthdate_year_unknown == false
      assert fields.first_met_at == :clear
      assert fields.first_met_year_unknown == false
    end

    test "members agreeing on the date but disagreeing on the flag keep the year unknown",
         %{account_id: account_id} do
      a =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1900-04-12],
          birthdate_year_unknown: true
        })

      b =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1900-04-12],
          birthdate_year_unknown: false
        })

      fields = MergeResolution.resolve([a, b], a.id).fields

      assert fields.birthdate == ~D[1900-04-12]
      assert fields.birthdate_year_unknown == true
    end

    test "the date still reports conflicts for the UI", %{account_id: account_id} do
      a =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1985-04-12]
        })

      b =
        Kith.ContactsFixtures.contact_fixture(account_id, %{
          first_name: "A",
          birthdate: ~D[1990-01-01]
        })

      resolution = MergeResolution.resolve([a, b], a.id)

      assert Map.has_key?(resolution.conflicts, :birthdate)
      assert length(resolution.conflicts.birthdate) == 2
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

    # ImmichSyncWorker sets immich_status: "needs_review" *without* an
    # immich_person_id, and it scans both duplicates — so this is the ordinary
    # state of a duplicate pair after a sync, not an edge case. No member counts
    # as linked, so the three nullable columns clear; the status must not clear
    # with them. Dropping the survivor to "unlinked" here would hide it from
    # `Contacts.list_needs_review/1` at the very moment
    # `:remap_immich_candidates` moved both members' pending suggestions onto
    # it, stranding those suggestions where no screen can reach them.
    #
    # `Kith.Contacts.Merge` still treats the Immich group as computed rather
    # than picked (see @computed_fields there): `:clear` is not a value any
    # member stores either.
    test "every member at needs_review with no person id stays needs_review", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah", immich_status: "needs_review"})
      b = contact(ctx.account_id, %{first_name: "Sarah", immich_status: "needs_review"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.immich_person_id == :clear
      assert res.fields.immich_person_url == :clear
      assert res.fields.immich_last_synced_at == :clear
      assert res.fields.immich_status == "needs_review"
    end

    test "needs_review beats unlinked when no member is linked", ctx do
      unlinked = contact(ctx.account_id, %{first_name: "Sarah", immich_status: "unlinked"})
      pending = contact(ctx.account_id, %{first_name: "Sarah", immich_status: "needs_review"})

      res = MergeResolution.resolve([unlinked, pending], unlinked.id)

      assert res.fields.immich_status == "needs_review"
    end

    test "all members unlinked stays unlinked", ctx do
      a = contact(ctx.account_id, %{first_name: "Sarah"})
      b = contact(ctx.account_id, %{first_name: "Sarah"})

      res = MergeResolution.resolve([a, b], a.id)

      assert res.fields.immich_status == "unlinked"
    end
  end
end
