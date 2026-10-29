defmodule Kith.Contacts.Write do
  @moduledoc """
  Account-serialized native and DAV writes with one publication at outer commit.

  Nested context calls accumulate affected identities instead of publishing
  intermediate representations. The account lock always precedes row locks.
  """
  import Ecto.Query

  alias Kith.Contacts.{
    Avatar,
    Contact,
    ContactField,
    ContactFieldType,
    Relationship,
    RelationshipType
  }

  alias Kith.DAV.{ContactDav, References, Store}
  alias Kith.Repo
  @key {__MODULE__, :write}
  require Logger

  def origin, do: Process.get({__MODULE__, :origin}, :kith)

  def from_dav(fun) do
    previous = Process.put({__MODULE__, :origin}, :dav)

    try do
      fun.()
    after
      if previous,
        do: Process.put({__MODULE__, :origin}, previous),
        else: Process.delete({__MODULE__, :origin})
    end
  end

  def transaction(account_id, fun) do
    case Process.get(@key) do
      %{account_id: ^account_id} -> Repo.transaction(fun)
      nil -> outer_transaction(account_id, fun)
      _ -> raise ArgumentError, "cannot nest writes across accounts"
    end
  end

  def run(account_id, ids, fun) do
    case transaction(account_id, fn -> execute(account_id, ids, fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(account_id, ids, fun) do
    prepared = dependencies(account_id, ids)
    prepare_contacts(account_id, prepared)
    result = fun.()
    validate_result!(account_id, result)
    affected = dependencies(account_id, ids ++ result_ids(result))

    # A new edge or moved child can introduce a staged owner that preparation
    # could not discover. Preserve its accepted metadata, then recapture native
    # values at publication. The command's own newly accepted document remains
    # staged because its owner was prepared before the mutation.
    invalidate_documents(affected -- prepared)
    mark(account_id, affected)
    result
  end

  defp validate_result!(_account_id, {:error, reason}), do: Repo.rollback(reason)
  defp validate_result!(account_id, {:ok, result}), do: validate_result!(account_id, result)

  defp validate_result!(account_id, %{account_id: owner}) when owner != account_id,
    do: Repo.rollback(:cross_account_write)

  defp validate_result!(account_id, %{contact_id: id} = result) do
    validate_owner!(account_id, id, result, :contact_id)
    validate_associations!(account_id, result)
  end

  defp validate_result!(_, _), do: :ok

  defp validate_owner!(account_id, id, result, field) do
    unless Repo.exists?(from c in Contact, where: c.id == ^id and c.account_id == ^account_id) do
      result
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(field, "must belong to the same account")
      |> Repo.rollback()
    end
  end

  defp validate_associations!(account_id, %ContactField{contact_field_type_id: id} = result) do
    unless Repo.exists?(
             from t in ContactFieldType,
               where: t.id == ^id and (is_nil(t.account_id) or t.account_id == ^account_id)
           ) do
      result
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:contact_field_type_id, "must belong to the same account")
      |> Repo.rollback()
    end
  end

  defp validate_associations!(account_id, %Relationship{} = result) do
    validate_owner!(account_id, result.related_contact_id, result, :related_contact_id)

    unless Repo.exists?(
             from t in RelationshipType,
               where:
                 t.id == ^result.relationship_type_id and
                   (is_nil(t.account_id) or t.account_id == ^account_id)
           ) do
      result
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:relationship_type_id, "must belong to the same account")
      |> Repo.rollback()
    end
  end

  defp validate_associations!(_, _), do: :ok

  def prepare(account_id, ids) do
    prepare_contacts(account_id, dependencies(account_id, ids))
  end

  defp prepare_contacts(account_id, ids) do
    invalidate_documents(ids)
    Store.ensure_contact_rows(account_id, ids)
    Store.initialize(account_id, ids)
    mark(account_id, ids)
    :ok
  end

  def mark(account_id, ids) do
    case Process.get(@key) do
      %{account_id: ^account_id, ids: pending} = state ->
        Process.put(@key, %{state | ids: MapSet.union(pending, MapSet.new(ids))})
        :ok

      nil ->
        run(account_id, ids, fn -> :ok end)

      _ ->
        raise ArgumentError, "cannot publish across accounts"
    end
  end

  def stage_document(account_id, contact, document) do
    %{account_id: ^account_id} = state = Process.get(@key)

    Process.put(@key, %{
      state
      | documents: Map.put(state.documents, contact.id, {contact, document})
    })

    :ok
  end

  def staged_document(contact_id) do
    case Process.get(@key) do
      %{documents: documents} -> Map.get(documents, contact_id)
      _ -> nil
    end
  end

  defp invalidate_documents(ids) do
    case Process.get(@key) do
      nil ->
        :ok

      state ->
        Enum.each(Map.take(state.documents, ids), fn {id, {_contact, document}} ->
          from(d in ContactDav, where: d.account_id == ^state.account_id and d.contact_id == ^id)
          |> Repo.update_all(set: [document: document])
        end)

        Process.put(@key, %{state | documents: Map.drop(state.documents, ids)})
    end
  end

  def after_commit(fun) do
    case Process.get(@key) do
      nil ->
        fun.()

      state ->
        Process.put(@key, %{state | effects: [fun | state.effects]})
        :ok
    end
  end

  def active?(account_id), do: match?(%{account_id: ^account_id}, Process.get(@key))

  def dependencies(_account_id, []), do: []

  def dependencies(account_id, ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    neighbors =
      Repo.all(
        from r in Relationship,
          where:
            r.account_id == ^account_id and
              (r.contact_id in ^ids or r.related_contact_id in ^ids),
          select: {r.contact_id, r.related_contact_id}
      )

    Enum.uniq(
      ids ++
        References.owners(account_id, ids) ++ Enum.flat_map(neighbors, fn {a, b} -> [a, b] end)
    )
  end

  defp outer_transaction(account_id, fun) do
    outcome =
      Avatar.with_cleanup(fn ->
        Repo.transaction(fn ->
          Store.lock_account!(account_id)

          Process.put(@key, %{
            account_id: account_id,
            ids: MapSet.new(),
            effects: [],
            documents: %{}
          })

          try do
            result = fun.()
            ids = Process.get(@key).ids |> MapSet.to_list()
            Store.publish(account_id, dependencies(account_id, ids))
            {result, Enum.reverse(Process.get(@key).effects)}
          after
            Process.delete(@key)
          end
        end)
      end)

    finish_transaction(outcome)
  end

  defp finish_transaction({:ok, {result, effects}}) do
    Enum.each(effects, &run_effect/1)
    {:ok, result}
  end

  defp finish_transaction(error), do: error

  defp run_effect(fun) do
    fun.()
  rescue
    error -> Logger.warning("Post-commit contact effect failed: #{Exception.message(error)}")
  catch
    kind, _reason -> Logger.warning("Post-commit contact effect terminated (#{kind})")
  end

  defp result_ids({:ok, result}), do: result_ids(result)
  defp result_ids(%Contact{id: id}), do: [id]
  defp result_ids(%{contact_id: id}), do: [id]
  defp result_ids(_), do: []
end
