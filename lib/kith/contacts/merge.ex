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

  @doc """
  Merges `loser_ids` into `survivor_id` inside one transaction.

  `resolution` is `%{fields: %{atom => value | :clear}, drop: %{atom => [id]}}`.

  Returns `{:ok, contact}` or `{:error, reason}`, where `reason` is one of
  `:not_found`, `:trashed`, `:different_accounts`, `:survivor_in_losers`,
  `:no_losers`, `{:unknown_value, field}`, `{:not_clearable, field}`, or
  `{:invalid_fields, changeset}` if the resolved values fail changeset
  validation on the survivor.
  """
  def run(scope, survivor_id, loser_ids, resolution) do
    Repo.transaction(fn ->
      with {:ok, members} <- lock_and_load(scope, survivor_id, loser_ids),
           survivor = Enum.find(members, &(&1.id == survivor_id)),
           :ok <- validate_fields(members, resolution) do
        losers = Enum.reject(members, &(&1.id == survivor_id))

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
          |> Enum.each(fn schema ->
            repo.update_all(
              from(r in schema, where: r.contact_id in ^loser_ids),
              set: [contact_id: survivor.id]
            )
          end)

          {:ok, :done}
        end)
        |> Multi.run(:remap_contact_tags, fn repo, _changes ->
          # contact_tags is a bare join table with no Ecto schema, so it is
          # invisible to @owned_schemas but must still follow the survivor —
          # mirrors the old engine's `:remap_contact_tags` step. unique_index
          # on (contact_id, tag_id); two losers can share a tag the survivor
          # doesn't have, so this dedupes across the whole cluster too.
          loser_ids = Enum.map(losers, & &1.id)
          dedupe_and_move(repo, "contact_tags", "tag_id", loser_ids, survivor.id)
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
          # contact_fields has no unique index — collapsing exact duplicates
          # here is a product decision, not a constraint guard. Tags and
          # photos are deduped by their own remap steps above already, via
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
                    AND other.value = cf.value
                    AND other.id < cf.id
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
        |> Multi.run(:soft_delete_losers, fn repo, _changes ->
          now = DateTime.utc_now(:second)
          ids = Enum.map(losers, & &1.id)

          {count, _} =
            repo.update_all(from(c in Contact, where: c.id in ^ids), set: [deleted_at: now])

          {:ok, count}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, changes} -> changes.survivor
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
