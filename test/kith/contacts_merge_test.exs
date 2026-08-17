defmodule Kith.Contacts.MergeTest do
  use Kith.DataCase

  alias Kith.Contacts
  alias Kith.ContactsFixtures
  alias Kith.AccountsFixtures

  setup do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    account_id = user.account_id

    contact_a =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Alice",
        last_name: "Smith",
        company: "Old Corp",
        occupation: "Designer"
      })

    contact_b =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Alice",
        last_name: "S.",
        company: "New Corp",
        occupation: nil
      })

    %{user: user, account_id: account_id, contact_a: contact_a, contact_b: contact_b}
  end

  describe "merge_contacts/3" do
    test "merges contacts with default field choices (keep survivor)", ctx do
      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      survivor = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      non_survivor = Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id)

      # Survivor unchanged (default choices = keep survivor)
      assert survivor.first_name == "Alice"
      assert survivor.last_name == "Smith"
      assert survivor.company == "Old Corp"

      # Non-survivor soft-deleted
      assert non_survivor.deleted_at != nil
    end

    test "applies field_choices to survivor", ctx do
      field_choices = %{"company" => "non_survivor", "occupation" => "non_survivor"}

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id, field_choices)

      survivor = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      assert survivor.company == "New Corp"
      # Non-survivor has nil occupation, so survivor gets nil
      assert survivor.occupation == nil
    end

    test "remaps notes from non-survivor to survivor", ctx do
      _note_a =
        ContactsFixtures.note_fixture(ctx.contact_a, ctx.user.id, %{"body" => "<p>Note A</p>"})

      _note_b =
        ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id, %{"body" => "<p>Note B</p>"})

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      # Both notes now belong to survivor
      notes = Repo.all(from(n in Kith.Contacts.Note, where: n.contact_id == ^ctx.contact_a.id))
      assert length(notes) == 2
      note_bodies = Enum.map(notes, & &1.body)
      assert "<p>Note A</p>" in note_bodies
      assert "<p>Note B</p>" in note_bodies

      # No notes on non-survivor
      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^ctx.contact_b.id),
               :count
             ) == 0
    end

    test "remaps addresses from non-survivor to survivor", ctx do
      ContactsFixtures.address_fixture(ctx.contact_a, %{"label" => "Home", "line1" => "111 A St"})
      ContactsFixtures.address_fixture(ctx.contact_b, %{"label" => "Work", "line1" => "222 B St"})

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      addresses =
        Repo.all(from(a in Kith.Contacts.Address, where: a.contact_id == ^ctx.contact_a.id))

      assert length(addresses) == 2
    end

    test "deduplicates tags during merge", ctx do
      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "family", "color" => "#FF0000"})

      Contacts.tag_contact(ctx.contact_a, tag)
      Contacts.tag_contact(ctx.contact_b, tag)

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      # Survivor should have exactly 1 "family" tag (not 2)
      tags =
        Repo.all(
          from(ct in "contact_tags",
            where: ct.contact_id == ^ctx.contact_a.id,
            select: ct.tag_id
          )
        )

      assert length(tags) == 1
      assert hd(tags) == tag.id
    end

    test "merges unique tags from non-survivor", ctx do
      {:ok, tag_a} =
        Contacts.create_tag(ctx.account_id, %{"name" => "work", "color" => "#0000FF"})

      {:ok, tag_b} = Contacts.create_tag(ctx.account_id, %{"name" => "gym", "color" => "#00FF00"})

      Contacts.tag_contact(ctx.contact_a, tag_a)
      Contacts.tag_contact(ctx.contact_b, tag_b)

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      tags =
        Repo.all(
          from(ct in "contact_tags",
            where: ct.contact_id == ^ctx.contact_a.id,
            select: ct.tag_id
          )
        )

      assert length(tags) == 2
      assert tag_a.id in tags
      assert tag_b.id in tags
    end

    test "deduplicates relationships during merge", ctx do
      contact_c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Charlie", last_name: "X"})

      [friend_type | _] = Repo.all(from(rt in "relationship_types", select: rt.id, limit: 1))

      ContactsFixtures.relationship_fixture(ctx.contact_a, contact_c, friend_type)
      ContactsFixtures.relationship_fixture(ctx.contact_b, contact_c, friend_type)

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      # Only one "Friend of Charlie" relationship should remain
      rels =
        Repo.all(
          from(r in Kith.Contacts.Relationship,
            where: r.contact_id == ^ctx.contact_a.id and r.related_contact_id == ^contact_c.id
          )
        )

      assert length(rels) == 1
    end

    test "removes self-referential relationships after merge", ctx do
      [friend_type | _] = Repo.all(from(rt in "relationship_types", select: rt.id, limit: 1))

      # B has a relationship pointing to A — after merge, this would become A -> A
      ContactsFixtures.relationship_fixture(ctx.contact_b, ctx.contact_a, friend_type)

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      self_rels =
        Repo.all(
          from(r in Kith.Contacts.Relationship,
            where: r.contact_id == ^ctx.contact_a.id and r.related_contact_id == ^ctx.contact_a.id
          )
        )

      assert self_rels == []
    end

    test "preserves different-type relationships to same contact", ctx do
      contact_c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Charlie", last_name: "Y"})

      [friend_type, parent_type] =
        Repo.all(from(rt in "relationship_types", select: rt.id, limit: 2, order_by: rt.id))

      ContactsFixtures.relationship_fixture(ctx.contact_a, contact_c, friend_type)
      ContactsFixtures.relationship_fixture(ctx.contact_b, contact_c, parent_type)

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      rels =
        Repo.all(
          from(r in Kith.Contacts.Relationship,
            where: r.contact_id == ^ctx.contact_a.id and r.related_contact_id == ^contact_c.id
          )
        )

      assert length(rels) == 2
    end

    test "updates last_talked_to to more recent value", ctx do
      old_date = ~U[2024-01-01 00:00:00Z]
      new_date = ~U[2025-06-15 00:00:00Z]

      ctx.contact_a
      |> Ecto.Changeset.change(%{last_talked_to: old_date})
      |> Repo.update!()

      ctx.contact_b
      |> Ecto.Changeset.change(%{last_talked_to: new_date})
      |> Repo.update!()

      {:ok, _result} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      survivor = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      assert survivor.last_talked_to == new_date
    end

    test "rejects merge of same contact", ctx do
      result = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_a.id)
      assert result == {:error, :same_contact}
    end

    test "rejects merge of contacts from different accounts", ctx do
      other_user = AccountsFixtures.user_fixture()

      other_contact =
        ContactsFixtures.contact_fixture(other_user.account_id, %{first_name: "Other"})

      result = Contacts.merge_contacts(ctx.contact_a.id, other_contact.id)
      assert result == {:error, :different_accounts}
    end

    test "rejects merge of trashed contact", ctx do
      ctx.contact_b
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
      |> Repo.update!()

      result = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)
      assert result == {:error, :trashed}
    end
  end

  describe "merge_preview/2" do
    test "returns counts of sub-entities to be merged", ctx do
      ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)
      ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)
      ContactsFixtures.address_fixture(ctx.contact_b)

      {:ok, preview} = Contacts.merge_preview(ctx.contact_a.id, ctx.contact_b.id)

      assert preview.notes == 2
      assert preview.addresses == 1
      assert preview.calls == 0
      assert preview.life_events == 0
    end

    test "identifies duplicate relationships", ctx do
      contact_c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Charlie", last_name: "Z"})

      [friend_type | _] = Repo.all(from(rt in "relationship_types", select: rt.id, limit: 1))

      ContactsFixtures.relationship_fixture(ctx.contact_a, contact_c, friend_type)
      ContactsFixtures.relationship_fixture(ctx.contact_b, contact_c, friend_type)

      {:ok, preview} = Contacts.merge_preview(ctx.contact_a.id, ctx.contact_b.id)

      assert preview.relationships_to_dedup >= 1
    end
  end

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
end
