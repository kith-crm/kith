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

    Enum.map(body ++ extras ++ [ending], fn line ->
      line |> convert(version) |> telephone_value(version) |> declare_identifier_type(version)
    end)
  end

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
    head = line |> String.split(":", parts: 2) |> hd()

    case Regex.run(~r/;TYPE=([^;]+)/i, head) do
      [_, value] ->
        case value |> String.trim("\"") |> String.split(",") |> hd() |> String.downcase() do
          "pref" -> nil
          type -> type
        end

      _ ->
        nil
    end
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
    [head, value] = String.split(line, ":", parts: 2)

    name =
      head |> String.split(";") |> hd() |> String.split(".") |> List.last() |> String.upcase()

    name = if name == "X-KITH-RELATED", do: "RELATED", else: name
    {name, value}
  end

  defp value(line), do: line |> String.split(":", parts: 2) |> List.last()

  defp telephone_value(line, :v30) do
    case identity(line) do
      {"TEL", value} ->
        [head, _] = String.split(line, ":", parts: 2)
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
    [head, _] = String.split(line, ":", parts: 2)

    if name in ["UID", "RELATED"] and not uri?(value) and not Regex.match?(~r/;VALUE=/i, head),
      do: head <> ";VALUE=text:" <> value,
      else: line
  end

  defp declare_identifier_type(line, _version), do: line

  # Translate the preference syntax when the client changes vCard versions.
  defp convert("RELATED" <> rest, :v30), do: convert("X-KITH-RELATED" <> rest, :v30)
  defp convert("X-KITH-RELATED" <> rest, :v40), do: convert("RELATED" <> rest, :v40)

  defp convert(line, version) do
    [head, value] = String.split(line, ":", parts: 2)
    [name | params] = String.split(head, ";")
    {types, params} = Enum.split_with(params, &String.starts_with?(String.upcase(&1), "TYPE="))

    types =
      Enum.flat_map(
        types,
        &(&1
          |> String.split("=", parts: 2)
          |> List.last()
          |> String.trim("\"")
          |> String.split(","))
      )

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

    params = if types == [], do: params, else: ["TYPE=" <> Enum.join(types, ",") | params]
    Enum.join([name | params ++ prefs], ";") <> ":" <> value
  end
end
