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

  # Policy and array fields are computed rather than picked from a member, so
  # `held_by_member?/3` accepts any value for them without a match. Mirrors
  # `MergeFields.policy_fields/0 ++ MergeFields.array_fields/0` at compile
  # time (guards cannot call remote functions) — keep this in sync with that
  # registry.
  @computed_fields MergeFields.policy_fields() ++ MergeFields.array_fields()

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
           :ok <- validate_fields(members, resolution),
           :ok <- validate_drop(members, resolution) do
        losers = Enum.reject(members, &(&1.id == survivor_id))

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
        dropped_field_ids = drop |> Map.get(:contact_fields, []) |> Enum.uniq()
        dropped_address_ids = drop |> Map.get(:addresses, []) |> Enum.uniq()
        dropped_tag_ids = drop |> Map.get(:tags, []) |> Enum.uniq()

        Multi.new()
        |> Multi.run(:survivor, fn _repo, _changes ->
          apply_fields(survivor, resolution)
        end)
        |> Multi.run(:remap_photos, fn repo, _changes ->
          # unique_index(:photos, [:contact_id, :content_hash]) means a blanket
          # move would raise whenever any two members share a hash — including
          # two losers colliding with each other, not just a loser vs. the
          # survivor. Dedupe across the whole cluster before moving.
          loser_ids = Enum.map(losers, & &1.id)
          dedupe_and_move(repo, "photos", "content_hash", loser_ids, survivor.id)
          {:ok, :done}
        end)
        |> Multi.run(:remap_immich_candidates, fn repo, _changes ->
          # unique_index(:immich_candidates, [:contact_id, :immich_photo_id]) —
          # duplicate contacts routinely have the same Immich photo suggested
          # for both, so this collides in practice more than most.
          loser_ids = Enum.map(losers, & &1.id)
          dedupe_and_move(repo, "immich_candidates", "immich_photo_id", loser_ids, survivor.id)
          {:ok, :done}
        end)
        |> Multi.run(:remap_birthday_reminders, fn repo, _changes ->
          # unique_index(:reminders, [:contact_id], where: "type = 'birthday'")
          # — birthday reminders are auto-created whenever a birthdate is set,
          # so merging any two contacts that both have one is the single most
          # common collision. Keep the survivor's own birthday reminder if it
          # has one; otherwise keep the lowest-id one among the losers. Delete
          # the rest; reminder_instances cascades (on_delete: :delete_all).
          loser_ids = Enum.map(losers, & &1.id)
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
              keep_id =
                case Enum.find(rows, fn [_id, contact_id] -> contact_id == survivor.id end) do
                  [id, _contact_id] -> id
                  nil -> rows |> Enum.map(&hd/1) |> Enum.min()
                end

              delete_ids = for [id, _contact_id] <- rows, id != keep_id, do: id

              if delete_ids != [] do
                repo.query!("DELETE FROM reminders WHERE id = ANY($1)", [delete_ids])
              end

              {:ok, :done}
          end
        end)
        |> Multi.run(:remap_owned, fn repo, _changes ->
          loser_ids = Enum.map(losers, & &1.id)

          @owned_schemas
          |> List.delete(Kith.Contacts.Photo)
          |> List.delete(Kith.Contacts.ImmichCandidate)
          |> List.delete(ContactField)
          |> List.delete(Address)
          |> Enum.each(fn schema ->
            repo.update_all(
              from(r in schema, where: r.contact_id in ^loser_ids),
              set: [contact_id: survivor.id]
            )
          end)

          # ContactField and Address get their own call: dropped ids owned by
          # a loser must not move, so they stay behind and are soft-deleted
          # with that loser instead of riding to the survivor.
          remap_excluding(repo, ContactField, loser_ids, survivor.id, dropped_field_ids)
          remap_excluding(repo, Address, loser_ids, survivor.id, dropped_address_ids)

          {:ok, :done}
        end)
        |> Multi.run(:remap_contact_tags, fn repo, _changes ->
          # contact_tags is a bare join table with no Ecto schema, so it is
          # invisible to @owned_schemas but must still follow the survivor —
          # mirrors the old engine's `:remap_contact_tags` step. unique_index
          # on (contact_id, tag_id); two losers can share a tag the survivor
          # doesn't have, so this dedupes across the whole cluster too.
          # Dropped tag ids are excluded from the move: a loser's link to a
          # dropped tag stays on the loser and rides to trash with it.
          loser_ids = Enum.map(losers, & &1.id)
          dedupe_and_move_tags(repo, loser_ids, survivor.id, dropped_tag_ids)
          {:ok, :done}
        end)
        |> Multi.run(:remap_activity_contacts, fn repo, _changes ->
          # unique_index(:activity_contacts, [:activity_id, :contact_id]) —
          # two losers can be tagged on the same activity the survivor isn't.
          loser_ids = Enum.map(losers, & &1.id)
          dedupe_and_move(repo, "activity_contacts", "activity_id", loser_ids, survivor.id)
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
        |> Multi.run(:dedupe_owned, fn repo, _changes ->
          # contact_fields and addresses have no unique index — collapsing
          # duplicates here is a product decision (design spec §3), not a
          # constraint guard. Both keys are normalized (lower + trimmed) so
          # case/whitespace-only differences still collapse. Tags and photos
          # are deduped by their own remap steps above already, via
          # `dedupe_and_move/5`; nothing to repeat here.
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
            [survivor.id]
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
            [survivor.id]
          )

          {:ok, :done}
        end)
        |> Multi.run(:remap_relationships, fn repo, _changes ->
          loser_ids = Enum.map(losers, & &1.id)
          remap_relationships(repo, survivor.id, loser_ids)
        end)
        |> Multi.run(:apply_drop, fn repo, _changes ->
          # Only rows currently owned by the survivor are deleted outright.
          # A dropped id owned by a loser was excluded from the remap steps
          # above, so it is still sitting on that loser here — left alone, it
          # rides to trash with the loser at `:soft_delete_losers` instead of
          # being destroyed with no trash behind it (design spec §2).
          Enum.each(drop_map(resolution), fn
            {_key, []} ->
              :ok

            {:tags, tag_ids} ->
              repo.delete_all(
                from(ct in "contact_tags",
                  where: ct.contact_id == ^survivor.id and ct.tag_id in ^tag_ids
                )
              )

            {key, ids} ->
              case Map.fetch(@drop_schemas, key) do
                {:ok, schema} ->
                  repo.delete_all(
                    from(r in schema, where: r.id in ^ids and r.contact_id == ^survivor.id)
                  )

                :error ->
                  :ok
              end
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
          # Runs after the remap steps, not before: cancel_all_for_contact/2
          # only cancels the Oban jobs of reminders currently owned by the
          # given contact. By this point every loser's reminders have already
          # moved to the survivor, so this step finds nothing on the losers —
          # that's the correct outcome. Running it earlier would cancel jobs
          # for reminders about to legitimately become the survivor's,
          # silently killing live reminders.
          Enum.each(losers, &Kith.Reminders.cancel_all_for_contact(&1.id, scope.account.id))
          {:ok, :done}
        end)
        |> Multi.run(:soft_delete_losers, fn repo, _changes ->
          now = DateTime.utc_now(:second)
          ids = Enum.map(losers, & &1.id)

          {count, _} =
            repo.update_all(from(c in Contact, where: c.id in ^ids), set: [deleted_at: now])

          {:ok, count}
        end)
        |> Multi.run(:resolve_pairs, fn _repo, _changes ->
          Kith.DuplicateDetection.resolve_after_merge(
            scope.account.id,
            survivor.id,
            Enum.map(losers, & &1.id),
            Map.get(resolution, :unchecked_ids, [])
          )

          {:ok, :done}
        end)
        |> Multi.run(:audit, fn _repo, changes ->
          survivor = changes.last_talked_to

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
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{last_talked_to: survivor}} -> survivor
          {:error, _step, reason, _changes} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
  defp dedupe_and_move(repo, table, key_column, loser_ids, survivor_id) do
    repo.query!(
      """
      DELETE FROM #{table} t
      WHERE t.contact_id = ANY($1)
        AND t.#{key_column} IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM #{table} o
          WHERE o.#{key_column} = t.#{key_column}
            AND (o.contact_id = $2
                 OR (o.contact_id = ANY($1) AND o.ctid < t.ctid))
        )
      """,
      [loser_ids, survivor_id]
    )

    repo.query!(
      "UPDATE #{table} SET contact_id = $1 WHERE contact_id = ANY($2)",
      [survivor_id, loser_ids]
    )

    :ok
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
  defp remap_relationships(repo, survivor_id, loser_ids) do
    cluster_ids = [survivor_id | loser_ids]

    repo.query!(
      "DELETE FROM relationships WHERE contact_id = ANY($1) AND related_contact_id = ANY($1)",
      [cluster_ids]
    )

    repo.query!(
      """
      DELETE FROM relationships r
      WHERE r.contact_id = ANY($1)
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
      [loser_ids, survivor_id]
    )

    repo.query!(
      "UPDATE relationships SET contact_id = $1 WHERE contact_id = ANY($2)",
      [survivor_id, loser_ids]
    )

    repo.query!(
      """
      DELETE FROM relationships r
      WHERE r.related_contact_id = ANY($1)
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
      [loser_ids, survivor_id]
    )

    repo.query!(
      "UPDATE relationships SET related_contact_id = $1 WHERE related_contact_id = ANY($2)",
      [survivor_id, loser_ids]
    )

    {:ok, :done}
  end

  # `resolution.drop` may legitimately be absent — dot access would raise
  # `KeyError` in that case, so every drop-related function goes through this.
  defp drop_map(resolution), do: Map.get(resolution, :drop) || %{}

  defp validate_drop(members, resolution) do
    member_ids = Enum.map(members, & &1.id)

    Enum.reduce_while(drop_map(resolution), :ok, fn
      {_key, []}, :ok ->
        {:cont, :ok}

      {:tags, ids}, :ok ->
        ids = Enum.uniq(ids)

        owned =
          from(ct in "contact_tags",
            where: ct.tag_id in ^ids and ct.contact_id in ^member_ids,
            select: ct.tag_id,
            distinct: true
          )
          |> Repo.all()

        if Enum.sort(owned) == Enum.sort(ids) do
          {:cont, :ok}
        else
          {:halt, {:error, {:unknown_drop, :tags}}}
        end

      {key, ids}, :ok ->
        case Map.fetch(@drop_schemas, key) do
          {:ok, schema} ->
            ids = Enum.uniq(ids)

            owned =
              from(r in schema,
                where: r.id in ^ids and r.contact_id in ^member_ids,
                select: r.id
              )
              |> Repo.all()

            if Enum.sort(owned) == Enum.sort(ids) do
              {:cont, :ok}
            else
              {:halt, {:error, {:unknown_drop, key}}}
            end

          :error ->
            {:halt, {:error, {:unknown_drop, key}}}
        end
    end)
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
    Enum.flat_map(drop_map(resolution), fn
      {_key, []} ->
        []

      {:tags, ids} ->
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

      {:addresses, ids} ->
        ids = Enum.uniq(ids)

        from(a in Address, where: a.id in ^ids, select: {a.line1, a.contact_id})
        |> repo.all()
        |> Enum.map(fn {line1, owner_id} ->
          %{type: "addresses", value: line1, owner_id: owner_id}
        end)

      {key, ids} ->
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
    end)
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

  # Same collision handling as `dedupe_and_move/5`, specialised to
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
