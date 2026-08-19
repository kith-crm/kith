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
    # Two sources, and neither alone is enough: the changeset's required list
    # misses `NOT NULL` columns nothing validates (which reach the database as
    # `nil` and raise 23502), and the not-null set misses fields that are
    # nullable but still required by the changeset.
    test "covers the contact update changeset's required fields" do
      required =
        %Kith.Contacts.Contact{}
        |> Kith.Contacts.Contact.update_changeset(%{})
        |> Map.fetch!(:required)

      assert Enum.all?(required, &(&1 in MergeFields.non_clearable()))
    end

    test "covers every mergeable field backed by a not-null column" do
      assert Enum.all?(MergeFields.not_null_fields(), &MergeFields.non_clearable?/1)

      assert MergeFields.non_clearable?(:birthdate_year_unknown)
      assert MergeFields.non_clearable?(:first_met_year_unknown)
      assert MergeFields.non_clearable?(:immich_status)
    end

    test "first_name cannot be cleared" do
      assert MergeFields.non_clearable?(:first_name)
      refute MergeFields.non_clearable?(:nickname)
    end
  end
end
