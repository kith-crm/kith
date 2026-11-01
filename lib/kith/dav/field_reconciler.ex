defmodule Kith.DAV.FieldReconciler do
  @moduledoc "Multiset replacement of trusted shared fields with internal and v4 PID bindings."

  import Ecto.Query
  alias Kith.Contacts.{Address, ContactField}
  alias Kith.DAV.{DocumentIndex, FieldRegistry, PropertyIdentity, SharedContact}
  alias Kith.Repo
  alias Kith.VCard.Document

  @names %{emails: "EMAIL", phones: "TEL", urls: "URL", addresses: "ADR"}
  @address_fields ~w(line1 line2 city province postal_code country)a

  def replace(contact, nested) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "DAV field replacement requires a transaction")

    current = Repo.preload(contact, :dav)
    old_document = Map.get(current.dav, :document) || %{}

    incoming_document =
      decode(Map.get(nested, :dav_parsed_document) || Map.get(nested, :dav_document))

    context = matching_context(old_document, incoming_document)

    rows =
      Repo.all(
        from(f in ContactField,
          where: f.account_id == ^contact.account_id and f.contact_id == ^contact.id,
          order_by: f.id,
          preload: [:contact_field_type]
        )
      )

    Enum.each([:emails, :phones, :urls], fn kind ->
      shared = Enum.filter(rows, &(FieldRegistry.kind(&1.contact_field_type) == kind))

      replace_kind(
        contact,
        kind,
        shared,
        Map.get(nested, kind, []),
        context
      )
    end)

    addresses =
      Repo.all(
        from(a in Address,
          where: a.account_id == ^contact.account_id and a.contact_id == ^contact.id,
          order_by: a.id
        )
      )

    replace_kind(
      contact,
      :addresses,
      addresses,
      Map.get(nested, :addresses, []),
      context
    )

    :ok
  end

  defp decode(nil), do: nil
  defp decode(%Document{} = document), do: document

  defp decode(raw) do
    case Document.parse(raw) do
      {:ok, document} -> document
      _ -> Repo.rollback(:invalid_document)
    end
  end

  defp matching_context(old, incoming) do
    incoming_properties = if incoming, do: incoming.properties, else: []
    mapped = Enum.filter(incoming_properties, &(&1.normalized_name in ~w(EMAIL TEL URL ADR)))
    needs_pids? = Enum.any?(mapped, &has_pid?/1)
    old_entries = if needs_pids?, do: Map.get(old, "properties", []), else: []

    %{
      properties: Enum.group_by(mapped, & &1.normalized_name),
      sources: sources(incoming_properties),
      old_sources: sources(Enum.map(old_entries, & &1["property"])),
      old_bindings: Enum.group_by(old_entries, & &1["binding"])
    }
  end

  defp has_pid?(property),
    do: Enum.any?(property_params(property), &(parameter_name(&1) == "PID"))

  defp replace_kind(contact, kind, rows, attrs, context) do
    name = @names[kind]
    properties = Map.get(context.properties, name, [])

    prior =
      if Enum.any?(properties, &has_pid?/1) do
        Map.new(rows, &{&1.id, row_pids(&1, kind, context.old_bindings, context.old_sources)})
      else
        %{}
      end

    properties = List.to_tuple(properties)
    sources = context.sources

    pid_owners =
      Enum.reduce(prior, %{}, fn {id, identities}, owners ->
        Enum.reduce(identities, owners, fn identity, acc ->
          Map.update(acc, identity, MapSet.new([id]), &MapSet.put(&1, id))
        end)
      end)

    index =
      DocumentIndex.new(rows, %{
        id: fn row -> [row.id] end,
        exact: fn row -> [value_key(row, kind)] end,
        typed: fn row ->
          Enum.map(row_types(row, kind), &{value_key(row, kind), &1})
        end
      })

    {index, _consumed, pending} =
      attrs
      |> Enum.with_index()
      |> Enum.reduce({index, MapSet.new(), []}, fn {attrs, ordinal}, {index, consumed, pending} ->
        property = if ordinal < tuple_size(properties), do: elem(properties, ordinal), else: nil
        ids = pids(property, sources)

        candidates =
          Enum.reduce(ids, MapSet.new(), fn id, acc ->
            MapSet.union(acc, Map.get(pid_owners, id, MapSet.new()))
          end)
          |> MapSet.difference(consumed)
          |> MapSet.to_list()

        {row, index} =
          case candidates do
            [id] ->
              DocumentIndex.take_first(index, [{:id, id}])

            [] ->
              key = value_key(attrs, kind)
              types = property_types(property, Map.get(attrs, :label))
              choices = Enum.map(types, &{:typed, {key, &1}}) ++ [{:exact, key}]
              DocumentIndex.take_first(index, choices)

            _ ->
              Repo.rollback(:ambiguous_property_identity)
          end

        if row do
          update!(row, kind, attrs)
          {index, MapSet.put(consumed, row.id), pending}
        else
          {index, consumed, [attrs | pending]}
        end
      end)

    bulk_insert!(contact, kind, Enum.reverse(pending))
    bulk_delete!(contact, kind, DocumentIndex.remaining(index))
  end

  defp value_key(row, :addresses),
    do: @address_fields |> Enum.map(&Map.get(row, &1)) |> List.to_tuple()

  defp value_key(row, _kind), do: Map.get(row, :value)

  defp row_types(row, :addresses), do: SharedContact.type_tokens(row.label)

  defp row_types(row, _kind),
    do: row |> SharedContact.field_label() |> SharedContact.type_tokens()

  defp property_types(nil, label), do: prioritize_types(SharedContact.type_tokens(label))

  defp property_types(property, _label) do
    property
    |> property_params()
    |> Enum.filter(&(parameter_name(&1) == "TYPE"))
    |> Enum.flat_map(&parameter_values/1)
    |> Enum.flat_map(&SharedContact.type_tokens/1)
    |> Enum.uniq()
    |> prioritize_types()
  end

  # HOME/WORK/CELL/FAX distinguish native labels; VOICE and other broad
  # client tokens must not win first merely because the client reordered TYPE.
  defp prioritize_types(types),
    do: Enum.sort_by(types, &{if(&1 in ~w(home work cell fax pager), do: 0, else: 1), &1})

  defp update!(row, :addresses, attrs) do
    if Enum.all?(@address_fields, &(Map.get(row, &1) == Map.get(attrs, &1))) do
      row
    else
      row |> Address.changeset(Map.take(attrs, @address_fields)) |> save!()
    end
  end

  defp update!(%{value: value} = row, _kind, %{value: value}), do: row

  defp update!(row, _kind, attrs),
    do: row |> ContactField.changeset(%{value: attrs.value}) |> save!()

  defp bulk_insert!(_contact, _kind, []), do: :ok

  defp bulk_insert!(contact, kind, attrs) do
    now = DateTime.utc_now(:second)
    type = if kind != :addresses, do: FieldRegistry.canonical_type!(kind)

    fields =
      if kind == :addresses,
        do: [:label, :contact_id, :account_id | @address_fields],
        else: [:value, :label]

    rows =
      attrs
      |> Enum.reject(fn attrs ->
        kind != :addresses and (is_nil(attrs.value) or String.trim(attrs.value) == "")
      end)
      |> Enum.map(fn attrs ->
        changeset =
          if kind == :addresses do
            owned = %{account_id: contact.account_id, contact_id: contact.id}

            Address.changeset(
              %Address{},
              Map.merge(Map.take(attrs, [:label | @address_fields]), owned)
            )
          else
            # Ownership/type are authorized constants supplied once by the SQL
            # below. The native changeset validates both variable field values.
            ContactField.changeset(%ContactField{}, %{value: attrs.value, label: attrs.label})
          end

        unless changeset.valid?, do: Repo.rollback(changeset)

        row = changeset |> Ecto.Changeset.apply_changes() |> Map.take(fields)

        if kind == :addresses,
          do: Map.merge(row, %{inserted_at: now, updated_at: now}),
          else: row
      end)

    if kind == :addresses do
      rows |> Enum.chunk_every(2_000) |> Enum.each(&Repo.insert_all(Address, &1))
    else
      rows
      |> Enum.chunk_every(50_000)
      |> Enum.each(fn batch ->
        # Arrays avoid repeating the common owner/type/timestamp parameters for
        # every row. Ordinality preserves deterministic occurrence/ID ordering.
        Repo.query!(
          """
          INSERT INTO "contact_fields"
            (account_id, contact_id, contact_field_type_id, value, label, inserted_at, updated_at)
          SELECT $1::bigint, $2::bigint, $3::bigint, f.value, f.label, $6::timestamp, $6::timestamp
          FROM unnest($4::text[], $5::text[]) WITH ORDINALITY AS f(value, label, position)
          ORDER BY f.position
          """,
          [
            contact.account_id,
            contact.id,
            type.id,
            Enum.map(batch, & &1.value),
            Enum.map(batch, & &1.label),
            DateTime.to_naive(now)
          ]
        )
      end)
    end
  end

  defp bulk_delete!(_contact, _kind, []), do: :ok

  defp bulk_delete!(contact, kind, rows) do
    ids = Enum.map(rows, & &1.id)
    schema = if kind == :addresses, do: Address, else: ContactField

    Repo.delete_all(
      from row in schema,
        where:
          row.account_id == ^contact.account_id and row.contact_id == ^contact.id and
            row.id in ^ids
    )
  end

  defp save!(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp row_pids(row, kind, old_bindings, sources) do
    token =
      if kind == :addresses, do: "address:#{row.id}:ADR", else: "field:#{row.id}:#{@names[kind]}"

    old_bindings
    |> Map.get(token, [])
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, pids(&1["property"], sources)))
  end

  defp sources(properties) do
    case PropertyIdentity.sources(properties) do
      {:ok, sources} -> sources
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pids(property, sources), do: PropertyIdentity.pids(property, sources)

  defp property_params(%Document.Property{parameters: parameters}), do: parameters
  defp property_params(property), do: property["parameters"] || []
  defp parameter_name(%Document.Parameter{normalized_name: name}), do: name
  defp parameter_name(parameter), do: parameter["normalized_name"]
  defp parameter_values(%Document.Parameter{values: values}), do: values
  defp parameter_values(parameter), do: parameter["values"]
end
