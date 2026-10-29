defmodule Kith.DAV.References do
  @moduledoc "Indexes client UUID references without guessing or creating native relationships."
  import Ecto.Query
  alias Kith.DAV.{ContactDav, DocumentReference, UID}
  alias Kith.Repo

  def owners(_account_id, []), do: []

  def owners(account_id, target_ids) do
    Repo.all(
      from r in DocumentReference,
        join: d in ContactDav,
        on: d.account_id == r.account_id and d.uid == r.target_uid,
        where: r.account_id == ^account_id and d.contact_id in ^target_ids,
        select: r.source_contact_id,
        distinct: true
    )
  end

  def replace(account_id, source_id, document) do
    wanted = document |> Map.get("properties", []) |> Enum.reduce(MapSet.new(), &reference/2)

    current =
      Repo.all(
        from r in DocumentReference,
          where: r.account_id == ^account_id and r.source_contact_id == ^source_id,
          select: r.target_uid
      )
      |> MapSet.new()

    removed = MapSet.difference(current, wanted) |> MapSet.to_list()

    if removed != [] do
      from(r in DocumentReference,
        where:
          r.account_id == ^account_id and
            r.source_contact_id == ^source_id and r.target_uid in ^removed
      )
      |> Repo.delete_all()
    end

    rows =
      wanted
      |> MapSet.difference(current)
      |> Enum.map(fn uid ->
        %{account_id: account_id, source_contact_id: source_id, target_uid: uid}
      end)

    if rows != [], do: Repo.insert_all(DocumentReference, rows, on_conflict: :nothing)
    :ok
  end

  defp reference(%{"property" => %{"normalized_name" => name, "value" => value}}, refs)
       when name in ["RELATED", "X-KITH-RELATED"] do
    case UID.normalize(value) do
      {:ok, uid} -> MapSet.put(refs, uid)
      _ -> refs
    end
  end

  defp reference(_, refs), do: refs
end
