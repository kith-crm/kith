defmodule Kith.Contacts.Merge do
  @moduledoc """
  The N-way contact merge engine.

  Applies a resolution it is handed; it never derives one. Everything the merge
  writes was computed by `Kith.Contacts.MergeResolution` and approved by the
  caller, so a concurrent edit between resolution and submission fails
  validation rather than silently changing the result.

  ## Contract: `resolution.drop` must name every row backing a dropped value

  `:dedupe_owned` (which collapses `contact_fields`/`addresses` rows the
  survivor and a loser hold with an equal, normalized value) runs *before*
  `:apply_drop`. If the caller's drop list names only one side of such a
  duplicate pair, the outcome depends on which row `:dedupe_owned` happened to
  keep by row id:

    * if the kept row is the one named in `drop` — it is then deleted by
      `:apply_drop`, and the value is gone, as the caller intended.
    * if the *other* row (the one **not** named in `drop`) is the one kept —
      `:apply_drop`'s id matches nothing, and the value the caller meant to
      exclude survives on the merged contact, unconditionally.

  A caller building a drop list (e.g. a merge-review UI) must therefore
  include the ids of every member's row backing a value the user chose to
  drop, not just one. This is a caller contract, not a merge bug: reordering
  `:apply_drop` ahead of `:dedupe_owned` does not fix it — it makes the
  survivor's row disappear into the loser's not-yet-deduped duplicate, which
  then gets remapped in and the dropped value comes back unconditionally.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kith.AuditLogs
  alias Kith.Contacts.{Address, Contact, ContactField, MergeFields, Tag}
  alias Kith.Repo

  # Policy, array, Immich and coupled-flag fields are computed rather than
  # picked from a member, so `held_by_member?/3` accepts any value for them
  # without a match. Two of those groups are resolved as a unit and can
  # therefore synthesise a value no member stores:
  #
  #   * the Immich group — an id from one record paired with another's sync
  #     timestamp is corrupt state. With every member at `needs_review` and
  #     no `immich_person_id`, the three nullable columns clear while
  #     `immich_status` keeps the strongest status any member held, because
  #     the column is `null: false` with a CHECK constraint and has no unset
  #     state to clear to.
  #   * the date/flag pairs — with no member holding a date, the flag
  #     resolves to `false` for that same reason, even when every member
  #     stores `true`.
  #
  # Mirrors `MergeFields.policy_fields/0 ++ MergeFields.array_fields/0 ++
  # MergeFields.immich_fields/0 ++ MergeFields.coupled_flags/0` at compile
  # time (guards cannot call remote functions) — keep this in sync with that
  # registry.
  @computed_fields MergeFields.policy_fields() ++
                     MergeFields.array_fields() ++
                     MergeFields.immich_fields() ++ MergeFields.coupled_flags()

  # Every schema owning a contact_id that must follow the survivor. The six
  # after `Reminder` are the ones the previous two-contact engine silently
  # orphaned (Bug 1 in the design spec). `import_records` is deliberately
  # absent: it references a contact through an untyped `local_entity_id`
  # bigint with no FK, so it gets its own step (`remap_import_records_step/4`)
  # rather than the blanket `contact_id` move.
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

  # Which schema backs each key of `resolution.drop`. Tags are the exception:
  # `contact_tags` is a bare join table, so its ids are tag ids.
  @drop_schemas %{
    contact_fields: ContactField,
    addresses: Address
  }

  @doc """
  Merges `loser_ids` into `survivor_id` inside one transaction.

  `resolution` is `%{fields: %{atom => value | :clear}, drop: %{atom => [id]},
  unchecked_ids: [id]}`. `:unchecked_ids` is optional (default `[]`) and
  names every contact the caller's UI presented as a duplicate candidate but
  the user did not include in this merge — see
  `Kith.DuplicateDetection.resolve_after_merge/4`, which this calls to
  settle and repoint that cluster's candidate pairs. Omitting it (or passing
  an incomplete list) does not fail the merge, but it means a pair the user
  actually rejected is left `pending` instead of `dismissed`, so it comes
  back as a suggestion on the next duplicate scan — the caller is
  responsible for passing every id it showed the user, not just the ones
  the user visibly unchecked.

  `scope.user` is used as the actor recorded on the merge's audit entry.

  Returns `{:ok, contact}` or `{:error, reason}`, where `reason` is one of
  `:not_found`, `:trashed`, `:different_accounts`, `:survivor_in_losers`,
  `:no_losers`, `{:unknown_value, field}`, `{:not_clearable, field}`,
  `{:unknown_drop, key}`, or `{:invalid_fields, changeset}` if the resolved
  values fail changeset validation on the survivor.
  """
  def run(scope, survivor_id, loser_ids, resolution) do
    Repo.transaction(fn ->
      with {:ok, members} <- lock_and_load(scope, survivor_id, loser_ids),
           survivor = Enum.find(members, &(&1.id == survivor_id)),
           {:ok, resolution} <- validate_fields(members, resolution),
           :ok <- validate_drop(members, resolution) do
        run_merge(scope, members, survivor, resolution)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Everything below this point runs inside the `SELECT ... FOR UPDATE`
  # transaction opened by `run/4` above — the lock and every validation and
  # write must stay inside that one enclosing `Repo.transaction`.
  defp run_merge(scope, members, survivor, resolution) do
    losers = Enum.reject(members, &(&1.id == survivor.id))

    # Captured now, before `:remap_owned` reassigns contact_fields and
    # addresses from losers to the survivor — read any later than this
    # and every dropped row's owner_id would read back as the survivor
    # regardless of which member actually held it.
    member_ids = Enum.map(members, & &1.id)
    dropped_records = describe_dropped(Repo, resolution, member_ids)

    # A dropped record owned by a loser must not be remapped onto the
    # survivor at all — it stays put and rides to trash with its owner
    # when the loser is soft-deleted below. Only a dropped record already
    # owned by the survivor is deleted outright, in `:apply_drop`. These
    # ids are what the remap steps below exclude from their moves.
    drop = drop_map(resolution)

    dropped_ids = %{
      contact_fields: drop |> Map.get(:contact_fields, []) |> Enum.uniq(),
      addresses: drop |> Map.get(:addresses, []) |> Enum.uniq(),
      tags: drop |> Map.get(:tags, []) |> Enum.uniq()
    }

    scope
    |> build_multi(members, survivor, losers, resolution, dropped_records, dropped_ids)
    |> Repo.transaction()
    |> case do
      {:ok, %{last_talked_to: survivor}} -> survivor
      {:error, _step, reason, _changes} -> Repo.rollback(reason)
    end
  end

  # Multi step ORDER is load-bearing: every dedupe stays ahead of the move it
  # guards, the drop capture happens before this is even called (in
  # `run_merge/3`, ahead of any mutation), `:resolve_pairs` stays immediately
  # after `:soft_delete_losers` (a `merged` pair row must have a trashed
  # endpoint), and `run/4` returns the survivor struct from `:last_talked_to`,
  # not the earlier `:survivor` step.
  defp build_multi(scope, members, survivor, losers, resolution, dropped_records, dropped_ids) do
    loser_ids = Enum.map(losers, & &1.id)

    account_id = scope.account.id

    Multi.new()
    |> Multi.run(:survivor, fn _repo, _changes -> apply_fields(survivor, resolution) end)
    |> Multi.run(:remap_photos, fn repo, _changes ->
      # unique_index(:photos, [:contact_id, :content_hash]) means a blanket
      # move would raise whenever any two members share a hash — including
      # two losers colliding with each other, not just a loser vs. the
      # survivor. Dedupe across the whole cluster before moving.
      dedupe_and_move(repo, "photos", "content_hash", loser_ids, survivor.id, account_id)
      {:ok, :done}
    end)
    |> Multi.run(:remap_immich_candidates, fn repo, _changes ->
      # unique_index(:immich_candidates, [:contact_id, :immich_photo_id]) —
      # duplicate contacts routinely have the same Immich photo suggested
      # for both, so this collides in practice more than most.
      dedupe_and_move(
        repo,
        "immich_candidates",
        "immich_photo_id",
        loser_ids,
        survivor.id,
        account_id
      )

      {:ok, :done}
    end)
    |> Multi.run(:remap_birthday_reminders, fn repo, %{survivor: survivor} ->
      remap_birthday_reminders_step(repo, survivor, loser_ids, account_id)
    end)
    |> Multi.run(:remap_stay_in_touch_reminders, fn repo, _changes ->
      remap_stay_in_touch_reminders_step(repo, loser_ids, survivor.id)
    end)
    |> Multi.run(:remap_owned, fn repo, _changes ->
      remap_owned_step(repo, loser_ids, survivor.id, dropped_ids)
    end)
    |> Multi.run(:remap_contact_tags, fn repo, _changes ->
      # contact_tags is a bare join table with no Ecto schema, so it is
      # invisible to @owned_schemas but must still follow the survivor —
      # mirrors the old engine's `:remap_contact_tags` step. unique_index
      # on (contact_id, tag_id); two losers can share a tag the survivor
      # doesn't have, so this dedupes across the whole cluster too.
      # Dropped tag ids are excluded from the move: a loser's link to a
      # dropped tag stays on the loser and rides to trash with it.
      dedupe_and_move_tags(repo, loser_ids, survivor.id, dropped_ids.tags)
      {:ok, :done}
    end)
    |> Multi.run(:remap_activity_contacts, fn repo, _changes ->
      # unique_index(:activity_contacts, [:activity_id, :contact_id]) —
      # two losers can be tagged on the same activity the survivor isn't.
      dedupe_and_move(
        repo,
        "activity_contacts",
        "activity_id",
        loser_ids,
        survivor.id,
        account_id
      )

      {:ok, :done}
    end)
    |> Multi.run(:remap_inbound_first_met, fn repo, _changes ->
      remap_inbound_first_met_step(repo, loser_ids, survivor.id, account_id)
    end)
    |> Multi.run(:remap_import_records, fn repo, _changes ->
      remap_import_records_step(repo, loser_ids, survivor.id, account_id)
    end)
    |> Multi.run(:dedupe_owned, fn repo, _changes -> dedupe_owned_step(repo, survivor.id) end)
    |> Multi.run(:remap_relationships, fn repo, _changes ->
      remap_relationships(repo, survivor.id, loser_ids, account_id)
    end)
    |> Multi.run(:apply_drop, fn repo, _changes ->
      apply_drop_step(repo, resolution, survivor.id)
    end)
    |> Multi.run(:last_talked_to, fn repo, %{survivor: survivor} ->
      last_talked_to_step(repo, members, survivor)
    end)
    |> Multi.run(:soft_delete_losers, fn repo, _changes ->
      soft_delete_losers_step(repo, loser_ids)
    end)
    |> Multi.run(:resolve_pairs, fn _repo, _changes ->
      resolve_pairs_step(scope, survivor.id, loser_ids, resolution)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit_step(scope, changes, losers, resolution, dropped_records)
    end)
  end

  # unique_index(:reminders, [:contact_id], where: "type = 'birthday'") —
  # birthday reminders are auto-created whenever a birthdate is set, so
  # merging any two contacts that both have one is the single most common
  # collision. Keep the survivor's own birthday reminder if it has one;
  # otherwise keep the lowest-id one among the losers. Delete the rest;
  # reminder_instances cascades (on_delete: :delete_all).
  #
  # The kept reminder is then re-dated from the *merged* birthdate. `:survivor`
  # runs before this step and may have just replaced the survivor's birthdate
  # with a loser's — nothing else in the app re-syncs a birthday reminder from
  # `contacts.birthdate`, so without this the survivor keeps a reminder firing
  # on a date it no longer has, permanently, while the reminder that matched
  # the surviving birthdate has just been deleted.
  defp remap_birthday_reminders_step(repo, survivor, loser_ids, account_id) do
    all_ids = [survivor.id | loser_ids]

    %{rows: rows} =
      repo.query!(
        "SELECT id, contact_id FROM reminders WHERE type = 'birthday' AND contact_id = ANY($1)",
        [all_ids]
      )

    case rows do
      [] ->
        {:ok, :done}

      _ ->
        {:ok, :done} = delete_extra_birthday_reminders(repo, rows, survivor.id)
        resync_birthday_reminder(repo, rows, survivor, account_id)
    end
  end

  # No merged birthdate means there is no date to re-derive from, so the kept
  # reminder is left exactly as it was. Deleting it here would be a different
  # change than this one: a merge that clears a birthdate is not the same event
  # as a user removing one (which routes through
  # `Reminders.delete_birthday_reminder/2`), and the engine's contract is that
  # a merge destroys birthday reminders only to resolve the unique-index
  # collision.
  defp resync_birthday_reminder(_repo, _rows, %Contact{birthdate: nil}, _account_id) do
    {:ok, :done}
  end

  defp resync_birthday_reminder(repo, rows, survivor, account_id) do
    keep_id = reminder_keep_id(rows, survivor.id)
    next_date = Kith.TimeHelper.next_birthday_date(survivor.birthdate)
    reminder = repo.get!(Kith.Reminders.Reminder, keep_id)

    if reminder.next_reminder_date != next_date do
      cancel_reminder_jobs(repo, [keep_id])

      reminder =
        reminder
        |> Ecto.Changeset.change(%{next_reminder_date: next_date, enqueued_oban_job_ids: []})
        |> repo.update!()

      account = repo.get!(Kith.Accounts.Account, account_id)
      {:ok, job_ids} = Kith.Reminders.enqueue_jobs_for_reminder(reminder, account)

      repo.update_all(
        from(r in Kith.Reminders.Reminder, where: r.id == ^keep_id),
        set: [enqueued_oban_job_ids: job_ids]
      )
    end

    {:ok, :done}
  end

  defp delete_extra_birthday_reminders(repo, rows, survivor_id) do
    keep_id = reminder_keep_id(rows, survivor_id)
    delete_ids = for [id, _contact_id] <- rows, id != keep_id, do: id

    if delete_ids != [] do
      cancel_reminder_jobs(repo, delete_ids)
      repo.query!("DELETE FROM reminders WHERE id = ANY($1)", [delete_ids])
    end

    {:ok, :done}
  end

  # Design spec §2 step 7: these duplicate birthday reminders, and the
  # duplicate stay-in-touch reminders collapsed in
  # `remap_stay_in_touch_reminders_step/3`, are the only reminders a merge
  # destroys. Every other reminder a loser owns moves to the survivor at
  # `:remap_owned` and must keep its scheduled job, so there is nothing to
  # cancel per-contact — cancelling here, where the doomed ids are still
  # known, is the correct scope. `ReminderNotificationWorker.perform/1` also
  # discards a job whose reminder is gone, so this trims the queue rather
  # than being the only guard.
  defp cancel_reminder_jobs(repo, reminder_ids) do
    %{rows: rows} =
      repo.query!("SELECT enqueued_oban_job_ids FROM reminders WHERE id = ANY($1)", [reminder_ids])

    rows |> List.flatten() |> Kith.Reminders.cancel_jobs()
  end

  defp reminder_keep_id(rows, survivor_id) do
    case Enum.find(rows, fn [_id, contact_id] -> contact_id == survivor_id end) do
      [id, _contact_id] -> id
      nil -> rows |> Enum.map(&hd/1) |> Enum.min()
    end
  end

  # Stay-in-touch reminders have no unique index (only `reminders_birthday_
  # unique_idx` exists), so the blanket `:remap_owned` move happily lands two
  # active rows on the survivor. Nothing raises at write time — the failure
  # surfaces later and elsewhere, in `Reminders.resolve_stay_in_touch_instance/1`,
  # whose `Repo.one/1` raises `Ecto.MultipleResultsError` the next time an
  # interaction is logged. Collapse to one here, where the doomed ids are
  # still known and their jobs can be cancelled. Same keep rule as birthdays:
  # the survivor's own row wins, else the lowest id.
  defp remap_stay_in_touch_reminders_step(repo, loser_ids, survivor_id) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id, contact_id FROM reminders
        WHERE contact_id = ANY($1)
          AND type = 'stay_in_touch'
          AND active = true
        """,
        [[survivor_id | loser_ids]]
      )

    case rows do
      [] ->
        {:ok, :done}

      [_only_one] ->
        {:ok, :done}

      _ ->
        keep_id = reminder_keep_id(rows, survivor_id)
        delete_ids = for [id, _contact_id] <- rows, id != keep_id, do: id

        cancel_reminder_jobs(repo, delete_ids)
        repo.query!("DELETE FROM reminders WHERE id = ANY($1)", [delete_ids])

        {:ok, :done}
    end
  end

  defp remap_owned_step(repo, loser_ids, survivor_id, dropped_ids) do
    @owned_schemas
    |> List.delete(Kith.Contacts.Photo)
    |> List.delete(Kith.Contacts.ImmichCandidate)
    |> List.delete(ContactField)
    |> List.delete(Address)
    |> Enum.each(fn schema ->
      repo.update_all(
        from(r in schema, where: r.contact_id in ^loser_ids),
        set: [contact_id: survivor_id]
      )
    end)

    # ContactField and Address get their own call: dropped ids owned by
    # a loser must not move, so they stay behind and are soft-deleted
    # with that loser instead of riding to the survivor.
    remap_excluding(repo, ContactField, loser_ids, survivor_id, dropped_ids.contact_fields)
    remap_excluding(repo, Address, loser_ids, survivor_id, dropped_ids.addresses)

    {:ok, :done}
  end

  # Contacts met *through* a loser now point at the survivor. The survivor's
  # own row is excluded: `clear_member_self_reference/2` only coerces when the
  # caller's field map names `:first_met_through_id`, so a partial resolution
  # can reach here with the survivor pointing at a loser — and rewriting that
  # to `survivor_id` produces the self-reference
  # `Contact.validate_first_met_through_account/1` exists to reject, through an
  # `update_all` that runs no changeset.
  defp remap_inbound_first_met_step(repo, loser_ids, survivor_id, account_id) do
    {count, _} =
      repo.update_all(
        from(c in Contact,
          where: c.account_id == ^account_id,
          where: c.id != ^survivor_id,
          where: c.first_met_through_id in ^loser_ids
        ),
        set: [first_met_through_id: survivor_id]
      )

    {:ok, count}
  end

  # `import_records.local_entity_id` is an untyped bigint with no foreign key,
  # so nothing repoints it on its own and `ContactPurgeWorker` will hard-delete
  # the loser it names 30 days from now. The unique index on
  # (account_id, source, source_entity_type, source_entity_id) means a
  # re-import would then map that source contact to a row that no longer
  # exists instead of to the survivor.
  defp remap_import_records_step(repo, loser_ids, survivor_id, account_id) do
    {count, _} =
      repo.update_all(
        from(ir in Kith.Imports.ImportRecord,
          where: ir.account_id == ^account_id,
          where: ir.local_entity_type == "contact",
          where: ir.local_entity_id in ^loser_ids
        ),
        set: [local_entity_id: survivor_id]
      )

    {:ok, count}
  end

  # contact_fields and addresses have no unique index — collapsing
  # duplicates here is a product decision (design spec §3), not a
  # constraint guard. Both keys are normalized (lower + trimmed) so
  # case/whitespace-only differences still collapse. Tags and photos
  # are deduped by their own remap steps above already, via
  # `dedupe_and_move/6`; nothing to repeat here.
  defp dedupe_owned_step(repo, survivor_id) do
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
              AND lower(btrim(other.value)) = lower(btrim(cf.value))
              AND other.id < cf.id
          )
      )
      """,
      [survivor_id]
    )

    # A row with neither line1 nor postal_code is not a duplicate of
    # another such row — addresses carry city/region/country/label too,
    # so two blank-key rows can be different places. Only dedupe when
    # at least one of the key columns actually has content.
    repo.query!(
      """
      DELETE FROM addresses
      WHERE id IN (
        SELECT a.id FROM addresses a
        WHERE a.contact_id = $1
          AND (lower(btrim(coalesce(a.line1, ''))) <> ''
               OR lower(btrim(coalesce(a.postal_code, ''))) <> '')
          AND EXISTS (
            SELECT 1 FROM addresses other
            WHERE other.contact_id = $1
              AND lower(btrim(coalesce(other.line1, ''))) =
                  lower(btrim(coalesce(a.line1, '')))
              AND lower(btrim(coalesce(other.postal_code, ''))) =
                  lower(btrim(coalesce(a.postal_code, '')))
              AND other.id < a.id
          )
      )
      """,
      [survivor_id]
    )

    {:ok, :done}
  end

  # Only rows currently owned by the survivor are deleted outright.
  # A dropped id owned by a loser was excluded from the remap steps
  # above, so it is still sitting on that loser here — left alone, it
  # rides to trash with the loser at `:soft_delete_losers` instead of
  # being destroyed with no trash behind it (design spec §2).
  defp apply_drop_step(repo, resolution, survivor_id) do
    Enum.each(drop_map(resolution), &apply_drop_entry(repo, &1, survivor_id))
    {:ok, :done}
  end

  defp apply_drop_entry(_repo, {_key, []}, _survivor_id), do: :ok

  defp apply_drop_entry(repo, {:tags, tag_ids}, survivor_id) do
    repo.delete_all(
      from(ct in "contact_tags",
        where: ct.contact_id == ^survivor_id and ct.tag_id in ^tag_ids
      )
    )
  end

  defp apply_drop_entry(repo, {key, ids}, survivor_id) do
    case Map.fetch(@drop_schemas, key) do
      {:ok, schema} ->
        repo.delete_all(from(r in schema, where: r.id in ^ids and r.contact_id == ^survivor_id))

      :error ->
        :ok
    end
  end

  defp last_talked_to_step(repo, members, survivor) do
    latest = latest_last_talked_to(members)

    if latest && latest != survivor.last_talked_to do
      survivor |> Ecto.Changeset.change(%{last_talked_to: latest}) |> repo.update()
    else
      {:ok, survivor}
    end
  end

  defp latest_last_talked_to(members) do
    members
    |> Enum.map(& &1.last_talked_to)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> Enum.max(dates, DateTime)
    end
  end

  defp soft_delete_losers_step(repo, loser_ids) do
    now = DateTime.utc_now(:second)

    {count, _} =
      repo.update_all(from(c in Contact, where: c.id in ^loser_ids), set: [deleted_at: now])

    {:ok, count}
  end

  defp resolve_pairs_step(scope, survivor_id, loser_ids, resolution) do
    Kith.DuplicateDetection.resolve_after_merge(
      scope.account.id,
      survivor_id,
      loser_ids,
      Map.get(resolution, :unchecked_ids, [])
    )

    {:ok, :done}
  end

  defp audit_step(scope, changes, losers, resolution, dropped_records) do
    survivor = changes.last_talked_to

    if scope.user do
      AuditLogs.log_event(scope.account.id, scope.user, :contact_merged,
        contact_id: survivor.id,
        contact_name: survivor.display_name,
        metadata: %{
          survivor_id: survivor.id,
          loser_ids: Enum.map(losers, & &1.id),
          fields: inspect_fields(resolution),
          dropped: dropped_records
        }
      )
    else
      {:ok, :skipped}
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
        # FOR UPDATE must run inside the same transaction as the writes below:
        # a row lock taken outside a transaction is released the instant the
        # statement returns, so it would not serialise two sessions merging
        # overlapping clusters (design-spec §2 step 1, scenario D9).
        #
        # order_by: c.id fixes a deterministic lock acquisition order across
        # sessions, so two merges over overlapping clusters always contend
        # for locks in the same order instead of deadlocking.
        members =
          from(c in Contact, where: c.id in ^ids, order_by: c.id, lock: "FOR UPDATE")
          |> Repo.all()

        cond do
          length(members) != length(Enum.uniq(ids)) -> {:error, :not_found}
          Enum.any?(members, &(&1.account_id != account_id)) -> {:error, :different_accounts}
          Enum.any?(members, &(&1.deleted_at != nil)) -> {:error, :trashed}
          true -> {:ok, members}
        end
    end
  end

  # Returns the resolution to apply, which is not always the one handed in:
  # `first_met_through_id` is coerced (see `clear_member_self_reference/2`).
  defp validate_fields(members, resolution) do
    member_ids = Enum.map(members, & &1.id)
    fields = clear_member_self_reference(resolution.fields, member_ids)

    result =
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

    case result do
      :ok -> {:ok, Map.put(resolution, :fields, fields)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Design spec §3 / scenario D4: "when the resolved `first_met_through_id` is
  # any merged member, it is set to `nil`". A contact cannot be met through a
  # record it just absorbed, and pointing at a loser is worse than useless —
  # `:remap_inbound_first_met` would rewrite it to the survivor anyway,
  # producing a self-reference. Enforced here, at the engine, so every caller
  # gets it: `MergeResolution.clear_self_reference/2` covers the resolver-driven
  # paths, but a legacy `%{"first_met_through_id" => "survivor"}` choice and a
  # cluster screen offering a loser's id as a value both route around it.
  # Coercing rather than rejecting matches §3's wording and is a no-op for the
  # resolver-driven callers, which already pass `:clear`.
  defp clear_member_self_reference(fields, member_ids) do
    case Map.fetch(fields, :first_met_through_id) do
      {:ok, value} when value != :clear ->
        if value in member_ids,
          do: Map.put(fields, :first_met_through_id, :clear),
          else: fields

      _ ->
        fields
    end
  end

  # Array, policy and Immich fields are computed rather than picked, so they
  # are not required to match a single member's stored value.
  defp held_by_member?(_members, field, _value)
       when field in @computed_fields,
       do: true

  defp held_by_member?(members, field, value) do
    Enum.any?(members, fn member ->
      stored = Map.fetch!(member, field)
      stored == value or (is_binary(stored) and String.trim(stored) == value)
    end)
  end

  # Moves every `table` row owned by a loser onto the survivor, first deleting
  # whichever rows collide on `(contact_id, key_column)` — mirroring a unique
  # index on that pair. Collisions are checked across the *whole* cluster, not
  # just loser-vs-survivor: two losers can hold the same key value while the
  # survivor holds none, and a plain survivor-vs-loser check would miss that,
  # then raise when both surviving loser rows land on the same contact_id.
  # `ctid` (Postgres's physical row identifier) breaks ties between two
  # colliding loser rows deterministically without needing an `id` column, so
  # this works for bare join tables (`contact_tags`) as well as tables with a
  # primary key (`photos`, `activity_contacts`, `immich_candidates`).
  defp dedupe_and_move(repo, table, key_column, loser_ids, survivor_id, account_id) do
    {scope_delete, scope_update, scope_param} = account_scope(table, account_id)

    repo.query!(
      """
      DELETE FROM #{table} t
      WHERE t.contact_id = ANY($1)#{scope_delete}
        AND t.#{key_column} IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM #{table} o
          WHERE o.#{key_column} = t.#{key_column}
            AND (o.contact_id = $2
                 OR (o.contact_id = ANY($1) AND o.ctid < t.ctid))
        )
      """,
      [loser_ids, survivor_id] ++ scope_param
    )

    repo.query!(
      "UPDATE #{table} SET contact_id = $1 WHERE contact_id = ANY($2)#{scope_update}",
      [survivor_id, loser_ids] ++ scope_param
    )

    :ok
  end

  # Tables `dedupe_and_move/6` drives that carry their own account_id column.
  # `activity_contacts` (and `contact_tags`, in `dedupe_and_move_tags/4`) are
  # bare join tables with no account column, so they are scoped transitively
  # by the account-validated contact ids `lock_and_load/3` produced. The
  # scoping is defence in depth either way — those ids are already checked —
  # but every other query in this codebase carries its scope.
  @account_column_tables ~w(photos immich_candidates)

  defp account_scope(table, account_id) do
    if table in @account_column_tables do
      {"\n  AND t.account_id = $3", " AND account_id = $3", [account_id]}
    else
      {"", "", []}
    end
  end

  # Relationships are directional and carry a 4-column unique index
  # (account_id, contact_id, related_contact_id, relationship_type_id), so a
  # collision can appear on either endpoint, and — as with the other dedupes
  # above — between two losers that neither one shares with the survivor.
  #
  # Step 1 handles self-references: any relationship with both endpoints
  # inside the cluster (survivor or loser, in either order — including a
  # relationship between two different losers) becomes contact_id ==
  # related_contact_id once both sides land on the survivor, so it is
  # dropped outright rather than deduped. What remains has exactly one
  # cluster endpoint; the other points outside the cluster.
  #
  # Steps 2-3 dedupe + move the forward direction (contact_id is a loser),
  # steps 4-5 mirror that for the reverse direction (related_contact_id is a
  # loser) — each pass drops a loser's row when either another loser's row
  # (ctid tie-break) or the survivor's own row already covers the same
  # (other endpoint, type) pair, then moves what's left onto the survivor.
  defp remap_relationships(repo, survivor_id, loser_ids, account_id) do
    cluster_ids = [survivor_id | loser_ids]

    repo.query!(
      """
      DELETE FROM relationships
      WHERE account_id = $2
        AND contact_id = ANY($1)
        AND related_contact_id = ANY($1)
      """,
      [cluster_ids, account_id]
    )

    repo.query!(
      """
      DELETE FROM relationships r
      WHERE r.account_id = $3
        AND r.contact_id = ANY($1)
        AND EXISTS (
          SELECT 1 FROM relationships o
          WHERE o.related_contact_id = r.related_contact_id
            AND o.relationship_type_id = r.relationship_type_id
            AND (
              o.contact_id = $2
              OR (o.contact_id = ANY($1) AND o.ctid < r.ctid)
            )
        )
      """,
      [loser_ids, survivor_id, account_id]
    )

    repo.query!(
      "UPDATE relationships SET contact_id = $1 WHERE contact_id = ANY($2) AND account_id = $3",
      [survivor_id, loser_ids, account_id]
    )

    repo.query!(
      """
      DELETE FROM relationships r
      WHERE r.account_id = $3
        AND r.related_contact_id = ANY($1)
        AND EXISTS (
          SELECT 1 FROM relationships o
          WHERE o.contact_id = r.contact_id
            AND o.relationship_type_id = r.relationship_type_id
            AND (
              o.related_contact_id = $2
              OR (o.related_contact_id = ANY($1) AND o.ctid < r.ctid)
            )
        )
      """,
      [loser_ids, survivor_id, account_id]
    )

    repo.query!(
      """
      UPDATE relationships SET related_contact_id = $1
      WHERE related_contact_id = ANY($2) AND account_id = $3
      """,
      [survivor_id, loser_ids, account_id]
    )

    {:ok, :done}
  end

  # `resolution.drop` may legitimately be absent — dot access would raise
  # `KeyError` in that case, so every drop-related function goes through this.
  defp drop_map(resolution), do: Map.get(resolution, :drop) || %{}

  defp validate_drop(members, resolution) do
    member_ids = Enum.map(members, & &1.id)

    Enum.reduce_while(drop_map(resolution), :ok, fn entry, :ok ->
      validate_drop_entry(entry, member_ids)
    end)
  end

  defp validate_drop_entry({_key, []}, _member_ids), do: {:cont, :ok}

  defp validate_drop_entry({:tags, ids}, member_ids) do
    ids = Enum.uniq(ids)

    owned =
      from(ct in "contact_tags",
        where: ct.tag_id in ^ids and ct.contact_id in ^member_ids,
        select: ct.tag_id,
        distinct: true
      )
      |> Repo.all()

    drop_validation_result(owned, ids, :tags)
  end

  defp validate_drop_entry({key, ids}, member_ids) do
    case Map.fetch(@drop_schemas, key) do
      {:ok, schema} ->
        ids = Enum.uniq(ids)

        owned =
          from(r in schema,
            where: r.id in ^ids and r.contact_id in ^member_ids,
            select: r.id
          )
          |> Repo.all()

        drop_validation_result(owned, ids, key)

      :error ->
        {:halt, {:error, {:unknown_drop, key}}}
    end
  end

  defp drop_validation_result(owned, ids, key) do
    if Enum.sort(owned) == Enum.sort(ids) do
      {:cont, :ok}
    else
      {:halt, {:error, {:unknown_drop, key}}}
    end
  end

  # Captured before deletion so the audit trail survives the rows it describes.
  #
  # `member_ids` matters only for the `:tags` clause: a tag_id is many-to-one
  # with `contact_tags` rows, so without filtering by the cluster's members,
  # dropping a widely-used tag would describe every contact in the account
  # that happens to hold it — not just the merge's own members. The
  # `:contact_fields`/`:addresses` clauses don't need it: their ids are row
  # ids already pinned to a member by `validate_drop/2`.
  defp describe_dropped(repo, resolution, member_ids) do
    Enum.flat_map(drop_map(resolution), &describe_dropped_entry(repo, &1, member_ids))
  end

  defp describe_dropped_entry(_repo, {_key, []}, _member_ids), do: []

  defp describe_dropped_entry(repo, {:tags, ids}, member_ids) do
    ids = Enum.uniq(ids)

    from(ct in "contact_tags",
      join: t in Tag,
      on: t.id == ct.tag_id,
      where: ct.tag_id in ^ids and ct.contact_id in ^member_ids,
      select: {t.name, ct.contact_id}
    )
    |> repo.all()
    |> Enum.map(fn {name, owner_id} ->
      %{type: "tags", value: name, owner_id: owner_id}
    end)
  end

  defp describe_dropped_entry(repo, {:addresses, ids}, _member_ids) do
    ids = Enum.uniq(ids)

    from(a in Address, where: a.id in ^ids, select: {a.line1, a.contact_id})
    |> repo.all()
    |> Enum.map(fn {line1, owner_id} ->
      %{type: "addresses", value: line1, owner_id: owner_id}
    end)
  end

  defp describe_dropped_entry(repo, {key, ids}, _member_ids) do
    case Map.fetch(@drop_schemas, key) do
      {:ok, schema} ->
        ids = Enum.uniq(ids)

        from(r in schema, where: r.id in ^ids, select: {r.value, r.contact_id})
        |> repo.all()
        |> Enum.map(fn {value, owner_id} ->
          %{type: to_string(key), value: value, owner_id: owner_id}
        end)

      :error ->
        []
    end
  end

  # Moves every `schema` row owned by a loser onto the survivor, except rows
  # whose id is in `excluded_ids` — those are dropped ids owned by a loser,
  # which must stay on that loser (see the `:remap_owned` step). An empty
  # `excluded_ids` list compiles to a no-op filter, not a special case.
  defp remap_excluding(repo, schema, loser_ids, survivor_id, excluded_ids) do
    from(r in schema, where: r.contact_id in ^loser_ids, where: r.id not in ^excluded_ids)
    |> repo.update_all(set: [contact_id: survivor_id])

    :ok
  end

  # Same collision handling as `dedupe_and_move/6`, specialised to
  # `contact_tags` with one addition: a loser's link to a tag_id in
  # `excluded_tag_ids` is neither deduped away nor moved — it is left in
  # place so it rides to trash with that loser. An empty `excluded_tag_ids`
  # behaves exactly like the unfiltered move.
  defp dedupe_and_move_tags(repo, loser_ids, survivor_id, excluded_tag_ids) do
    repo.query!(
      """
      DELETE FROM contact_tags t
      WHERE t.contact_id = ANY($1)
        AND t.tag_id IS NOT NULL
        AND t.tag_id <> ALL($3::bigint[])
        AND EXISTS (
          SELECT 1 FROM contact_tags o
          WHERE o.tag_id = t.tag_id
            AND (o.contact_id = $2
                 OR (o.contact_id = ANY($1) AND o.ctid < t.ctid))
        )
      """,
      [loser_ids, survivor_id, excluded_tag_ids]
    )

    repo.query!(
      "UPDATE contact_tags SET contact_id = $1 WHERE contact_id = ANY($2) AND tag_id <> ALL($3::bigint[])",
      [survivor_id, loser_ids, excluded_tag_ids]
    )

    :ok
  end

  defp inspect_fields(%{fields: fields}) do
    Map.new(fields, fn {field, value} -> {to_string(field), inspect(value)} end)
  end

  defp apply_fields(survivor, %{fields: fields}) do
    changes =
      Map.new(fields, fn
        {field, :clear} -> {field, nil}
        {field, value} -> {field, value}
      end)

    case survivor |> Contact.update_changeset(changes) |> Repo.update() do
      {:ok, contact} -> {:ok, contact}
      {:error, changeset} -> {:error, {:invalid_fields, changeset}}
    end
  end
end
