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
