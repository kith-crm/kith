defmodule Kith.VCard.Metadata do
  @moduledoc "Preserves client vCard data that has no native Kith field."

  alias Kith.VCard.Parser

  @mapped ~w(BEGIN END VERSION UID REV PHOTO FN N NICKNAME BDAY X-KITH-BDAY ORG TITLE NOTE GENDER X-GENDER CATEGORIES EMAIL TEL ADR URL IMPP RELATED X-KITH-RELATED)

  # Social profiles are parsed into native URL fields (CDV-86).
  @social %{"X-SOCIALPROFILE" => nil, "X-TWITTER" => "twitter", "X-INSTAGRAM" => "instagram"}

  @doc """
  Overlays retained metadata only while the corresponding native value still
  matches. A retained property Kith maps natively, or any other member of its
  `group.`, only decorates a native line that is still emitted: it is never
  re-emitted on its own after the native child is gone (CDV-87).
  """
  def merge(lines, contact, version) do
    properties = Map.get(contact, :dav_vcard, %{}) |> Map.get("properties", [])
    {lines, _unused} = Enum.map_reduce(lines, properties, &restore/2)
    emitted = MapSet.new(lines)
    emitted_groups = MapSet.new(lines, &group/1)

    native_groups =
      properties
      |> Enum.filter(&native?/1)
      |> MapSet.new(&group(&1["head"]))
      |> MapSet.delete(nil)

    extras =
      Enum.reject(properties, fn property ->
        group = group(property["head"])

        native?(property) or
          (MapSet.member?(native_groups, group) and not MapSet.member?(emitted_groups, group)) or
          MapSet.member?(emitted, render(property))
      end)
      |> Enum.map(&render/1)

    {body, [ending]} = Enum.split(lines, -1)

    (body ++ extras ++ [ending])
    |> Enum.flat_map(&version_syntax(&1, version))
    |> delivery_labels(version)
    |> Enum.map(fn line ->
      line |> convert(version) |> telephone_value(version) |> declare_identifier_type(version)
    end)
  end

  # ── Version-specific syntax (CDV-92) ────────────────────────────────────
  # Retained lines are written in the client's version. Syntax the other
  # version lacks is converted where RFC 6350 defines a mapping (3.0 LABEL ↔
  # 4.0 ADR LABEL=, ENCODING=b ↔ data: URI) and dropped otherwise.

  @v30_only ~w(AGENT NAME MAILER CLASS PROFILE SORT-STRING)
  @v40_only ~w(KIND GENDER ANNIVERSARY LANG MEMBER CLIENTPIDMAP XML)
  @v30_params ~w(CHARSET)
  @v40_params ~w(PID ALTID CALSCALE SORT-AS GEO TZ MEDIATYPE INDEX LEVEL CC)
  @v30_uri ~w(PHOTO LOGO SOUND AGENT)
  @media %{"PGP" => "application/pgp-keys", "X509" => "application/pkix-cert"}

  defp version_syntax(line, version) do
    {head, value} = Parser.split_line(line)
    [name | params] = Parser.split_params(head)
    property = name |> String.split(".") |> List.last() |> String.upcase()

    cond do
      property in ["PHOTO", "BEGIN", "END", "VERSION"] -> [line]
      version == :v40 and property in @v30_only -> []
      version == :v30 and property in @v40_only -> []
      true -> [rebuild(name, version_params(property, params, value, version))]
    end
  end

  defp version_params(property, params, value, :v40) do
    params = Enum.reject(params, &(param_key(&1) in @v30_params))
    {encoding, params} = Enum.split_with(params, &(param_key(&1) == "ENCODING"))

    if Enum.any?(encoding, &(param_raw(&1) |> String.upcase() |> Kernel.in(["B", "BASE64"]))) do
      {types, params} = Enum.split_with(params, &(param_key(&1) == "TYPE"))
      params = Enum.reject(params, &(param_key(&1) == "VALUE"))
      type = types |> Enum.map(&param_raw/1) |> List.first()
      {params, "data:" <> media_type(property, type) <> ";base64," <> value}
    else
      {params, value}
    end
  end

  defp version_params(property, params, value, :v30) do
    params = Enum.reject(params, &(param_key(&1) in @v40_params))

    case Regex.run(~r/\Adata:([^;,]+)[^,]*;base64,(.*)\z/s, value) do
      [_, media, data] when property != "PHOTO" ->
        params = Enum.reject(params, &(param_key(&1) in ["TYPE", "VALUE"]))
        {params ++ ["ENCODING=b", "TYPE=" <> media_name(media)], data}

      _ ->
        uri? = property in @v30_uri or property == "TEL"

        {Enum.reject(
           params,
           &(param_key(&1) == "VALUE" and not uri? and
               String.downcase(param_raw(&1)) == "uri")
         ), value}
    end
  end

  defp media_type(property, nil), do: media_type(property, "octet-stream")

  defp media_type(property, type) do
    case {property, String.upcase(type)} do
      {_, type} when is_map_key(@media, type) -> @media[type]
      {"SOUND", type} -> "audio/" <> String.downcase(type)
      {_, type} when property in ["LOGO", "PHOTO"] -> "image/" <> String.downcase(type)
      {_, "OCTET-STREAM"} -> "application/octet-stream"
      {_, type} -> "application/" <> String.downcase(type)
    end
  end

  defp media_name(media) do
    case Enum.find(@media, fn {_name, type} -> type == String.downcase(media) end) do
      {name, _} -> name
      nil -> media |> String.split("/") |> List.last() |> String.upcase()
    end
  end

  # 3.0 LABEL is the delivery label of the ADR with its group or first TYPE;
  # 4.0 carries it as that ADR's LABEL parameter. A LABEL without its ADR
  # is dropped like any other orphaned decoration (R40).
  defp delivery_labels(lines, :v40) do
    {labels, lines} = Enum.split_with(lines, &(property_name(&1) == "LABEL"))

    Enum.reduce(labels, lines, fn label, lines ->
      case Enum.find_index(lines, &labelled_address?(&1, label, false)) do
        nil ->
          lines

        index ->
          List.update_at(lines, index, &label_parameter(&1, label))
      end
    end)
  end

  defp delivery_labels(lines, :v30) do
    lines
    |> Enum.reject(fn line ->
      property_name(line) == "LABEL" and not Enum.any?(lines, &labelled_address?(&1, line, true))
    end)
    |> Enum.flat_map(fn line ->
      {head, value} = Parser.split_line(line)
      [name | params] = Parser.split_params(head)
      {labels, params} = Enum.split_with(params, &(param_key(&1) == "LABEL"))

      case {property_name(line), labels} do
        {"ADR", [label | _]} ->
          group = String.replace_suffix(name, name |> String.split(".") |> List.last(), "")
          types = Enum.filter(params, &(param_key(&1) == "TYPE"))
          text = label |> String.split("=", parts: 2) |> List.last() |> String.trim("\"")
          text = text |> Parser.unescape() |> escape_text()
          [rebuild(name, {params, value}), rebuild(group <> "LABEL", {types, text})]

        _ ->
          [line]
      end
    end)
  end

  defp label_parameter(adr, label) do
    {head, value} = Parser.split_line(adr)
    text = label |> Parser.split_line() |> elem(1) |> Parser.unescape()
    param = text |> String.replace("\\", "\\\\") |> String.replace("\n", "\\n")
    head <> ";LABEL=" <> param_value(param) <> ":" <> value
  end

  defp labelled_address?(line, label, allow_labelled) do
    property_name(line) == "ADR" and
      (allow_labelled or not Enum.any?(params_of(line), &(param_key(&1) == "LABEL"))) and
      case group(label) do
        nil -> type(line) == type(label)
        group -> group(line) == group
      end
  end

  defp escape_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp property_name(line) do
    line
    |> Parser.split_line()
    |> elem(0)
    |> Parser.split_params()
    |> hd()
    |> String.split(".")
    |> List.last()
    |> String.upcase()
  end

  defp params_of(line),
    do: line |> Parser.split_line() |> elem(0) |> Parser.split_params() |> tl()

  defp param_key(param), do: param |> String.split("=", parts: 2) |> hd() |> String.upcase()

  defp param_raw(param),
    do: param |> String.split("=", parts: 2) |> List.last() |> String.trim("\"")

  defp rebuild(name, {params, value}), do: Enum.join([name | params], ";") <> ":" <> value

  # Kith's own 3.0 relationship lines live in `kithrelN.` groups.
  defp native?(property) do
    property["name"] in @mapped or Map.has_key?(@social, property["name"]) or
      Regex.match?(~r/\Akithrel\d+\z/i, group(property["head"]) || "")
  end

  defp group(line) do
    name = line |> String.split([";", ":"], parts: 2) |> hd()

    case String.split(name, ".", parts: 2) do
      [group, _name] -> String.downcase(group)
      _ -> nil
    end
  end

  defp restore("FN:" <> _ = line, properties), do: {restore_fn(line, properties), properties}

  defp restore("N:" <> current, properties),
    do: {restore_n(current, properties), properties}

  defp restore("ORG:" <> company = line, properties),
    do: {restore_org(company, line, properties), properties}

  defp restore(line, properties) do
    {name, val} = identity(line)

    match =
      Enum.find(properties, fn property ->
        native_name(property["name"]) == name and
          comparable(name, property["value"]) == comparable(name, val) and
          property_type(property) == type(line)
      end)

    # Each retained property decorates at most one native line.
    if match, do: {render(match), List.delete(properties, match)}, else: {line, properties}
  end

  defp restore_fn(line, properties) do
    with %{} = fn_property <- find(properties, "FN"),
         %{} = n_property <- find(properties, "N"),
         {:ok, [parsed]} <- Parser.parse("BEGIN:VCARD\n" <> render(n_property) <> "\nEND:VCARD"),
         expected <-
           [parsed.first_name, parsed.middle_name, parsed.last_name]
           |> Enum.reject(&(&1 in [nil, ""]))
           |> Enum.join(" "),
         true <- Parser.unescape(value(line)) == expected do
      render(fn_property)
    else
      _ -> line
    end
  end

  defp restore_n(current, properties) do
    case find(properties, "N") do
      nil ->
        "N:" <> current

      property ->
        current = Parser.split_components(current, ";") |> Enum.take(3)
        original = Parser.split_components(property["value"], ";") |> Enum.drop(3)
        "N:" <> Enum.join(current ++ original, ";")
    end
  end

  defp restore_org(company, line, properties) do
    case find(properties, "ORG") do
      %{"value" => original} ->
        if hd(Parser.split_components(original, ";")) == company,
          do: "ORG:" <> original,
          else: line

      _ ->
        line
    end
  end

  defp native_name(name) when is_map_key(@social, name), do: "URL"
  defp native_name(name), do: name

  defp property_type(property),
    do: type(render(property)) || Map.get(@social, property["name"])

  defp type(line) do
    {head, _value} = Parser.split_line(line)

    case List.keyfind(Parser.params(head), "TYPE", 0) do
      {"TYPE", [value | _]} ->
        case String.downcase(value) do
          "pref" -> nil
          type -> type
        end

      _ ->
        nil
    end
  end

  @doc """
  A parameter value as written on the wire: DQUOTE and control characters
  cannot be represented and are dropped; a value containing `;`, `:` or `,`
  is quoted (RFC 6350 §3.3, RFC 2426 §4; CDV-89).
  """
  def param_value(value) do
    value = String.replace(value, ~r/["\x00-\x1F\x7F]/, "")
    if String.match?(value, ~r/[;:,]/), do: "\"" <> value <> "\"", else: value
  end

  defp comparable("CATEGORIES", value) do
    value |> Parser.split_components(",") |> Enum.map(&Parser.unescape/1) |> Enum.sort()
  end

  defp comparable("TEL", value), do: value |> Parser.unescape() |> Parser.phone_value()
  defp comparable("ADR", value), do: value |> Parser.split_components(";") |> Enum.drop(1)
  defp comparable(_, value), do: Parser.unescape(value)

  defp find(properties, name),
    do: properties |> Enum.reverse() |> Enum.find(&(&1["name"] == name))

  defp render(property), do: property["head"] <> ":" <> property["value"]

  defp identity(line) do
    {head, value} = Parser.split_line(line)

    name =
      head |> Parser.split_params() |> hd() |> String.split(".") |> List.last() |> String.upcase()

    name = if name == "X-KITH-RELATED", do: "RELATED", else: name
    {name, value}
  end

  defp value(line), do: line |> Parser.split_line() |> elem(1)

  defp telephone_value(line, :v30) do
    case identity(line) do
      {"TEL", value} ->
        {head, _} = Parser.split_line(line)
        head = Regex.replace(~r/;VALUE=uri/i, head, "")
        head <> ":" <> Parser.phone_value(value)

      _ ->
        line
    end
  end

  defp telephone_value(line, _version), do: line

  @doc false
  def uri?(value), do: Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:[^\s\\]*\z/, value)

  defp declare_identifier_type(line, :v40) do
    {name, value} = identity(line)
    {head, _} = Parser.split_line(line)

    if name in ["UID", "RELATED"] and not uri?(value) and not Regex.match?(~r/;VALUE=/i, head),
      do: head <> ";VALUE=text:" <> value,
      else: line
  end

  defp declare_identifier_type(line, _version), do: line

  # Translate the preference syntax when the client changes vCard versions.
  defp convert("RELATED" <> rest, :v30), do: convert("X-KITH-RELATED" <> rest, :v30)
  defp convert("X-KITH-RELATED" <> rest, :v40), do: convert("RELATED" <> rest, :v40)

  defp convert(line, version) do
    {head, value} = Parser.split_line(line)
    [name | params] = Parser.split_params(head)
    {types, params} = Enum.split_with(params, &String.starts_with?(String.upcase(&1), "TYPE="))
    types = Enum.flat_map(types, &(Parser.params("X;" <> &1) |> hd() |> elem(1)))

    {prefs, params} = Enum.split_with(params, &String.starts_with?(String.upcase(&1), "PREF="))

    needs_conversion =
      (version == :v30 and prefs != []) or
        (version == :v40 and Enum.any?(types, &(String.upcase(&1) == "PREF")))

    if needs_conversion do
      convert_preference(name, value, types, params, prefs, version)
    else
      line
    end
  end

  defp convert_preference(name, value, types, params, prefs, version) do
    preferred = prefs != [] or Enum.any?(types, &(String.upcase(&1) == "PREF"))
    types = Enum.reject(types, &(String.upcase(&1) == "PREF"))

    {types, prefs} =
      case version do
        :v30 -> {if(preferred, do: types ++ ["PREF"], else: types), []}
        :v40 -> {types, if(preferred, do: [List.first(prefs) || "PREF=1"], else: [])}
      end

    params =
      if types == [],
        do: params,
        else: ["TYPE=" <> Enum.map_join(types, ",", &param_value/1) | params]

    Enum.join([name | params ++ prefs], ";") <> ":" <> value
  end
end
