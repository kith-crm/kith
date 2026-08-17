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
