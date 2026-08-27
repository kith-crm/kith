defmodule Kith.Contacts.MergeTest do
  use Kith.DataCase
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Contacts
  alias Kith.ContactsFixtures
  alias Kith.AccountsFixtures

  import Kith.RemindersFixtures

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

  # Enqueues a real notification job for `reminder` and records it the way
  # Reminders.enqueue_jobs_for_reminder/2 would.
  defp notification_job!(reminder) do
    {:ok, job} =
      Oban.insert(
        Kith.Workers.ReminderNotificationWorker.new(%{
          reminder_id: reminder.id,
          type: "on_day",
          days_before: 0
        })
      )

    Repo.update_all(
      from(r in Kith.Reminders.Reminder, where: r.id == ^reminder.id),
      set: [enqueued_oban_job_ids: [job.id]]
    )

    job
  end

  # The 3-arity call the wizard actually makes — `field_choices` starts empty
  # and gains one entry per click. apply_legacy_choices/4 resolves each field
  # independently (a per-field reduce over `choices`), so it cannot reproduce
  # the wizard's lost-gap-fill bug itself: that one lives in the LiveView's own
  # `default_field_choices/0` / `effective_choice/4` and is
  # covered by test/kith_web/live/contact_live/merge_test.exs. The tests
  # below instead pin a narrower invariant: an unrelated explicit choice must
  # never disturb the resolution of a field the user didn't touch.
  defp wizard_merge(survivor_id, loser_id, clicked) do
    Contacts.merge_contacts(survivor_id, loser_id, clicked)
  end

  # A contact in a different account, used to force a changeset failure on the
  # survivor that D4's coercion does not pre-empt.
  defp foreign_contact do
    other_account_id = AccountsFixtures.user_fixture().account_id
    ContactsFixtures.contact_fixture(other_account_id, %{first_name: "Stranger"})
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

    test "fills a gap on the survivor from the loser through the wizard path", ctx do
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [middle_name: nil]
      )

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [middle_name: "Jo"]
      )

      # Pins wizard_merge/3's narrow invariant: the user clicked one unrelated
      # field, so middle_name must still gap-fill even though `choices` isn't
      # empty.
      {:ok, survivor} =
        wizard_merge(ctx.contact_a.id, ctx.contact_b.id, %{"company" => "non_survivor"})

      assert survivor.middle_name == "Jo"
      assert survivor.company == "New Corp"
    end

    test "never overrides an existing survivor value by default", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert survivor.company == "Old Corp"
    end

    test "never overrides an existing survivor value through the wizard path", ctx do
      # Pins wizard_merge/3's narrow invariant: company was never touched, so
      # the survivor-value protection must still hold for it.
      {:ok, survivor} =
        wizard_merge(ctx.contact_a.id, ctx.contact_b.id, %{"occupation" => "survivor"})

      assert survivor.company == "Old Corp"
    end

    test "keeps the survivor's value even when the loser was updated later", ctx do
      # The resolver's conflict default is most-held, then most-recently-updated.
      # Make the loser unambiguously newer so only the survivor-value protection
      # can keep "Old Corp".
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)]
      )

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert survivor.company == "Old Corp"
    end

    test "keeps the survivor's value even when the loser was updated later, through the wizard path",
         ctx do
      # Same conflict-default scenario as above, run with an unrelated field
      # clicked. Pins wizard_merge/3's narrow invariant, not the wizard's
      # lost-gap-fill bug — apply_legacy_choices/4 resolves each field
      # independently, so that gap cannot occur here.
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)]
      )

      {:ok, survivor} =
        wizard_merge(ctx.contact_a.id, ctx.contact_b.id, %{"occupation" => "survivor"})

      assert survivor.company == "Old Corp"
    end

    test "ignores an unrecognised field key instead of crashing", ctx do
      {:ok, survivor} =
        Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id, %{
          "definitely_not_a_field" => "non_survivor",
          "company" => "non_survivor"
        })

      assert survivor.company == "New Corp"
    end

    test "an explicit survivor choice still empties a field the survivor lacks", ctx do
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [middle_name: nil]
      )

      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [middle_name: "Jo"]
      )

      {:ok, survivor} =
        Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id, %{
          "middle_name" => "survivor"
        })

      assert survivor.middle_name == nil
    end

    test "clears first_met_through rather than pointing at the trashed loser", ctx do
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert survivor.first_met_through_id == nil
    end

    test "clears first_met_through rather than pointing at the trashed loser, through the wizard path",
         ctx do
      # Same D4 self-reference clearing as above, run with an unrelated field
      # clicked. Pins wizard_merge/3's narrow invariant, not the wizard's
      # lost-gap-fill bug.
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      {:ok, survivor} =
        wizard_merge(ctx.contact_a.id, ctx.contact_b.id, %{"occupation" => "survivor"})

      assert survivor.first_met_through_id == nil
    end

    test "an explicit \"survivor\" choice cannot keep a pointer at the loser", ctx do
      # apply_legacy_choices/4 overrides the resolver's :clear with the
      # survivor's raw value, which here is the loser's id — routing around
      # MergeResolution.clear_self_reference/2 entirely. Only the engine's own
      # D4 enforcement catches this.
      Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      {:ok, survivor} =
        Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id, %{
          "first_met_through_id" => "survivor"
        })

      assert survivor.first_met_through_id == nil
      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id).first_met_through_id == nil
    end

    test "restoring the survivor's birthdate restores its flag too", %{account_id: account_id} do
      survivor =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-04-12],
          birthdate_year_unknown: false
        })

      loser =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1900-04-12],
          birthdate_year_unknown: true
        })

      fields = Contacts.legacy_resolution_fields(survivor, loser)

      assert fields.birthdate == ~D[1985-04-12]
      assert fields.birthdate_year_unknown == false
    end

    test "gap-filling the survivor's empty birthdate keeps the loser's flag",
         %{account_id: account_id} do
      survivor = ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})

      loser =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1900-06-15],
          birthdate_year_unknown: true
        })

      fields = Contacts.legacy_resolution_fields(survivor, loser)

      assert fields.birthdate == ~D[1900-06-15]
      assert fields.birthdate_year_unknown == true
    end

    test "an explicit birthdate choice carries that contact's flag",
         %{account_id: account_id} do
      survivor =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-04-12],
          birthdate_year_unknown: false
        })

      loser =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1900-04-12],
          birthdate_year_unknown: true
        })

      assert {:ok, merged} =
               Contacts.merge_contacts(survivor.id, loser.id, %{"birthdate" => "non_survivor"})

      assert merged.birthdate == ~D[1900-04-12]
      assert merged.birthdate_year_unknown == true
    end

    test "a choice naming a boolean flag directly is ignored, not a crash",
         %{contact_a: contact_a, contact_b: contact_b} do
      # `birthdate_year_unknown` is `null: false`; the wizard's "choose-field"
      # event passes the raw client string with no allowlist, so this must not
      # reach the merge as a NULL write.
      assert {:ok, merged} =
               Contacts.merge_contacts(contact_a.id, contact_b.id, %{
                 "birthdate_year_unknown" => "non_survivor"
               })

      assert merged.birthdate_year_unknown == false
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

    # `:clear` becomes `nil` at the database, so a `NOT NULL` column raises
    # SQLSTATE 23502 — outside this engine's `{:error, reason}` contract.
    # `birthdate_year_unknown` is `null: false` but named by no
    # `validate_required/2`, so only the schema itself can rule it out. The
    # screen is one caller; the contract is what slice 3 and the API lean on.
    test "rejects clearing a not-null column that no changeset marks required", ctx do
      assert {:error, {:not_clearable, :birthdate_year_unknown}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{birthdate_year_unknown: :clear})
               )

      assert {:error, {:not_clearable, :first_met_year_unknown}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{first_met_year_unknown: :clear})
               )

      # Rejected before anything is written.
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at == nil
    end

    # Guards the derivation itself: every mergeable field backed by a NOT NULL
    # column must be non-clearable, so a column added with `null: false` later
    # cannot quietly become clearable.
    test "every not-null contacts column is reported non-clearable" do
      %{rows: rows} =
        Kith.Repo.query!("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'contacts' AND is_nullable = 'NO'
        """)

      names = rows |> List.flatten() |> MapSet.new()

      not_null_mergeable =
        Enum.filter(Kith.Contacts.MergeFields.all(), &MapSet.member?(names, Atom.to_string(&1)))

      assert :birthdate_year_unknown in not_null_mergeable
      assert :first_met_year_unknown in not_null_mergeable

      for field <- not_null_mergeable do
        assert Kith.Contacts.MergeFields.non_clearable?(field),
               "#{field} is NOT NULL in the database but is offered as clearable"
      end

      # Nullable fields are still clearable — this is not a blanket refusal.
      refute Kith.Contacts.MergeFields.non_clearable?(:occupation)
      refute Kith.Contacts.MergeFields.non_clearable?(:deceased_at)
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
      # contact_b references a contact in a *different* account as
      # first_met_through (written straight to the column, which is the only way
      # such a pointer could exist). Resolving to that value passes
      # held_by_member?/3 — a member holds it — but applying it to the survivor
      # is rejected by Contact.update_changeset/2. A pointer at a merged member
      # cannot serve as the injection here: the engine coerces that to nil
      # before validation (design spec D4).
      stranger = foreign_contact()

      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [first_met_through_id: stranger.id]
      )

      assert {:error, {:invalid_fields, %Ecto.Changeset{} = changeset}} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{first_met_through_id: stranger.id})
               )

      assert %{first_met_through_id: ["must be a contact in the same account"]} =
               errors_on(changeset)
    end

    test "clears a first_met_through_id pointing at a merged member (D4)", ctx do
      # The survivor genuinely holds this value, so validate_fields/2 accepts it
      # and apply_fields/2 writes it — and then :remap_inbound_first_met rewrites
      # every pointer at a loser to the survivor, turning it into a
      # self-reference. The engine coerces the value to nil instead.
      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      assert {:ok, survivor} =
               Contacts.merge_cluster(
                 ctx.scope,
                 ctx.contact_a.id,
                 [ctx.contact_b.id],
                 resolution(%{first_met_through_id: ctx.contact_b.id})
               )

      assert survivor.first_met_through_id == nil
      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id).first_met_through_id == nil
    end

    test "merges a cluster whose every member is at immich needs_review", ctx do
      # ImmichSyncWorker sets needs_review without an immich_person_id and scans
      # both duplicates, so this is the ordinary post-sync state of a duplicate
      # pair. The resolver clears the three nullable Immich columns — `:clear`
      # is a value no member stores — so the merge must accept the group as
      # computed rather than halting with {:unknown_value, :immich_person_id}.
      # The status itself must survive at needs_review: the survivor has just
      # absorbed both members' pending candidate rows and has to stay visible
      # to `Contacts.list_needs_review/1`.
      Repo.update_all(
        from(c in Kith.Contacts.Contact,
          where: c.id in ^[ctx.contact_a.id, ctx.contact_b.id]
        ),
        set: [immich_status: "needs_review", immich_person_id: nil]
      )

      a = Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id)
      b = Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id)
      fields = Kith.Contacts.MergeResolution.resolve([a, b], a.id).fields

      assert fields.immich_person_id == :clear
      assert fields.immich_status == "needs_review"

      assert {:ok, survivor} =
               Contacts.merge_cluster(ctx.scope, a.id, [b.id], %{fields: fields, drop: %{}})

      assert survivor.immich_status == "needs_review"
      assert is_nil(survivor.immich_person_id)
      assert Repo.get!(Kith.Contacts.Contact, b.id).deleted_at != nil
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

    test "returns an error for a field key that is not a contact field", ctx do
      assert {:error, {:unknown_field, :not_a_real_field}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{not_a_real_field: "whatever"},
                 drop: %{},
                 unchecked_ids: []
               })
    end

    test "rejects an unknown field even when its value is :clear", ctx do
      # :clear alone is not proof the field is known — an unrecognised field
      # carrying :clear must not slip through the `value == :clear` branch
      # before the known?/1 guard has a chance to reject it.
      assert {:error, {:unknown_field, :not_a_real_field}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{not_a_real_field: :clear},
                 drop: %{},
                 unchecked_ids: []
               })
    end
  end

  describe "merge_cluster/4 remapping" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)
      %{scope: scope}
    end

    test "import records follow the survivor", ctx do
      import_job = Kith.ImportsFixtures.import_fixture(ctx.account_id, ctx.user.id)

      {:ok, record} =
        %Kith.Imports.ImportRecord{}
        |> Kith.Imports.ImportRecord.changeset(%{
          source: "monica_api",
          source_entity_type: "contact",
          source_entity_id: "42",
          local_entity_type: "contact",
          local_entity_id: ctx.contact_b.id,
          account_id: ctx.account_id,
          import_id: import_job.id
        })
        |> Repo.insert()

      assert {:ok, _merged} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{},
                 drop: %{}
               })

      assert Repo.reload!(record).local_entity_id == ctx.contact_a.id
    end

    test "a partial resolution cannot leave the survivor met through itself", ctx do
      # A field map that omits :first_met_through_id entirely — the shape the
      # cluster screen can produce. clear_member_self_reference/2 is a no-op
      # here, so the guard has to live in the remap step itself.
      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_a.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      assert {:ok, merged} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{first_name: "Alice"},
                 drop: %{}
               })

      refute merged.first_met_through_id == merged.id
      assert merged.first_met_through_id == ctx.contact_b.id
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

    test "cancels the Oban jobs of the birthday reminders it deletes", ctx do
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

      kept_job = notification_job!(birthday_a)
      doomed_job = notification_job!(birthday_b)

      {:ok, _survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      # birthday_b is the reminder the merge destroys, so its scheduled
      # notification must go with it (design spec §2 step 7). Every other
      # reminder just changes owner and keeps its job.
      assert Repo.get!(Oban.Job, doomed_job.id).state == "cancelled"
      assert Repo.get!(Oban.Job, kept_job.id).state == "available"
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

    test "two addresses with no line1 or postal_code are not treated as duplicates", ctx do
      # Both normalize to the same empty key, but they carry different
      # cities — collapsing them would silently destroy a distinct address.
      Kith.ContactsFixtures.address_fixture(ctx.contact_a, %{
        "line1" => nil,
        "postal_code" => nil,
        "city" => "Paris"
      })

      Kith.ContactsFixtures.address_fixture(ctx.contact_b, %{
        "line1" => nil,
        "postal_code" => nil,
        "city" => "Tokyo"
      })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{}
        })

      cities =
        from(a in Kith.Contacts.Address, where: a.contact_id == ^survivor.id, select: a.city)
        |> Repo.all()
        |> Enum.sort()

      assert cities == ["Paris", "Tokyo"]
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

  describe "merge_cluster/4 side effects" do
    setup ctx do
      scope = Kith.Accounts.Scope.for_user(ctx.user)

      email_type =
        Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      %{scope: scope, email_type: email_type}
    end

    test "drops a survivor-owned contact field outright and records it in the audit entry", ctx do
      keep =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
          "value" => "keep@example.com"
        })

      drop =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
          "value" => "drop@example.com"
        })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{contact_fields: [drop.id]}
        })

      Oban.drain_queue(queue: :default)

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
      assert dropped["owner_id"] == ctx.contact_a.id
    end

    test "a loser-owned dropped contact field is not deleted; it rides to trash with its loser",
         ctx do
      drop =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_b, ctx.email_type.id, %{
          "value" => "drop@example.com"
        })

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{contact_fields: [drop.id]}
        })

      Oban.drain_queue(queue: :default)

      # Still there — untouched, still owned by the (now-trashed) loser, not
      # hard-deleted and not remapped onto the survivor.
      reloaded = Repo.get!(Kith.Contacts.ContactField, drop.id)
      assert reloaded.contact_id == ctx.contact_b.id
      refute reloaded.contact_id == survivor.id
      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at != nil

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

    test "drops a survivor-owned address outright and records it in the audit entry", ctx do
      address = Kith.ContactsFixtures.address_fixture(ctx.contact_a, %{"line1" => "1 Drop St"})

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{addresses: [address.id]}
        })

      Oban.drain_queue(queue: :default)

      refute Repo.get(Kith.Contacts.Address, address.id)

      assert Repo.aggregate(
               from(a in Kith.Contacts.Address, where: a.contact_id == ^survivor.id),
               :count
             ) == 0

      log =
        Repo.one!(
          from(l in Kith.AuditLogs.AuditLog,
            where: l.event == "contact_merged",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert [dropped] = log.metadata["dropped"]
      assert dropped["type"] == "addresses"
      assert dropped["value"] == "1 Drop St"
      assert dropped["owner_id"] == ctx.contact_a.id
    end

    test "drops a survivor-owned tag outright and records it in the audit entry", ctx do
      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "Drop Me", "color" => "#ABCDEF"})

      Contacts.tag_contact(ctx.contact_a, tag)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{tags: [tag.id]}
        })

      Oban.drain_queue(queue: :default)

      assert Repo.aggregate(
               from(ct in "contact_tags",
                 where: ct.contact_id == ^survivor.id and ct.tag_id == ^tag.id
               ),
               :count
             ) == 0

      log =
        Repo.one!(
          from(l in Kith.AuditLogs.AuditLog,
            where: l.event == "contact_merged",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert [dropped] = log.metadata["dropped"]
      assert dropped["type"] == "tags"
      assert dropped["value"] == "Drop Me"
      assert dropped["owner_id"] == ctx.contact_a.id
    end

    test "a loser-owned dropped tag is not moved to the survivor; it rides to trash with its loser",
         ctx do
      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "Loser Tag", "color" => "#123456"})

      Contacts.tag_contact(ctx.contact_b, tag)

      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{tags: [tag.id]}
        })

      Oban.drain_queue(queue: :default)

      assert Repo.aggregate(
               from(ct in "contact_tags",
                 where: ct.contact_id == ^survivor.id and ct.tag_id == ^tag.id
               ),
               :count
             ) == 0

      assert Repo.aggregate(
               from(ct in "contact_tags",
                 where: ct.contact_id == ^ctx.contact_b.id and ct.tag_id == ^tag.id
               ),
               :count
             ) == 1

      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at != nil

      log =
        Repo.one!(
          from(l in Kith.AuditLogs.AuditLog,
            where: l.event == "contact_merged",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert [dropped] = log.metadata["dropped"]
      assert dropped["type"] == "tags"
      assert dropped["value"] == "Loser Tag"
      assert dropped["owner_id"] == ctx.contact_b.id
    end

    test "a dropped tag's audit entry names only the cluster's own owners, not every contact holding it",
         ctx do
      outsider = Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Outsider"})

      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "Widely Used", "color" => "#654321"})

      Contacts.tag_contact(ctx.contact_a, tag)
      Contacts.tag_contact(ctx.contact_b, tag)
      Contacts.tag_contact(outsider, tag)

      {:ok, _survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{},
          drop: %{tags: [tag.id]}
        })

      Oban.drain_queue(queue: :default)

      log =
        Repo.one!(
          from(l in Kith.AuditLogs.AuditLog,
            where: l.event == "contact_merged",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      owner_ids = log.metadata["dropped"] |> Enum.map(& &1["owner_id"]) |> Enum.sort()

      assert owner_ids == Enum.sort([ctx.contact_a.id, ctx.contact_b.id])
      refute outsider.id in owner_ids

      # The outsider's own tag link is untouched — the merge never touched
      # any contact outside its own cluster.
      assert Repo.aggregate(
               from(ct in "contact_tags",
                 where: ct.contact_id == ^outsider.id and ct.tag_id == ^tag.id
               ),
               :count
             ) == 1
    end

    test "rejects a dropped id belonging to no member", ctx do
      stranger =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Zed"})

      field =
        Kith.ContactsFixtures.contact_field_fixture(stranger, ctx.email_type.id, %{
          "value" => "zed@example.com"
        })

      assert {:error, {:unknown_drop, :contact_fields}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{},
                 drop: %{contact_fields: [field.id]}
               })
    end

    test "rejects a dropped tag id belonging to no member", ctx do
      {:ok, tag} =
        Contacts.create_tag(ctx.account_id, %{"name" => "Orphan", "color" => "#000000"})

      assert {:error, {:unknown_drop, :tags}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{},
                 drop: %{tags: [tag.id]}
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

    test "recomputes the survivor's display_name synchronously, with no job enqueued", ctx do
      {:ok, survivor} =
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{last_name: "S."},
          drop: %{}
        })

      assert survivor.display_name == "Alice S."

      # DisplayNameRecomputeWorker is account-wide (recomputes every contact
      # from `%{"account_id", "display_name_format"}`); enqueuing it with a
      # `contact_id` arg can never match a perform/1 clause, so the merge
      # must not enqueue it at all — `Contact.update_changeset/2` already
      # recomputes display_name synchronously (ruling R15).
      refute_enqueued(worker: Kith.Workers.DisplayNameRecomputeWorker)
    end

    # This one fails at the FIRST Multi step, so it pins the error contract and
    # the "nothing at all happened" outcome. It cannot prove the later steps roll
    # back — nothing had run yet. See the late-failure test below for that.
    test "a merge that fails inside the transaction rolls back every mutation", ctx do
      note = Kith.ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)

      drop =
        Kith.ContactsFixtures.contact_field_fixture(ctx.contact_a, ctx.email_type.id, %{
          "value" => "drop@example.com"
        })

      # contact_b references a contact in another account, so resolving to that
      # value passes validate_fields/2 (a member holds it, and it names no member
      # so D4's coercion leaves it alone), but applying it to the survivor fails
      # Contact.update_changeset/2 — inside the Multi, after `with` has already
      # accepted the resolution.
      stranger = foreign_contact()

      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [first_met_through_id: stranger.id]
      )

      assert {:error, {:invalid_fields, %Ecto.Changeset{}}} =
               Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
                 fields: %{first_met_through_id: stranger.id},
                 drop: %{contact_fields: [drop.id]}
               })

      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at == nil
      assert Repo.get!(Kith.Contacts.Note, note.id).contact_id == ctx.contact_b.id
      assert Repo.get!(Kith.Contacts.ContactField, drop.id)

      assert Repo.aggregate(
               from(l in Kith.AuditLogs.AuditLog, where: l.event == "contact_merged"),
               :count
             ) == 0
    end

    test "a failure late in the Multi rolls back the remaps that already ran", ctx do
      note = Kith.ContactsFixtures.note_fixture(ctx.contact_b, ctx.user.id)

      outsider =
        Kith.ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Outsider"})

      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^outsider.id),
        set: [first_met_through_id: ctx.contact_b.id]
      )

      # No real data can make :soft_delete_losers fail, so the failure is
      # injected as a constraint that makes the soft delete itself illegal. By
      # then :survivor and every remap step above it have written — the point of
      # the test is that all of them come back (design spec D7).
      Repo.query!(
        "ALTER TABLE contacts ADD CONSTRAINT contacts_never_deleted CHECK (deleted_at IS NULL)"
      )

      assert_raise Postgrex.Error, fn ->
        Contacts.merge_cluster(ctx.scope, ctx.contact_a.id, [ctx.contact_b.id], %{
          fields: %{last_name: "S."},
          drop: %{}
        })
      end

      Repo.query!("ALTER TABLE contacts DROP CONSTRAINT contacts_never_deleted")

      # :survivor (the first step)
      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_a.id).last_name == "Smith"
      # :remap_owned
      assert Repo.get!(Kith.Contacts.Note, note.id).contact_id == ctx.contact_b.id
      # :remap_inbound_first_met
      assert Repo.get!(Kith.Contacts.Contact, outsider.id).first_met_through_id ==
               ctx.contact_b.id

      assert Repo.get!(Kith.Contacts.Contact, ctx.contact_b.id).deleted_at == nil

      assert Repo.aggregate(
               from(l in Kith.AuditLogs.AuditLog, where: l.event == "contact_merged"),
               :count
             ) == 0
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

      Oban.drain_queue(queue: :default)

      logs =
        from(l in Kith.AuditLogs.AuditLog, where: l.event == "contact_merged") |> Repo.all()

      assert length(logs) == 1
      assert Enum.sort(hd(logs).metadata["loser_ids"]) == Enum.sort([ctx.contact_b.id, c.id])
    end

    test "the surviving birthday reminder matches the merged birthdate", ctx do
      survivor =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-01-05]
        })

      loser =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-07-22]
        })

      {:ok, survivor_reminder} = Kith.Reminders.create_birthday_reminder(survivor, ctx.user.id)
      {:ok, _loser_reminder} = Kith.Reminders.create_birthday_reminder(loser, ctx.user.id)

      # Force the loser's birthdate to win.
      assert {:ok, merged} =
               Contacts.merge_cluster(ctx.scope, survivor.id, [loser.id], %{
                 fields: %{birthdate: ~D[1985-07-22], birthdate_year_unknown: false},
                 drop: %{}
               })

      assert merged.birthdate == ~D[1985-07-22]

      reminder = Kith.Reminders.get_birthday_reminder(merged.id, ctx.account_id)

      assert reminder
      assert reminder.id == survivor_reminder.id
      assert reminder.next_reminder_date == Kith.TimeHelper.next_birthday_date(~D[1985-07-22])
    end

    test "clearing the birthdate leaves the surviving birthday reminder alone", ctx do
      # A merge that clears a birthdate is not the same event as a user
      # removing one, so the kept reminder survives untouched — the engine
      # destroys birthday reminders only to resolve the unique-index collision.
      survivor =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          birthdate: ~D[1985-01-05]
        })

      loser = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Alice"})

      {:ok, reminder} = Kith.Reminders.create_birthday_reminder(survivor, ctx.user.id)

      assert {:ok, merged} =
               Contacts.merge_cluster(ctx.scope, survivor.id, [loser.id], %{
                 fields: %{birthdate: :clear, birthdate_year_unknown: false},
                 drop: %{}
               })

      assert is_nil(merged.birthdate)

      kept = Kith.Reminders.get_birthday_reminder(merged.id, ctx.account_id)

      assert kept
      assert kept.id == reminder.id
      assert kept.next_reminder_date == reminder.next_reminder_date
    end

    test "merging two needs_review contacts keeps the survivor reviewable", ctx do
      survivor =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          immich_status: "needs_review"
        })

      loser =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          immich_status: "needs_review"
        })

      fields =
        [survivor, loser]
        |> Kith.Contacts.MergeResolution.resolve(survivor.id)
        |> Map.fetch!(:fields)

      assert {:ok, merged} =
               Contacts.merge_cluster(ctx.scope, survivor.id, [loser.id], %{
                 fields: fields,
                 drop: %{}
               })

      assert merged.immich_status == "needs_review"

      assert merged.id in Enum.map(Contacts.list_needs_review(ctx.account_id), & &1.id)
    end
  end

  describe "stay-in-touch reminders" do
    setup ctx do
      survivor_reminder =
        stay_in_touch_reminder_fixture(ctx.account_id, ctx.contact_a.id, ctx.user.id, "monthly")

      loser_reminder =
        stay_in_touch_reminder_fixture(ctx.account_id, ctx.contact_b.id, ctx.user.id, "weekly")

      Map.merge(ctx, %{
        survivor_reminder: survivor_reminder,
        loser_reminder: loser_reminder
      })
    end

    test "leaves the survivor with exactly one active stay-in-touch reminder", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      count =
        Repo.aggregate(
          from(r in Kith.Reminders.Reminder,
            where: r.contact_id == ^survivor.id and r.type == "stay_in_touch" and r.active == true
          ),
          :count
        )

      assert count == 1
    end

    test "keeps the survivor's own reminder, not the loser's", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      kept =
        Repo.one!(
          from(r in Kith.Reminders.Reminder,
            where: r.contact_id == ^survivor.id and r.type == "stay_in_touch" and r.active == true
          )
        )

      assert kept.id == ctx.survivor_reminder.id
      assert kept.frequency == "monthly"
    end

    test "cancels the Oban jobs of the reminder it discards", ctx do
      job = notification_job!(ctx.loser_reminder)

      {:ok, _survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert Repo.get(Oban.Job, job.id).state in ["cancelled", "discarded"]
    end

    # The regression this whole task exists for: a second active reminder makes
    # Reminders.resolve_stay_in_touch_instance/1 raise Ecto.MultipleResultsError.
    test "logging an interaction after the merge does not raise", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert {:ok, _} = Kith.Reminders.resolve_stay_in_touch_instance(survivor.id)
    end
  end

  describe "me_contact_id" do
    test "repoints a user whose me-contact is merged away", ctx do
      {:ok, _user} = Kith.Accounts.link_me_contact(ctx.user, ctx.contact_b.id)

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert Repo.get!(Kith.Accounts.User, ctx.user.id).me_contact_id == survivor.id
    end

    test "leaves a user whose me-contact is the survivor untouched", ctx do
      {:ok, _user} = Kith.Accounts.link_me_contact(ctx.user, ctx.contact_a.id)

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert Repo.get!(Kith.Accounts.User, ctx.user.id).me_contact_id == survivor.id
    end

    test "does not touch a user in another account", ctx do
      other = Kith.AccountsFixtures.user_fixture()
      other_contact = ContactsFixtures.contact_fixture(other.account_id)
      {:ok, _} = Kith.Accounts.link_me_contact(other, other_contact.id)

      {:ok, _survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      assert Repo.get!(Kith.Accounts.User, other.id).me_contact_id == other_contact.id
    end

    # The slow-burn failure this guards: the pointer survives the merge, then
    # the purge worker hard-deletes the loser and the FK nilifies it away.
    test "survives the 30-day purge of the merged-away contact", ctx do
      {:ok, _user} = Kith.Accounts.link_me_contact(ctx.user, ctx.contact_b.id)

      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      Repo.query!("DELETE FROM contacts WHERE id = $1", [ctx.contact_b.id])

      assert Repo.get!(Kith.Accounts.User, ctx.user.id).me_contact_id == survivor.id
    end
  end

  describe "inactive birthday reminders" do
    setup ctx do
      import Kith.RemindersFixtures

      reminder =
        birthday_reminder_fixture(ctx.account_id, ctx.contact_a.id, ctx.user.id)

      Repo.update_all(
        from(r in Kith.Reminders.Reminder, where: r.id == ^reminder.id),
        set: [active: false, enqueued_oban_job_ids: []]
      )

      # A birthdate on the loser that the merge will gap-fill onto the
      # survivor, forcing next_reminder_date to change.
      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^ctx.contact_b.id),
        set: [birthdate: ~D[1990-06-15]]
      )

      Map.put(ctx, :reminder, reminder)
    end

    test "does not enqueue jobs for a deactivated reminder", ctx do
      {:ok, _survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      kept = Repo.get!(Kith.Reminders.Reminder, ctx.reminder.id)

      assert kept.active == false
      assert kept.enqueued_oban_job_ids == []
    end

    test "still tracks the merged birthdate on the date field", ctx do
      {:ok, survivor} = Contacts.merge_contacts(ctx.contact_a.id, ctx.contact_b.id)

      kept = Repo.get!(Kith.Reminders.Reminder, ctx.reminder.id)

      assert survivor.birthdate == ~D[1990-06-15]
      assert kept.next_reminder_date == Kith.TimeHelper.next_birthday_date(~D[1990-06-15])
    end
  end
end
