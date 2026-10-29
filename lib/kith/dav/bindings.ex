defmodule Kith.DAV.Bindings do
  @moduledoc "Rebinds trusted document references after authorized native merge deduplication."

  import Ecto.Query
  alias Kith.DAV.ContactDav

  def rebind_owned!(repo, account_id, contact_id, field_ids, address_ids) do
    unless repo.in_transaction?(),
      do: raise(ArgumentError, "DAV binding reassignment requires the merge transaction")

    if map_size(field_ids) + map_size(address_ids) > 0 do
      dav =
        repo.one!(
          from d in ContactDav,
            where: d.account_id == ^account_id and d.contact_id == ^contact_id
        )

      document = rewrite_document(dav.document, field_ids, address_ids)
      dav |> Ecto.Changeset.change(document: document) |> repo.update!()
    end

    :ok
  end

  defp rewrite_document(%{"properties" => entries} = document, field_ids, address_ids) do
    properties = Enum.map(entries, &rewrite_entry(&1, field_ids, address_ids))
    %{document | "properties" => properties}
  end

  defp rewrite_document(document, _field_ids, _address_ids), do: document

  defp rewrite_entry(entry, field_ids, address_ids) do
    # Property syntax, groups, parameters, PID values and occurrence IDs are
    # client/document data. Only these internal references identify native rows.
    entry =
      if Map.has_key?(entry, "binding"),
        do: Map.update!(entry, "binding", &rewrite_token(&1, field_ids, address_ids)),
        else: entry

    case Map.get(entry, "dependencies") do
      dependencies when is_list(dependencies) ->
        Map.put(
          entry,
          "dependencies",
          Enum.map(dependencies, &rewrite_token(&1, field_ids, address_ids))
        )

      _ ->
        entry
    end
  end

  defp rewrite_token("field:" <> rest = token, field_ids, _address_ids),
    do: rewrite_id(token, "field:", rest, field_ids)

  defp rewrite_token("address:" <> rest = token, _field_ids, address_ids),
    do: rewrite_id(token, "address:", rest, address_ids)

  defp rewrite_token(token, _field_ids, _address_ids), do: token

  defp rewrite_id(token, prefix, rest, replacements) do
    with [raw_id, property] <- String.split(rest, ":", parts: 2),
         {id, ""} <- Integer.parse(raw_id),
         {:ok, replacement} <- Map.fetch(replacements, id) do
      prefix <> Integer.to_string(replacement) <> ":" <> property
    else
      _ -> token
    end
  end
end
