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

    test "all/0 is the union of the five groups" do
      expected =
        MergeFields.choice_fields() ++
          MergeFields.policy_fields() ++
          MergeFields.array_fields() ++
          MergeFields.immich_fields() ++ MergeFields.coupled_flags()

      assert Enum.sort(MergeFields.all()) == Enum.sort(expected)
    end
  end

  describe "coupled_fields/0" do
    test "pairs each date with the flag describing it" do
      assert MergeFields.coupled_fields() == [
               {:birthdate, :birthdate_year_unknown},
               {:first_met_at, :first_met_year_unknown}
             ]
    end

    test "flags are not choice fields — they are never picked independently" do
      refute :birthdate_year_unknown in MergeFields.choice_fields()
      refute :first_met_year_unknown in MergeFields.choice_fields()
    end

    test "dates remain choice fields so the UI still shows their conflicts" do
      assert :birthdate in MergeFields.choice_fields()
      assert :first_met_at in MergeFields.choice_fields()
    end

    test "all/0 still covers every mergeable column" do
      assert :birthdate_year_unknown in MergeFields.all()
      assert :first_met_year_unknown in MergeFields.all()
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
