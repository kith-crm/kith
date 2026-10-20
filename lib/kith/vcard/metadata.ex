defmodule Kith.VCard.Metadata do
  @moduledoc "Preserves client vCard data that has no native Kith field."

  alias Kith.VCard.Parser

  @mapped ~w(BEGIN END VERSION UID REV PHOTO FN N NICKNAME BDAY X-KITH-BDAY ORG TITLE NOTE GENDER X-GENDER CATEGORIES EMAIL TEL ADR URL)

  @doc "Overlays retained metadata only while the corresponding native value still matches."
  def merge(lines, contact, version) do
    properties = Map.get(contact, :dav_vcard, %{}) |> Map.get("properties", [])
    lines = Enum.map(lines, &restore(&1, properties))
    names_and_values = MapSet.new(lines, &identity/1)

    extras =
      Enum.reject(properties, fn property ->
        property["name"] in @mapped or
          MapSet.member?(names_and_values, identity(render(property)))
      end)
      |> Enum.map(&render/1)

    {body, [ending]} = Enum.split(lines, -1)
    Enum.map(body ++ extras ++ [ending], &convert(&1, version))
  end

  defp restore("FN:" <> _ = line, properties) do
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

  defp restore("N:" <> current = line, properties) do
    case find(properties, "N") do
      nil ->
        line

      property ->
        current = Parser.split_components(current, ";") |> Enum.take(3)
        original = Parser.split_components(property["value"], ";") |> Enum.drop(3)
        "N:" <> Enum.join(current ++ original, ";")
    end
  end

  defp restore("ORG:" <> company = line, properties) do
    case find(properties, "ORG") do
      %{"value" => original} ->
        if hd(Parser.split_components(original, ";")) == company,
          do: "ORG:" <> original,
          else: line

      _ ->
        line
    end
  end

  defp restore(line, properties) do
    {name, val} = identity(line)

    match =
      Enum.find(properties, fn property ->
        property["name"] == name and comparable(name, property["value"]) == comparable(name, val) and
          type(render(property)) == type(line)
      end)

    if match, do: render(match), else: line
  end

  defp type(line) do
    head = line |> String.split(":", parts: 2) |> hd()

    case Regex.run(~r/;TYPE=([^;]+)/i, head) do
      [_, value] -> value |> String.trim("\"") |> String.split(",") |> hd() |> String.downcase()
      _ -> nil
    end
  end

  defp comparable("ADR", value), do: value |> Parser.split_components(";") |> Enum.drop(1)
  defp comparable(_, value), do: Parser.unescape(value)

  defp find(properties, name),
    do: properties |> Enum.reverse() |> Enum.find(&(&1["name"] == name))

  defp render(property), do: property["head"] <> ":" <> property["value"]

  defp identity(line) do
    [head, value] = String.split(line, ":", parts: 2)

    name =
      head |> String.split(";") |> hd() |> String.split(".") |> List.last() |> String.upcase()

    {name, value}
  end

  defp value(line), do: line |> String.split(":", parts: 2) |> List.last()

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
