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

    test "rejects a nonexistent loser id", ctx do
      assert {:error, :not_found} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [-1],
                 resolution()
               )
    end

    test "wraps a changeset failure as {:invalid_fields, changeset}", ctx do
      # contact_b already references the survivor as first_met_through; resolving
      # to that value passes held_by_member?/3, but applying it to the survivor
      # is a self-reference, which Contact.update_changeset/2 rejects.
      {:ok, _} =
        ctx.contact_b
        |> Ecto.Changeset.change(%{first_met_through_id: ctx.contact_a.id})
        |> Repo.update()

      assert {:error, {:invalid_fields, %Ecto.Changeset{} = changeset}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{first_met_through_id: ctx.contact_a.id})
               )

      assert %{first_met_through_id: ["cannot reference the contact itself"]} =
               errors_on(changeset)
    end

    test "a rejected merge leaves the database unchanged", ctx do
      before_a = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      before_b = Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id)

      assert {:error, {:unknown_value, :company}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{company: "Never Corp"})
               )

      after_a = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      after_b = Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id)

      assert after_a == before_a
      assert after_b == before_b
      assert after_a.deleted_at == nil
      assert after_b.deleted_at == nil
    end
  end

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
        creator_id: ctx.user.id,
        title: "Loan",
        amount: Decimal.new("25.00"),
        direction: "owed_to_me",
        status: "active"
      })

      Repo.insert!(%Kith.Contacts.Gift{
        account_id: account_id,
        contact_id: loser_id,
        creator_id: ctx.user.id,
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
        creator_id: ctx.user.id,
        title: "Call back"
      })

      Repo.insert!(%Kith.Conversations.Conversation{
        account_id: account_id,
        contact_id: loser_id,
        creator_id: ctx.user.id,
        subject: "Catch up"
      })

      Repo.insert!(%Kith.Contacts.ImmichCandidate{
        account_id: account_id,
        contact_id: loser_id,
        immich_photo_id: "photo-1",
        immich_server_url: "https://immich.example.com",
        thumbnail_url: "https://immich.example.com/thumb/1",
        suggested_at: DateTime.utc_now(:second)
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

    test "deduplicates colliding tags and moves unique ones (contact_tags has no schema)", ctx do
      {:ok, shared_tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "shared", "color" => "#FF0000"})

      {:ok, unique_tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "unique", "color" => "#00FF00"})

      Contacts.tag_contact(ctx.contact_a, shared_tag)
      Contacts.tag_contact(ctx.contact_b, shared_tag)
      Contacts.tag_contact(ctx.contact_b, unique_tag)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      tag_ids =
        Repo.all(
          from(ct in "contact_tags", where: ct.contact_id == ^survivor.id, select: ct.tag_id)
        )

      assert Enum.sort(tag_ids) == Enum.sort([shared_tag.id, unique_tag.id])

      assert Repo.aggregate(
               from(ct in "contact_tags", where: ct.contact_id == ^ctx.contact_b.id),
               :count
             ) == 0
    end

    test "drops a loser photo colliding with the survivor's content_hash instead of raising",
         ctx do
      Repo.insert!(%Kith.Contacts.Photo{
        account_id: ctx.account_id,
        contact_id: ctx.contact_a.id,
        creator_id: ctx.user.id,
        file_name: "a.jpg",
        storage_key: "keys/a.jpg",
        file_size: 100,
        content_type: "image/jpeg",
        content_hash: "same-hash"
      })

      Repo.insert!(%Kith.Contacts.Photo{
        account_id: ctx.account_id,
        contact_id: ctx.contact_b.id,
        creator_id: ctx.user.id,
        file_name: "b.jpg",
        storage_key: "keys/b.jpg",
        file_size: 100,
        content_type: "image/jpeg",
        content_hash: "same-hash"
      })

      Repo.insert!(%Kith.Contacts.Photo{
        account_id: ctx.account_id,
        contact_id: ctx.contact_b.id,
        creator_id: ctx.user.id,
        file_name: "c.jpg",
        storage_key: "keys/c.jpg",
        file_size: 200,
        content_type: "image/jpeg",
        content_hash: "different-hash"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      survivor_hashes =
        Repo.all(
          from(p in Kith.Contacts.Photo,
            where: p.contact_id == ^survivor.id,
            select: p.content_hash
          )
        )

      assert Enum.sort(survivor_hashes) == Enum.sort(["same-hash", "different-hash"])

      assert Repo.aggregate(
               from(p in Kith.Contacts.Photo, where: p.contact_id == ^ctx.contact_b.id),
               :count
             ) == 0
    end

    test "dedupes collisions between two losers, not just loser-vs-survivor", ctx do
      now = DateTime.utc_now(:second)

      contact_c =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Carol"})

      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "duplicate", "color" => "#123456"})

      # Survivor holds none of these — only the two losers collide with each other.
      Contacts.tag_contact(ctx.contact_b, tag)
      Contacts.tag_contact(contact_c, tag)

      {1, [%{id: activity_id}]} =
        Repo.insert_all(
          "activities",
          [
            %{
              account_id: ctx.account_id,
              title: "Group hang",
              occurred_at: now,
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: [:id]
        )

      Repo.insert_all("activity_contacts", [
        %{activity_id: activity_id, contact_id: ctx.contact_b.id},
        %{activity_id: activity_id, contact_id: contact_c.id}
      ])

      Repo.insert!(%Kith.Contacts.Photo{
        account_id: ctx.account_id,
        contact_id: ctx.contact_b.id,
        creator_id: ctx.user.id,
        file_name: "b.jpg",
        storage_key: "keys/b.jpg",
        file_size: 100,
        content_type: "image/jpeg",
        content_hash: "shared-hash"
      })

      Repo.insert!(%Kith.Contacts.Photo{
        account_id: ctx.account_id,
        contact_id: contact_c.id,
        creator_id: ctx.user.id,
        file_name: "c.jpg",
        storage_key: "keys/c.jpg",
        file_size: 100,
        content_type: "image/jpeg",
        content_hash: "shared-hash"
      })

      Repo.insert!(%Kith.Contacts.ImmichCandidate{
        account_id: ctx.account_id,
        contact_id: ctx.contact_b.id,
        immich_photo_id: "shared-photo",
        immich_server_url: "https://immich.example.com",
        thumbnail_url: "https://immich.example.com/thumb/shared",
        suggested_at: now
      })

      Repo.insert!(%Kith.Contacts.ImmichCandidate{
        account_id: ctx.account_id,
        contact_id: contact_c.id,
        immich_photo_id: "shared-photo",
        immich_server_url: "https://immich.example.com",
        thumbnail_url: "https://immich.example.com/thumb/shared",
        suggested_at: now
      })

      assert {:ok, survivor} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id, contact_c.id],
                 %{fields: %{}, drop: %{}}
               )

      assert Repo.aggregate(
               from(ct in "contact_tags",
                 where: ct.contact_id == ^survivor.id and ct.tag_id == ^tag.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(ac in "activity_contacts",
                 where: ac.activity_id == ^activity_id and ac.contact_id == ^survivor.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(p in Kith.Contacts.Photo,
                 where: p.contact_id == ^survivor.id and p.content_hash == "shared-hash"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(ic in Kith.Contacts.ImmichCandidate,
                 where: ic.contact_id == ^survivor.id and ic.immich_photo_id == "shared-photo"
               ),
               :count
             ) == 1
    end

    test "keeps the survivor's birthday reminder and drops colliding loser ones", ctx do
      birthday_a =
        Kith.RemindersFixtures.birthday_reminder_fixture(
          ctx.account_id,
          ctx.contact_a.id,
          ctx.user.id
        )

      birthday_b =
        Kith.RemindersFixtures.birthday_reminder_fixture(
          ctx.account_id,
          ctx.contact_b.id,
          ctx.user.id
        )

      Kith.RemindersFixtures.reminder_instance_fixture(birthday_b)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      remaining =
        Repo.all(
          from(r in Kith.Reminders.Reminder,
            where: r.type == "birthday" and r.contact_id == ^survivor.id
          )
        )

      assert [%{id: id}] = remaining
      assert id == birthday_a.id
      assert Repo.get(Kith.Reminders.Reminder, birthday_b.id) == nil

      assert Repo.aggregate(
               from(ri in Kith.Reminders.ReminderInstance,
                 where: ri.reminder_id == ^birthday_b.id
               ),
               :count
             ) == 0
    end

    test "when only losers have birthday reminders, keeps the lowest-id one", ctx do
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Carol"})

      birthday_b =
        Kith.RemindersFixtures.birthday_reminder_fixture(
          ctx.account_id,
          ctx.contact_b.id,
          ctx.user.id
        )

      _birthday_c =
        Kith.RemindersFixtures.birthday_reminder_fixture(ctx.account_id, c.id, ctx.user.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
          fields: %{},
          drop: %{}
        })

      remaining =
        Repo.all(
          from(r in Kith.Reminders.Reminder,
            where: r.type == "birthday" and r.contact_id == ^survivor.id
          )
        )

      assert [%{id: id}] = remaining
      assert id == birthday_b.id
    end

    test "moves reminders, reminder_instances, documents, calls and life_events", ctx do
      loser_id = ctx.contact_b.id

      reminder =
        Kith.RemindersFixtures.recurring_reminder_fixture(ctx.account_id, loser_id, ctx.user.id)

      Kith.RemindersFixtures.reminder_instance_fixture(reminder)
      Kith.ContactsFixtures.document_fixture(ctx.contact_b)

      Repo.insert!(%Kith.Activities.Call{
        account_id: ctx.account_id,
        contact_id: loser_id,
        occurred_at: DateTime.utc_now(:second)
      })

      [life_event_type_id] =
        Repo.all(from(t in "life_event_types", select: t.id, limit: 1))

      Repo.insert!(%Kith.Activities.LifeEvent{
        account_id: ctx.account_id,
        contact_id: loser_id,
        occurred_on: Date.utc_today(),
        life_event_type_id: life_event_type_id
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [loser_id], %{
          fields: %{},
          drop: %{}
        })

      for schema <- [
            Kith.Reminders.Reminder,
            Kith.Reminders.ReminderInstance,
            Kith.Contacts.Document,
            Kith.Activities.Call,
            Kith.Activities.LifeEvent
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
  end

  describe "merge_cluster/4 deduplication" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)

      email_type =
        Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      %{scope: scope, email_type: email_type}
    end

    test "identical contact fields collapse to one", ctx do
      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
        "value" => "sarah@example.com"
      })

      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
        "value" => "sarah@example.com"
      })

      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
        "value" => "other@example.com"
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

    test "contact fields differing only by case and whitespace collapse to one", ctx do
      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
        "value" => "Sarah@Example.com "
      })

      Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
        "value" => "sarah@example.com"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      count =
        Repo.aggregate(
          from(f in Kith.Contacts.ContactField, where: f.contact_id == ^survivor.id),
          :count
        )

      assert count == 1
    end

    test "addresses differing only by case and whitespace collapse to one, distinct address kept",
         ctx do
      Kith.ContactsFixtures.address_fixture(ctx.contact_a, %{
        "line1" => " 123 Main St ",
        "postal_code" => "62701"
      })

      Kith.ContactsFixtures.address_fixture(ctx.contact_b, %{
        "line1" => "123 MAIN ST",
        "postal_code" => " 62701 "
      })

      Kith.ContactsFixtures.address_fixture(ctx.contact_b, %{
        "line1" => "456 Other Ave",
        "postal_code" => "10001"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      lines =
        from(a in Kith.Contacts.Address, where: a.contact_id == ^survivor.id, select: a.line1)
        |> Repo.all()
        |> Enum.sort()

      assert lines == [" 123 Main St ", "456 Other Ave"]
    end

    test "a tag on both members is kept once", ctx do
      {:ok, tag} = Contacts.create_tag(ctx.account_id, %{name: "Design"})
      Contacts.tag_contact(ctx.contact_a, tag)
      Contacts.tag_contact(ctx.contact_b, tag)

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

    test "a relationship between two losers is removed, not self-referential", ctx do
      # Neither end is the survivor here — both contact_b and c are losers,
      # so this only exercises the "both endpoints are cluster members"
      # cleanup, not the loser-vs-survivor path already covered above.
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Carol"})
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(ctx.contact_b, c, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
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

    test "two losers holding the same forward relationship to a third contact collapse to one",
         ctx do
      # contact_b -> third and c -> third, same type, same direction. The
      # survivor holds neither, so a plain survivor-vs-loser collision check
      # would miss this and the blanket move would violate the unique index.
      third = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Third"})
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Carol"})
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(ctx.contact_b, third, type.id)
      Kith.ContactsFixtures.relationship_fixture(c, third, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(r in Kith.Contacts.Relationship,
                 where:
                   r.contact_id == ^survivor.id and r.related_contact_id == ^third.id and
                     r.relationship_type_id == ^type.id
               ),
               :count
             ) == 1
    end

    test "two losers holding the same reverse relationship from a third contact collapse to one",
         ctx do
      # third -> contact_b and third -> c, same type, same direction — the
      # mirror of the previous case on the related_contact_id side.
      third = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Third"})
      c = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Carol"})
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(third, ctx.contact_b, type.id)
      Kith.ContactsFixtures.relationship_fixture(third, c, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id, c.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(r in Kith.Contacts.Relationship,
                 where:
                   r.related_contact_id == ^survivor.id and r.contact_id == ^third.id and
                     r.relationship_type_id == ^type.id
               ),
               :count
             ) == 1
    end

    test "a loser's forward relationship colliding with the survivor's own is dropped, not moved",
         ctx do
      # contact_a (survivor) -> third already exists; contact_b (loser) holds
      # the identical (related_contact_id, type) pair. Exercises the
      # `o.contact_id = $2` branch specifically, distinct from the two-loser
      # collision tests above.
      third = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Third"})
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(ctx.contact_a, third, type.id)
      Kith.ContactsFixtures.relationship_fixture(ctx.contact_b, third, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(r in Kith.Contacts.Relationship,
                 where:
                   r.contact_id == ^survivor.id and r.related_contact_id == ^third.id and
                     r.relationship_type_id == ^type.id
               ),
               :count
             ) == 1
    end

    test "a loser's reverse relationship colliding with the survivor's own is dropped, not moved",
         ctx do
      # third -> contact_a (survivor) already exists; third -> contact_b
      # (loser) holds the identical pair. Exercises the
      # `o.related_contact_id = $2` branch specifically.
      third = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Third"})
      type = Repo.one!(from(t in Kith.Contacts.RelationshipType, limit: 1))
      Kith.ContactsFixtures.relationship_fixture(third, ctx.contact_a, type.id)
      Kith.ContactsFixtures.relationship_fixture(third, ctx.contact_b, type.id)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      assert Repo.aggregate(
               from(r in Kith.Contacts.Relationship,
                 where:
                   r.related_contact_id == ^survivor.id and r.contact_id == ^third.id and
                     r.relationship_type_id == ^type.id
               ),
               :count
             ) == 1
    end
  end
end
