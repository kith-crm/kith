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
          # move would raise whenever a loser and the survivor share a hash.
          # Delete the loser's colliding copy first, then move what's left —
          # mirrors the old engine's `:remap_photos` step.
          loser_ids = Enum.map(losers, & &1.id)

          repo.query!(
            """
            DELETE FROM photos
            WHERE contact_id = ANY($1)
              AND content_hash IS NOT NULL
              AND content_hash IN (
                SELECT content_hash FROM photos WHERE contact_id = $2 AND content_hash IS NOT NULL
              )
            """,
            [loser_ids, survivor.id]
          )

          {count, _} =
            repo.update_all(
              from(p in Kith.Contacts.Photo, where: p.contact_id in ^loser_ids),
              set: [contact_id: survivor.id]
            )

          {:ok, count}
        end)
        |> Multi.run(:remap_owned, fn repo, _changes ->
          loser_ids = Enum.map(losers, & &1.id)

          @owned_schemas
          |> List.delete(Kith.Contacts.Photo)
          |> Enum.each(fn schema ->
            repo.update_all(
              from(r in schema, where: r.contact_id in ^loser_ids),
              set: [contact_id: survivor.id]
            )
          end)

          {:ok, length(@owned_schemas) - 1}
        end)
        |> Multi.run(:remap_contact_tags, fn repo, _changes ->
          # contact_tags is a bare join table with no Ecto schema, so it is
          # invisible to @owned_schemas but must still follow the survivor —
          # mirrors the old engine's `:remap_contact_tags` step. Delete rows
          # that would collide with a tag the survivor already has (unique
          # index on (contact_id, tag_id)), then move the rest.
          loser_ids = Enum.map(losers, & &1.id)

          repo.query!(
            """
            DELETE FROM contact_tags
            WHERE contact_id = ANY($1)
              AND tag_id IN (SELECT tag_id FROM contact_tags WHERE contact_id = $2)
            """,
            [loser_ids, survivor.id]
          )

          repo.update_all(
            from(ct in "contact_tags", where: ct.contact_id in ^loser_ids),
            set: [contact_id: survivor.id]
          )

          {:ok, :done}
        end)
        |> Multi.run(:remap_activity_contacts, fn repo, _changes ->
          loser_ids = Enum.map(losers, & &1.id)

          # Drop join rows that would collide with one the survivor already
          # has, then move the rest.
          repo.query!(
            """
            DELETE FROM activity_contacts
            WHERE contact_id = ANY($1)
              AND activity_id IN (SELECT activity_id FROM activity_contacts WHERE contact_id = $2)
            """,
            [loser_ids, survivor.id]
          )

          repo.update_all(
            from(ac in "activity_contacts", where: ac.contact_id in ^loser_ids),
            set: [contact_id: survivor.id]
          )

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
