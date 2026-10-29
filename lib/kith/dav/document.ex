defmodule Kith.DAV.RepresentationError do
  defexception message: "DAV representation is temporarily unavailable"
end

defmodule Kith.DAV.ConversionError do
  defexception message: "DAV document cannot be converted without losing client metadata"
end

defmodule Kith.DAV.Document do
  @moduledoc "A client vCard document whose bound values are owned by native shared rows."

  import Ecto.Query
  alias Kith.Contacts.Relationship
  alias Kith.DAV.{DocumentIndex, PropertyIdentity, Relationships, SharedContact, UID}
  alias Kith.Repo
  alias Kith.VCard.{Document, Parser, Serializer}
  alias Kith.VCard.Document.{Parameter, Property}

  @server ~w(VERSION UID REV)
  @scalar ~w(FN N NICKNAME BDAY ORG TITLE PHOTO)
  @companions ~w(X-ABLABEL X-ABADR X-ABRELATEDNAMES)

  @doc false
  def pack(%{"schema_version" => 2} = document), do: document

  def pack(%{"properties" => entries} = document) when is_list(entries),
    do:
      document
      |> Map.put("schema_version", 2)
      |> Map.put("properties", Enum.map(entries, &pack_entry/1))

  def pack(document), do: document

  @doc false
  def unpack(%{"schema_version" => 2, "properties" => entries} = document),
    do:
      document
      |> Map.put("schema_version", 1)
      |> Map.put("properties", Enum.map(entries, &unpack_entry/1))

  def unpack(document), do: document

  defp pack_entry(entry) do
    property = entry["property"]
    extras = Map.drop(entry, ~w(id binding property baseline))

    packed = [
      entry["id"],
      pack_binding(entry["binding"]),
      pack_property(property),
      pack_baseline(entry["baseline"], property)
    ]

    if extras == %{}, do: trim_trailing_nil(packed), else: packed ++ [extras]
  end

  defp unpack_entry(packed) do
    [id, binding, property | rest] = packed
    property = unpack_property(property)
    baseline = unpack_baseline(Enum.at(rest, 0), property)
    extras = Enum.at(rest, 1) || %{}

    entry =
      Map.merge(extras, %{
        "id" => id,
        "binding" => unpack_binding(binding, property, id),
        "property" => property
      })

    if baseline, do: Map.put(entry, "baseline", baseline), else: entry
  end

  defp pack_property(property),
    do: [
      property["group"],
      property["name"],
      Enum.map(property["parameters"], &[&1["name"], &1["raw"], &1["values"]]),
      property["value"]
    ]

  defp unpack_property([group, name, parameters, value]),
    do: %{
      "group" => group,
      "name" => name,
      "normalized_name" => String.upcase(name),
      "parameters" => Enum.map(parameters, &unpack_parameter/1),
      "value" => value
    }

  defp unpack_parameter([name, raw, values]),
    do: %{
      "name" => name,
      "normalized_name" => String.upcase(name),
      "raw" => raw,
      "values" => values
    }

  defp pack_baseline(nil, _property), do: nil

  defp pack_baseline(baseline, property) do
    value = if baseline["value"] == property["value"], do: nil, else: baseline["value"]
    types = property_types(baseline)

    cond do
      Map.has_key?(baseline, "name") -> [value, types, baseline["name"], baseline["group"]]
      value == nil and types == [] -> []
      types == [] -> [value]
      true -> [value, types]
    end
  end

  defp unpack_baseline(nil, _property), do: nil

  defp unpack_baseline(packed, property) do
    value = Enum.at(packed, 0) || property["value"]
    baseline = %{"value" => value, "types" => Enum.at(packed, 1) || []}

    if length(packed) >= 3,
      do: baseline |> Map.put("name", Enum.at(packed, 2)) |> Map.put("group", Enum.at(packed, 3)),
      else: baseline
  end

  defp pack_binding("field:" <> rest), do: numeric_binding(rest, 0)
  defp pack_binding("address:" <> rest), do: numeric_binding(rest, 1)
  defp pack_binding("scalar:" <> _), do: [2]
  defp pack_binding("relationship:" <> rest), do: [3, rest |> String.split(":", parts: 2) |> hd()]
  defp pack_binding("tag:" <> rest), do: numeric_binding(rest, 4)
  defp pack_binding("categories:" <> id), do: [5, id]
  defp pack_binding(binding), do: binding

  defp numeric_binding(rest, kind) do
    [id, _name] = String.split(rest, ":", parts: 2)
    [kind, String.to_integer(id)]
  end

  defp unpack_binding([0, id], property, _), do: "field:#{id}:#{property["normalized_name"]}"
  defp unpack_binding([1, id], property, _), do: "address:#{id}:#{property["normalized_name"]}"
  defp unpack_binding([2], property, _), do: "scalar:#{property["normalized_name"]}"

  defp unpack_binding([3, id], property, _),
    do: "relationship:#{id}:#{property["normalized_name"]}"

  defp unpack_binding([4, id], property, _), do: "tag:#{id}:#{property["normalized_name"]}"
  defp unpack_binding([5, id], _property, _entry_id), do: "categories:" <> id
  defp unpack_binding([5], _property, id), do: "categories:" <> id
  defp unpack_binding(binding, _property, _), do: binding

  defp trim_trailing_nil(values),
    do: values |> Enum.reverse() |> Enum.drop_while(&is_nil/1) |> Enum.reverse()

  def capture(contact) do
    previous = stored(contact)
    version = source_version(previous)
    generated = generated(contact, version, snapshot: true)
    refresh(previous, generated, version, contact)
  end

  def accept(contact, raw) when is_binary(raw) do
    {:ok, incoming} = Document.parse(raw)
    accept(contact, incoming)
  end

  def accept(contact, %Document{} = incoming) do
    generated = generated(contact, incoming.source_version, snapshot: true)

    incoming = %{
      incoming
      | properties: Relationships.safe_document_properties(contact, incoming.properties)
    }

    previous = stored(contact)
    previous = Map.put_new(previous, "properties", [])
    accepted = incoming |> bind(generated, previous) |> preserve_occurrence_ids(previous)
    dormant = Enum.filter(previous["properties"], & &1["dormant"])
    %{accepted | "properties" => accepted["properties"] ++ dormant}
  end

  def render(contact, opts \\ []) do
    version = Keyword.get(opts, :version, :v30)
    previous = stored(contact)
    captured = if source_version(previous) == version, do: previous, else: capture(contact)
    generated = generated(contact, version, opts)

    document =
      if source_version(captured) == version,
        do: refresh(captured, generated, version, contact),
        else: convert(captured, generated, version)

    properties =
      document["properties"]
      |> Enum.reject(& &1["dormant"])
      |> coalesce_native_categories()
      |> Enum.map(&decode_property(&1["property"]))

    properties = Relationships.safe_document_properties(contact, properties)

    properties =
      if Keyword.get(opts, :include_photo, true),
        do: properties,
        else: Enum.reject(properties, &(&1.normalized_name == "PHOTO"))

    Document.serialize(%Document{source_version: version, properties: properties})
  end

  def stamp(document, %DateTime{} = modified_at) do
    value =
      if source_version(document) == :v40,
        do: Calendar.strftime(modified_at, "%Y%m%dT%H%M%SZ"),
        else: DateTime.to_iso8601(modified_at)

    property =
      encode_property(%Property{
        name: "REV",
        normalized_name: "REV",
        parameters: [],
        value: value
      })

    entries =
      Enum.map(document["properties"], fn entry ->
        if entry["binding"] == "scalar:REV",
          do:
            entry
            |> Map.put("property", Map.put(entry["property"], "value", value))
            |> Map.put("baseline", baseline(decode_property(property))),
          else: entry
      end)

    entries =
      if Enum.any?(entries, &(&1["binding"] == "scalar:REV")),
        do: entries,
        else:
          entries ++
            [
              %{
                "id" => Ecto.UUID.generate(),
                "binding" => "scalar:REV",
                "property" => property,
                "baseline" => baseline(decode_property(property))
              }
            ]

    %{document | "properties" => entries}
  end

  def fingerprint(contact) do
    document = stored(contact)
    source = source_version(document)
    other = if source == :v30, do: :v40, else: :v30
    source_view = fingerprint_view(contact, document, source)
    other_view = converted_fingerprint_view(contact, document, other)
    views = if source == :v30, do: {source_view, other_view}, else: {other_view, source_view}

    :crypto.hash(:sha256, :erlang.term_to_binary(views, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp converted_fingerprint_view(contact, document, version) do
    document
    |> convert(fingerprint_templates(contact, document, version), version)
    |> then(&fingerprint_view(contact, &1, version))
  rescue
    _ in Kith.DAV.ConversionError -> :supported_address_data_conversion_unavailable
  end

  # The stored document is freshly accepted/captured by the write service.
  # EMAIL/TEL/URL/ADR native canonical values are version-invariant in the
  # existing serializer. Reuse those trusted baselines for this transient
  # fingerprint conversion, regenerating version-sensitive properties only.
  # Actual rendering continues to generate every value from native rows.
  defp fingerprint_templates(contact, document, version) do
    small = generated(contact, version, snapshot: true, skip_fields: true)

    rows =
      document
      |> Map.get("properties", [])
      |> Enum.filter(&invariant_row?/1)
      |> Enum.map(&invariant_template/1)

    small ++ rows
  end

  defp invariant_row?(%{"binding" => "field:" <> _, "baseline" => %{"value" => _}}), do: true
  defp invariant_row?(%{"binding" => "address:" <> _, "baseline" => %{"value" => _}}), do: true
  defp invariant_row?(_entry), do: false

  defp invariant_template(entry) do
    name = entry["property"]["normalized_name"]

    property = %{
      "group" => nil,
      "name" => name,
      "normalized_name" => name,
      "parameters" => [],
      "value" => entry["baseline"]["value"]
    }

    %{entry | "property" => property}
  end

  defp fingerprint_view(contact, document, version) do
    entries = document |> Map.get("properties", []) |> Enum.reject(& &1["dormant"])
    entries = normalize_snapshot_photo(entries, contact, version)
    entries |> safe_entries(contact) |> coalesce_native_categories() |> Enum.map(&wire_syntax/1)
  end

  defp wire_syntax(entry) do
    property = entry["property"]
    value = if property["normalized_name"] == "REV", do: "__KITH_REV__", else: property["value"]
    {property["group"], property["name"], Enum.map(property["parameters"], & &1["raw"]), value}
  end

  defp normalize_snapshot_photo(entries, contact, version) do
    if Enum.any?(entries, &(&1["binding"] == "scalar:PHOTO")) do
      reference = avatar_property(contact, version)

      Enum.map(entries, &normalize_photo_entry(&1, reference, version))
    else
      entries
    end
  end

  defp normalize_photo_entry(%{"binding" => "scalar:PHOTO"} = entry, reference, version),
    do: %{
      entry
      | "property" =>
          entry["property"]
          |> Map.put("value", reference["value"])
          |> replace_type(nil, reference, version)
    }

  defp normalize_photo_entry(entry, _reference, _version), do: entry

  defp safe_entries(entries, contact) do
    related =
      entries
      |> Enum.filter(&(&1["property"]["normalized_name"] in ["RELATED", "X-KITH-RELATED"]))
      |> Enum.map(&decode_property(&1["property"]))

    if related == [] do
      entries
    else
      safe = contact |> Relationships.safe_document_properties(related) |> MapSet.new()
      removed = Enum.reject(related, &MapSet.member?(safe, &1))
      groups = removed |> Enum.map(& &1.group) |> Enum.reject(&is_nil/1) |> MapSet.new()
      removed = MapSet.new(Enum.map(removed, &encode_property/1))

      Enum.reject(
        entries,
        &(MapSet.member?(groups, &1["property"]["group"]) or
            MapSet.member?(removed, &1["property"]))
      )
    end
  end

  defp stored(contact) do
    case Map.get(contact, :dav) do
      dav when is_map(dav) -> unpack(Map.get(dav, :document) || %{})
      _ -> %{}
    end
  end

  defp source_version(%{"source_version" => "v40"}), do: :v40
  defp source_version(_), do: :v30

  defp generated(contact, version, opts) do
    snapshot? = Keyword.get(opts, :snapshot, false)
    project_opts = if snapshot?, do: Keyword.put(opts, :include_photo, false), else: opts
    shared = SharedContact.project(contact, project_opts)

    {:ok, document} =
      shared |> Serializer.serialize(version: version, include_uid: true) |> Document.parse()

    document = expand_categories(document, shared.tags)
    document = if snapshot?, do: avatar_reference(document, contact), else: document
    queues = token_queues(shared)
    tags = Map.new(shared.tags, &{to_string(&1.id), &1})
    relationships = Map.new(shared.relationships, &{to_string(&1.id), &1})

    {entries, _} =
      Enum.map_reduce(document.properties, queues, fn property, queues ->
        {token, queues} = token(property, queues)

        entry = %{
          "id" => Ecto.UUID.generate(),
          "property" => encode_property(property),
          "binding" => token,
          "baseline" => baseline(property)
        }

        entry = category_binding(entry, tags)
        entry = relationship_binding(entry, relationships)
        {entry, queues}
      end)

    entries
  end

  def category_values(value) do
    Regex.split(~r/(?<!\\)(?:\\\\)*\K,/, value)
    |> Enum.map(&unescape/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp coalesce_native_categories(entries) do
    if Enum.any?(entries, &native_category?/1),
      do: coalesce_category_chunks(entries),
      else: entries
  end

  defp coalesce_category_chunks(entries) do
    entries
    |> Enum.chunk_by(&native_category?/1)
    |> Enum.flat_map(fn chunk ->
      if native_category?(hd(chunk)) do
        first = hd(chunk)
        value = Enum.map_join(chunk, ",", & &1["property"]["value"])
        [%{first | "property" => Map.put(first["property"], "value", value)}]
      else
        chunk
      end
    end)
  end

  defp native_category?(%{
         "binding" => "tag:" <> _,
         "property" => %{"group" => nil, "parameters" => []}
       }),
       do: true

  defp native_category?(_), do: false

  defp expand_categories(document, tags) do
    categories =
      Enum.map(
        tags,
        &%Property{
          name: "CATEGORIES",
          normalized_name: "CATEGORIES",
          parameters: [],
          value: Serializer.escape(&1.name)
        }
      )

    properties =
      Enum.flat_map(document.properties, fn property ->
        if property.normalized_name == "CATEGORIES", do: categories, else: [property]
      end)

    %{document | properties: properties}
  end

  defp category_binding(%{"binding" => "tag:" <> binding} = entry, tags) do
    [id, _name] = String.split(binding, ":", parts: 2)

    case Map.get(tags, id) do
      nil -> entry
      tag -> Map.put(entry, "category_bindings", [%{"id" => tag.id, "value" => tag.name}])
    end
  end

  defp category_binding(entry, _tags), do: entry

  defp relationship_binding(%{"binding" => "relationship:" <> binding} = entry, relationships) do
    [id, _name] = String.split(binding, ":", parts: 2)

    case Map.get(relationships, id) do
      nil ->
        entry

      view ->
        Map.put(
          entry,
          "native_bindings",
          Enum.map(view.bindings, &%{"id" => &1.id, "direction" => Atom.to_string(&1.direction)})
        )
    end
  end

  defp relationship_binding(entry, _), do: entry

  defp avatar_reference(document, %{avatar: key} = contact) when is_binary(key) do
    property = contact |> avatar_property(document.source_version) |> decode_property()
    %{document | properties: document.properties ++ [property]}
  end

  defp avatar_reference(document, _), do: document

  defp avatar_property(contact, version) do
    parameters =
      if version == :v30,
        do: [parameter("ENCODING", ["b"], version), parameter("TYPE", ["JPEG"], version)],
        else: []

    %{
      "group" => nil,
      "name" => "PHOTO",
      "normalized_name" => "PHOTO",
      "parameters" => parameters,
      "value" => "urn:kith:avatar:" <> SharedContact.avatar_fingerprint(contact)
    }
  end

  defp token_queues(shared) do
    fields = Enum.group_by(shared.contact_fields, & &1.contact_field_type.vcard_label)

    field_tokens =
      Map.new(fields, fn {name, values} ->
        {name, Enum.map(values, &("field:" <> to_string(&1.id)))}
      end)

    relationships = Enum.map(shared.relationships, &("relationship:" <> to_string(&1.id)))

    Map.merge(field_tokens, %{
      "ADR" => Enum.map(shared.addresses, &("address:" <> to_string(&1.id))),
      "CATEGORIES" => Enum.map(shared.tags, &("tag:" <> to_string(&1.id))),
      "RELATED" => relationships,
      "X-KITH-RELATED" => relationships,
      "X-ABRELATEDNAMES" => relationships,
      "X-ABLABEL" => relationships
    })
  end

  defp token(%{normalized_name: name}, queues) when name in @server or name in @scalar,
    do: {"scalar:" <> name, queues}

  defp token(%{normalized_name: name}, queues) do
    case Map.get(queues, name, []) do
      [token | rest] -> {token <> ":" <> name, Map.put(queues, name, rest)}
      [] -> {nil, queues}
    end
  end

  defp bind(document, generated, previous) do
    sources = property_sources(document.properties)

    prior_identities = bound_identities(previous)
    counts = Enum.frequencies_by(document.properties, & &1.normalized_name)

    last_photo =
      document.properties
      |> Enum.with_index()
      |> Enum.filter(fn {property, _index} -> property.normalized_name == "PHOTO" end)
      |> List.last()

    index = generated_index(generated, :bind)

    {entries, index} =
      Enum.map_reduce(Enum.with_index(document.properties), index, fn {property, position},
                                                                      index ->
        primary? = counts[property.normalized_name] == 1 or last_photo == {property, position}
        raw = encode_property(property)
        identity_keys = identity_binding_keys(raw, sources, prior_identities)
        bind_property(property, raw, index, primary?, identity_keys)
      end)

    entries =
      entries
      |> Enum.reject(&(server_entry?(&1) and is_nil(&1["binding"])))
      |> Kernel.++(DocumentIndex.remaining(index))
      |> attach_group_dependencies()

    entries = order_version(entries)

    %{
      "schema_version" => 1,
      "source_version" => Atom.to_string(document.source_version),
      "properties" => entries
    }
  end

  defp bind_property(
         %{normalized_name: "CATEGORIES"} = property,
         raw,
         index,
         _primary?,
         _identity_keys
       ) do
    targets =
      property.value
      |> category_values()
      |> Enum.map(&Map.get(index.category_names, &1))
      |> Enum.reject(&is_nil/1)

    refs = targets |> Enum.flat_map(& &1["category_bindings"]) |> Enum.uniq_by(& &1["id"])
    index = consume_categories(index, refs)
    id = Ecto.UUID.generate()

    entry = %{
      "id" => id,
      "property" => raw,
      "binding" => if(refs == [], do: nil, else: "categories:" <> id),
      "baseline" => baseline(property)
    }

    entry = if refs == [], do: entry, else: Map.put(entry, "category_bindings", refs)
    {entry, index}
  end

  defp bind_property(property, raw, index, primary?, identity_keys) do
    value_key = value_key(raw)

    typed =
      Enum.map(
        type_candidates(property_types(raw)),
        &{:typed, {value_key, &1}}
      )

    names =
      if primary? and property.normalized_name in (@scalar ++ @server),
        do: [{:name, property.normalized_name}],
        else: []

    {target, index} =
      DocumentIndex.take_first(
        index,
        identity_keys ++
          typed ++ [{:value, {value_key, false}}, {:value, {value_key, true}}] ++ names
      )

    if target do
      {%{target | "property" => bound_property(property, raw, target)}, index}
    else
      entry = %{
        "id" => Ecto.UUID.generate(),
        "property" => raw,
        "binding" => nil
      }

      owned? =
        property.normalized_name in @scalar and property.normalized_name != "PHOTO" and
          DocumentIndex.contains?(index, :name, property.normalized_name)

      entry = if owned?, do: Map.put(entry, "scalar_owner", property.normalized_name), else: entry
      {entry, index}
    end
  end

  defp consume_categories(index, refs) do
    Enum.reduce(refs, index, fn ref, index ->
      {_entry, index} =
        DocumentIndex.take_first(index, [{:binding, "tag:#{ref["id"]}:CATEGORIES"}])

      index
    end)
  end

  defp bound_identities(document) do
    sources = identity_sources(document["properties"])

    Enum.reduce(document["properties"], %{}, fn entry, acc ->
      keys =
        Enum.map(
          identity_pids(entry["property"], sources),
          &{entry["property"]["normalized_name"], &1}
        )

      if entry["binding"],
        do: Enum.reduce(keys, acc, &Map.put(&2, &1, entry["binding"])),
        else: acc
    end)
  end

  defp identity_binding_keys(_property, _sources, prior) when map_size(prior) == 0, do: []

  defp identity_binding_keys(property, sources, prior) do
    identities =
      if related_text?(property), do: MapSet.new(), else: identity_pids(property, sources)

    identities
    |> Enum.flat_map(fn identity ->
      case Map.get(prior, {property["normalized_name"], identity}) do
        nil -> []
        binding -> [{:binding, binding}]
      end
    end)
  end

  defp generated_index(entries, mode) do
    base = %{binding: &binding_keys/1, native: &native_keys/1}

    definitions =
      if mode == :bind,
        do:
          Map.merge(base, %{
            typed: &typed_keys/1,
            value: fn entry ->
              [{value_key(entry["property"]), property_types(entry["property"]) != []}]
            end,
            name: &scalar_name_keys/1
          }),
        else: base

    index = DocumentIndex.new(entries, definitions)

    categories =
      entries
      |> Enum.filter(& &1["category_bindings"])
      |> Enum.map(fn entry -> {hd(entry["category_bindings"])["id"], entry} end)
      |> Map.new()

    names =
      Map.new(categories, fn {_id, entry} -> {hd(entry["category_bindings"])["value"], entry} end)

    index |> Map.put(:categories, categories) |> Map.put(:category_names, names)
  end

  defp typed_keys(entry) do
    case property_types(entry["property"]) do
      [] -> []
      types -> [{value_key(entry["property"]), types}]
    end
  end

  defp scalar_name_keys(%{"property" => %{"normalized_name" => name}})
       when name in @server or name in @scalar, do: [name]

  defp scalar_name_keys(_entry), do: []

  defp binding_keys(%{"binding" => binding}) when is_binary(binding), do: [binding]
  defp binding_keys(_), do: []

  defp native_keys(entry),
    do:
      Enum.map(
        Map.get(entry, "native_bindings", []),
        &{&1["id"], entry["property"]["normalized_name"]}
      )

  defp value_key(%{"normalized_name" => name} = property)
       when name in ["RELATED", "X-KITH-RELATED"] do
    value = Parser.unescape(property["value"])

    semantic =
      if related_text?(property), do: {:text, value}, else: {:uri, canonical_related_uri(value)}

    {name, semantic}
  end

  defp value_key(property),
    do:
      {property["normalized_name"],
       semantic_value(%{normalized_name: property["normalized_name"], value: property["value"]})}

  defp related_text?(%{"normalized_name" => name} = property)
       when name in ["RELATED", "X-KITH-RELATED"] do
    property["parameters"]
    |> Enum.filter(&(&1["normalized_name"] == "VALUE"))
    |> Enum.flat_map(& &1["values"])
    |> List.last()
    |> case do
      value when is_binary(value) -> String.downcase(value) == "text"
      _ -> false
    end
  end

  defp related_text?(_property), do: false

  defp canonical_related_uri(value) do
    case UID.normalize(value) do
      {:ok, uid} -> UID.urn(uid)
      _ -> value
    end
  end

  defp property_types(%{"types" => types}), do: types
  defp property_types(%{"parameters" => []}), do: []

  defp property_types(property) do
    property["parameters"]
    |> Enum.filter(&(&1["normalized_name"] == "TYPE"))
    |> Enum.flat_map(& &1["values"])
    |> Enum.flat_map(&SharedContact.type_tokens/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp type_candidates([]), do: []
  defp type_candidates(types), do: Enum.uniq([types | Enum.map(types, &[&1])])

  defp attach_group_dependencies(entries) do
    groups = Enum.reduce(entries, %{}, &group_owner/2)
    Enum.map(entries, &group_dependency(&1, groups))
  end

  defp group_owner(%{"category_bindings" => refs, "property" => %{"group" => group}}, groups)
       when is_binary(group) do
    owners = Enum.map(refs, &%{binding: "tag:#{&1["id"]}:CATEGORIES", native: []})
    Map.update(groups, group, owners, &(owners ++ &1))
  end

  defp group_owner(%{"binding" => binding, "property" => %{"group" => group}} = entry, groups)
       when is_binary(binding) and is_binary(group) do
    owner = %{binding: binding, native: Map.get(entry, "native_bindings", [])}
    Map.update(groups, group, [owner], &[owner | &1])
  end

  defp group_owner(_entry, groups), do: groups

  defp group_dependency(
         %{"binding" => nil, "property" => %{"group" => group, "normalized_name" => name}} = entry,
         groups
       )
       when name in @companions do
    case Map.get(groups, group) do
      nil ->
        entry

      owners ->
        entry
        |> Map.put("dependencies", Enum.map(owners, & &1.binding))
        |> Map.put("native_bindings", Enum.flat_map(owners, & &1.native))
    end
  end

  defp group_dependency(entry, _groups), do: entry

  defp bound_property(property, raw, target) do
    cond do
      property.normalized_name in ["RELATED", "X-KITH-RELATED"] and not related_text?(raw) ->
        Map.put(raw, "value", target["property"]["value"])

      property.normalized_name in (@scalar ++ @server) and
          semantic_value(property) != semantic_value(decode_property(target["property"])) ->
        Map.put(raw, "value", overlay_value(raw, target["property"]))

      true ->
        raw
    end
  end

  defp exact_property_keys(%{"binding" => nil, "property" => property}), do: [property]

  defp exact_property_keys(%{"binding" => "categories:" <> _, "property" => property}),
    do: [property]

  defp exact_property_keys(_entry), do: []

  defp preserve_occurrence_ids(document, previous) do
    version = source_version(document)
    old_sources = identity_sources(Map.get(previous, "properties", []))
    new_sources = identity_sources(document["properties"])

    definitions = %{
      binding: fn entry -> Enum.map(binding_keys(entry), &converted_binding(&1, version)) end,
      property: &exact_property_keys/1,
      pid: fn entry ->
        Enum.map(
          identity_pids(entry["property"], old_sources),
          &{entry["property"]["normalized_name"], &1}
        )
      end
    }

    index = DocumentIndex.new(Map.get(previous, "properties", []), definitions)

    {properties, _index} =
      Enum.map_reduce(document["properties"], index, fn entry, index ->
        keys =
          Enum.map(binding_keys(entry), &{:binding, &1}) ++
            [{:property, entry["property"]}] ++
            Enum.map(
              identity_pids(entry["property"], new_sources),
              &{:pid, {entry["property"]["normalized_name"], &1}}
            )

        {old, index} = DocumentIndex.take_first(index, keys)
        updated = if old, do: %{entry | "id" => old["id"]}, else: entry
        {updated, index}
      end)

    %{document | "properties" => properties}
  end

  defp identity_sources(entries), do: property_sources(Enum.map(entries, & &1["property"]))

  defp property_sources(properties) do
    case PropertyIdentity.sources(properties) do
      {:ok, sources} -> sources
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp identity_pids(property, sources), do: PropertyIdentity.pids(property, sources)

  defp semantic_value(%{normalized_name: name, value: value}) when name in ["N", "ORG", "ADR"] do
    parts = value |> split_components() |> Enum.map(&unescape/1)

    case name do
      "N" -> Enum.take(parts, 3)
      "ORG" -> Enum.take(parts, 1)
      "ADR" -> Enum.drop(parts, 1)
    end
  end

  defp semantic_value(%{normalized_name: "TEL", value: value}),
    do: value |> Parser.unescape() |> Parser.phone_value()

  defp semantic_value(property), do: unescape(property.value)

  defp unescape(value), do: Parser.unescape(value)

  defp refresh(%{"properties" => old}, generated, version, contact) do
    index = generated_index(generated, :refresh)
    {entries, index} = Enum.map_reduce(old, index, &refresh_entry(&1, &2, contact, version))

    %{
      "schema_version" => 1,
      "source_version" => Atom.to_string(version),
      "properties" =>
        order_version(Enum.reject(entries, &is_nil/1) ++ DocumentIndex.remaining(index))
    }
  end

  defp refresh(_, generated, version, _contact),
    do: %{
      "schema_version" => 1,
      "source_version" => Atom.to_string(version),
      "properties" => generated
    }

  defp refresh_entry(%{"category_bindings" => refs} = entry, index, _contact, _version) do
    current =
      refs
      |> Enum.flat_map(fn ref ->
        case Map.get(index.categories, ref["id"]) do
          nil -> []
          target -> target["category_bindings"]
        end
      end)

    index = consume_categories(index, current)

    if current == [] do
      {nil, index}
    else
      property =
        if current == refs,
          do: entry["property"],
          else:
            Map.put(
              entry["property"],
              "value",
              Enum.map_join(current, ",", &Serializer.escape(&1["value"]))
            )

      {entry |> Map.put("property", property) |> Map.put("category_bindings", current), index}
    end
  end

  defp refresh_entry(entry, index, contact, version) do
    keys =
      Enum.map(binding_keys(entry), &{:binding, &1}) ++
        Enum.map(native_keys(entry), &{:native, &1})

    {target, index} = DocumentIndex.take_first(index, keys)

    if target do
      updated =
        entry
        |> Map.put("property", overlay(entry, target, version))
        |> Map.put("baseline", target["baseline"])
        |> Map.put("binding", target["binding"])
        |> Map.delete("dormant")

      updated =
        if target["native_bindings"],
          do: Map.put(updated, "native_bindings", target["native_bindings"]),
          else: updated

      {updated, index}
    else
      {retain_unbound(entry, contact, index), index}
    end
  end

  defp retain_unbound(entry, contact, index) do
    dependencies = Map.get(entry, "dependencies", [])
    scalar_owner = entry["scalar_owner"]

    cond do
      is_binary(scalar_owner) and
          not DocumentIndex.contains?(index, :binding, "scalar:" <> scalar_owner) ->
        nil

      Enum.any?(dependencies, &DocumentIndex.contains?(index, :binding, &1)) ->
        entry

      native_binding_alive?(entry, contact) ->
        Map.put(entry, "dormant", true)

      entry["binding"] ->
        nil

      dependencies != [] ->
        nil

      true ->
        entry
    end
  end

  defp native_binding_alive?(entry, contact) do
    ids = Enum.map(Map.get(entry, "native_bindings", []), & &1["id"])

    ids != [] and
      Repo.exists?(
        from(r in Relationship,
          where:
            r.account_id == ^contact.account_id and r.id in ^ids and
              (r.contact_id == ^contact.id or r.related_contact_id == ^contact.id)
        )
      )
  end

  defp overlay(%{"binding" => "scalar:PHOTO", "property" => property}, target, version),
    do:
      property
      |> Map.put("value", target["property"]["value"])
      |> replace_type(nil, target["property"], version)

  defp overlay(
         %{
           "binding" => "relationship:" <> _,
           "property" => %{"normalized_name" => name} = property,
           "baseline" => baseline
         },
         target,
         version
       )
       when name in ["RELATED", "X-KITH-RELATED"],
       do:
         overlay_components(
           Map.put(property, "value", target["property"]["value"]),
           baseline,
           target,
           version
         )

  defp overlay(%{"property" => property, "baseline" => baseline}, target, version),
    do: overlay_components(property, baseline, target, version)

  defp overlay_components(property, baseline, target, version) do
    canonical = target["property"]

    if baseline == target["baseline"] do
      property
    else
      uri? = tel_uri?(property)
      property = Map.put(property, "value", overlay_value(property, canonical))
      property = coherent_tel_value(property, uri?, version)

      if property_types(baseline) == property_types(target["baseline"]),
        do: property,
        else: replace_type(property, baseline, canonical, version)
    end
  end

  defp overlay_value(%{"normalized_name" => name, "value" => value}, canonical)
       when name in ["N", "ORG", "ADR"] do
    previous = split_components(value)
    fresh = split_components(canonical["value"])

    case name do
      "N" -> Enum.take(fresh, 3) ++ Enum.drop(previous, 3)
      "ORG" -> Enum.take(fresh, 1) ++ Enum.drop(previous, 1)
      "ADR" -> Enum.take(previous, 1) ++ Enum.drop(fresh, 1)
    end
    |> Enum.join(";")
  end

  defp overlay_value(%{"normalized_name" => "TEL"} = property, canonical) do
    candidate = "tel:" <> (canonical["value"] |> Parser.unescape() |> Parser.phone_value())
    if tel_uri?(property) and safe_tel_uri?(candidate), do: candidate, else: canonical["value"]
  end

  defp overlay_value(_, canonical), do: canonical["value"]

  defp tel_uri?(%{"normalized_name" => "TEL"} = property) do
    value_type =
      property["parameters"]
      |> Enum.filter(&(&1["normalized_name"] == "VALUE"))
      |> Enum.flat_map(& &1["values"])
      |> List.last()

    case value_type do
      value when is_binary(value) -> String.downcase(value) == "uri"
      _ -> Regex.match?(~r/\Atel:/i, property["value"])
    end
  end

  defp tel_uri?(_property), do: false

  defp safe_tel_uri?(value),
    do: not Regex.match?(~r/[\x00-\x20\x7F-\x{10FFFF}\\"]|%(?![0-9A-Fa-f]{2})/u, value)

  defp coherent_tel_value(property, true, version) do
    if safe_tel_uri?(property["value"]) and Regex.match?(~r/\Atel:/i, property["value"]) do
      property
    else
      parameters = Enum.reject(property["parameters"], &(&1["normalized_name"] == "VALUE"))
      Map.put(property, "parameters", parameters ++ [parameter("VALUE", ["text"], version)])
    end
  end

  defp coherent_tel_value(property, _uri?, _version), do: property

  defp replace_type(%{"normalized_name" => "PHOTO"} = property, _baseline, canonical, _version) do
    metadata =
      Enum.reject(
        property["parameters"],
        &(&1["normalized_name"] in ~w(TYPE ENCODING MEDIATYPE VALUE))
      )

    Map.put(property, "parameters", metadata ++ canonical["parameters"])
  end

  defp replace_type(property, baseline, canonical, version) do
    owned = MapSet.new(property_types(baseline))

    fresh =
      canonical["parameters"]
      |> Enum.filter(&(&1["normalized_name"] == "TYPE"))
      |> Enum.flat_map(& &1["values"])
      |> Enum.flat_map(&String.split(&1, ","))

    {parameters, inserted?} =
      Enum.map_reduce(
        property["parameters"],
        false,
        &overlay_type_parameter(&1, &2, owned, fresh, version)
      )

    parameters = Enum.reject(parameters, &is_nil/1)

    parameters =
      if inserted? or fresh == [],
        do: parameters,
        else: parameters ++ [parameter("TYPE", fresh, version)]

    Map.put(property, "parameters", parameters)
  end

  defp overlay_type_parameter(
         %{"normalized_name" => "TYPE"} = param,
         inserted?,
         owned,
         fresh,
         version
       ) do
    tokens = Enum.flat_map(param["values"], &String.split(&1, ","))
    extras = Enum.reject(tokens, &owned_type?(&1, owned))

    if extras == tokens do
      {param, inserted?}
    else
      values = if inserted?, do: extras, else: fresh ++ extras
      updated = if values == [], do: nil, else: parameter(param["name"], values, version)
      {updated, true}
    end
  end

  defp overlay_type_parameter(param, inserted?, _owned, _fresh, _version), do: {param, inserted?}

  defp owned_type?(token, owned),
    do: Enum.any?(SharedContact.type_tokens(token), &MapSet.member?(owned, &1))

  defp convert(document, generated, version) do
    public_entries = Map.get(document, "properties", []) |> Enum.reject(& &1["dormant"])

    index = DocumentIndex.new(generated, %{binding: &binding_keys/1})
    {entries, index} = Enum.map_reduce(public_entries, index, &convert_entry(&1, &2, version))

    %{
      "source_version" => Atom.to_string(version),
      "properties" =>
        order_version(Enum.reject(entries, &is_nil/1) ++ DocumentIndex.remaining(index))
    }
  end

  defp convert_entry(%{"category_bindings" => refs} = entry, index, version) do
    index = consume_categories(index, refs)
    {%{entry | "property" => convert_parameters(entry["property"], version)}, index}
  end

  defp convert_entry(entry, index, version) do
    keys = Enum.map(binding_keys(entry), &{:binding, converted_binding(&1, version)})
    {target, index} = DocumentIndex.take_first(index, keys)
    property = convert_parameters(entry["property"], version)

    if target do
      canonical = target["property"]

      property =
        property
        |> Map.put("name", canonical["name"])
        |> Map.put("normalized_name", canonical["normalized_name"])
        |> Map.put("value", converted_value(property, canonical))
        |> replace_representation_parameters(canonical)

      {%{
         entry
         | "property" => property,
           "binding" => target["binding"],
           "baseline" => target["baseline"]
       }, index}
    else
      {converted_unbound(entry, property, version), index}
    end
  end

  defp converted_value(%{"normalized_name" => "TEL"}, canonical), do: canonical["value"]
  defp converted_value(property, canonical), do: overlay_value(property, canonical)

  defp converted_unbound(entry, property, version) do
    if generated_companion?(entry),
      do: nil,
      else: %{entry | "property" => convert_client_property(property, version)}
  end

  defp generated_companion?(entry) do
    is_binary(entry["binding"]) and
      entry["property"]["normalized_name"] in ["X-ABRELATEDNAMES", "X-ABLABEL"] and
      companion_syntax_unchanged?(entry)
  end

  defp companion_syntax_unchanged?(entry) do
    property = entry["property"]
    baseline = entry["baseline"]

    property["value"] == baseline["value"] and property["name"] == baseline["name"] and
      property["group"] == baseline["group"] and property["parameters"] == []
  end

  defp replace_representation_parameters(property, canonical) do
    owned =
      if property["normalized_name"] == "PHOTO",
        do: ~w(VALUE ENCODING MEDIATYPE TYPE),
        else: ~w(VALUE ENCODING)

    metadata = Enum.reject(property["parameters"], &(&1["normalized_name"] in owned))
    representation = Enum.filter(canonical["parameters"], &(&1["normalized_name"] in owned))
    Map.put(property, "parameters", metadata ++ representation)
  end

  defp convert_client_property(%{"normalized_name" => "RELATED"} = property, :v30),
    do:
      property
      |> Map.put("name", "X-KITH-RELATED")
      |> Map.put("normalized_name", "X-KITH-RELATED")

  defp convert_client_property(%{"normalized_name" => "X-KITH-RELATED"} = property, :v40),
    do: property |> Map.put("name", "RELATED") |> Map.put("normalized_name", "RELATED")

  defp convert_client_property(%{"normalized_name" => "PHOTO"} = property, :v40) do
    params = Map.new(property["parameters"], &{&1["normalized_name"], &1["values"]})

    if String.upcase(params |> Map.get("ENCODING", [""]) |> hd()) in ["B", "BASE64"] do
      type = params |> Map.get("TYPE", ["JPEG"]) |> hd() |> String.downcase()

      %{
        property
        | "value" => "data:image/" <> type <> ";base64," <> property["value"],
          "parameters" =>
            Enum.reject(
              property["parameters"],
              &(&1["normalized_name"] in ~w(TYPE ENCODING VALUE))
            )
      }
    else
      property
    end
  end

  defp convert_client_property(
         %{"normalized_name" => "PHOTO", "value" => "data:" <> _} = property,
         :v30
       ) do
    case Regex.run(~r/\Adata:image\/([A-Za-z0-9.+-]+);base64,(.*)\z/s, property["value"]) do
      [_, type, value] ->
        params =
          Enum.reject(
            property["parameters"],
            &(&1["normalized_name"] in ~w(TYPE ENCODING VALUE MEDIATYPE))
          )

        %{
          property
          | "value" => value,
            "parameters" =>
              params ++
                [
                  parameter("ENCODING", ["b"], :v30),
                  parameter("TYPE", [String.upcase(type)], :v30)
                ]
        }

      _ ->
        raise Kith.DAV.ConversionError
    end
  end

  defp convert_client_property(property, _version), do: property

  defp convert_parameters(property, version),
    do:
      Map.update!(
        property,
        "parameters",
        &Enum.map(&1, fn param -> parameter(param["name"], param["values"], version) end)
      )

  defp parameter(name, values, version) do
    raw = name <> "=" <> Enum.map_join(values, ",", &encode_parameter(&1, version))
    %{"name" => name, "normalized_name" => String.upcase(name), "values" => values, "raw" => raw}
  end

  defp encode_parameter(value, :v30) do
    if String.contains?(value, ["\"", "\n", "\r"]), do: raise(Kith.DAV.ConversionError)
    quote_parameter(value)
  end

  defp encode_parameter(value, :v40) do
    value
    |> String.replace("^", "^^")
    |> String.replace("\n", "^n")
    |> String.replace("\"", "^'")
    |> quote_parameter()
  end

  defp quote_parameter(value) do
    if String.contains?(value, [":", ";", ","]), do: "\"" <> value <> "\"", else: value
  end

  defp converted_binding(nil, _), do: nil

  defp converted_binding(binding, :v40),
    do: String.replace_suffix(binding, ":X-KITH-RELATED", ":RELATED")

  defp converted_binding(binding, :v30),
    do: String.replace_suffix(binding, ":RELATED", ":X-KITH-RELATED")

  defp server_entry?(entry), do: entry["property"]["normalized_name"] in @server

  defp order_version(entries),
    do:
      Enum.filter(entries, &(&1["property"]["normalized_name"] == "VERSION")) ++
        Enum.reject(entries, &(&1["property"]["normalized_name"] == "VERSION"))

  defp split_components(value), do: Regex.split(~r/(?<!\\)(?:\\\\)*\K;/, value)

  defp baseline(property) do
    types =
      property.parameters
      |> Enum.filter(&(&1.normalized_name == "TYPE"))
      |> Enum.flat_map(& &1.values)
      |> Enum.flat_map(&SharedContact.type_tokens/1)
      |> Enum.uniq()
      |> Enum.sort()

    base = %{"value" => property.value, "types" => types}

    if property.normalized_name in ["X-ABRELATEDNAMES", "X-ABLABEL"],
      do: base |> Map.put("name", property.name) |> Map.put("group", property.group),
      else: base
  end

  defp encode_property(property),
    do: %{
      "group" => property.group,
      "name" => property.name,
      "normalized_name" => property.normalized_name,
      "value" => property.value,
      "parameters" =>
        Enum.map(
          property.parameters,
          &%{
            "name" => &1.name,
            "normalized_name" => &1.normalized_name,
            "raw" => &1.raw,
            "values" => &1.values
          }
        )
    }

  defp decode_property(property),
    do: %Property{
      group: property["group"],
      name: property["name"],
      normalized_name: property["normalized_name"],
      value: property["value"],
      parameters:
        Enum.map(
          property["parameters"],
          &struct(Parameter, %{
            name: &1["name"],
            normalized_name: &1["normalized_name"],
            raw: &1["raw"],
            values: &1["values"]
          })
        )
    }
end
