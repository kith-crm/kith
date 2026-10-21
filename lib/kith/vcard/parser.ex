defmodule Kith.VCard.Parser do
  @moduledoc """
  Parses vCard 3.0 and 4.0 files into structured maps.

  Handles:
  - Single and multi-contact .vcf files
  - Property parameters (TYPE=HOME, etc.)
  - Line unfolding (continuation lines starting with space/tab)
  - Both CRLF and LF line endings
  """

  @doc """
  Parses a vCard file string into a list of contact maps.

  Returns `{:ok, contacts}` or `{:error, reason}`.

  Each contact map has keys:
  - :first_name, :last_name, :middle_name, :display_name, :nickname
  - :birthdate (Date or nil)
  - :company, :occupation, :description
  - :categories (list of strings)
  - :gender, :gender_text (RFC 6350 §6.2.7)
  - :emails (list of %{value, label})
  - :phones (list of %{value, label})
  - :urls (list of %{value, label})
  - :impp (list of %{value, label})
  - :addresses (list of %{label, line1, line2, city, province, postal_code, country})
  - :related (list of %{value, type})
  - :rev (string timestamp or nil)
  - :photo (map with :content_type/:data/:encoding or :url, or nil)
  """
  def parse(data) when is_binary(data) do
    # A fold can bisect a UTF-8 code point (RFC 6350 §3.2). Restore bytes
    # before validating encoding; genuinely malformed input remains rejected.
    data =
      data |> String.replace_prefix("\uFEFF", "") |> normalize_line_endings() |> unfold_lines()

    if String.valid?(data) do
      contacts = data |> split_vcards() |> Enum.map(&parse_vcard/1) |> Enum.reject(&is_nil/1)
      {:ok, contacts}
    else
      {:error, "Invalid UTF-8"}
    end
  rescue
    e -> {:error, "Failed to parse vCard file: #{Exception.message(e)}"}
  end

  # ── Preprocessing ──────────────────────────────────────────────────────

  defp normalize_line_endings(data) do
    data
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp unfold_lines(data) do
    # RFC 2425: continuation lines start with a single space or tab
    String.replace(data, ~r/\n[ \t]/, "")
  end

  defp split_vcards(data) do
    # Delimiters count only as whole lines: an escaped AGENT value may contain
    # "BEGIN:VCARD…END:VCARD" text (CDV-91).
    # A delimiter line may carry trailing blanks (CDV-95).
    ~r/^[ \t]*BEGIN:VCARD[ \t]*\n(.*?)^[ \t]*END:VCARD[ \t]*$/msi
    |> Regex.scan(data, capture: :all_but_first)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&is_nil/1)
  end

  # ── Single vCard Parsing ───────────────────────────────────────────────

  defp parse_vcard(block) do
    lines = String.split(block, "\n", trim: true)

    base = %{
      first_name: nil,
      last_name: nil,
      middle_name: nil,
      display_name: nil,
      nickname: nil,
      birthdate: nil,
      birthdate_year_unknown: false,
      company: nil,
      occupation: nil,
      description: nil,
      uid: nil,
      categories: [],
      gender: nil,
      gender_text: nil,
      emails: [],
      phones: [],
      urls: [],
      addresses: [],
      related: [],
      impp: [],
      rev: nil,
      photo: nil,
      properties: []
    }

    lines |> Enum.reduce(base, &parse_line/2) |> in_document_order()
  end

  # The accumulators are built by prepending (appending with `++` made a card
  # of n lines O(n^2), CDV-108); restore the document order once at the end.
  @ordered_lists [:properties, :phones, :emails, :addresses, :urls, :impp, :related]

  defp in_document_order(acc) do
    Enum.reduce(@ordered_lists, acc, fn key, acc -> Map.update!(acc, key, &Enum.reverse/1) end)
  end

  defp parse_line(line, acc) do
    case parse_property(line) do
      {name, params, value} ->
        {head, _value} = split_line(line)
        property = %{"name" => name, "head" => head, "value" => value}
        acc = %{acc | properties: [property | acc.properties]}
        apply_property(acc, name, params, value)

      _ ->
        acc
    end
  end

  defp apply_property(acc, "FN", _params, value),
    do: %{acc | display_name: unescape(value)}

  defp apply_property(acc, "N", _params, value) do
    parts = split_components(value, ";") |> Enum.take(5)
    last = Enum.at(parts, 0) |> unescape_or_nil()
    first = Enum.at(parts, 1) |> unescape_or_nil()
    middle = Enum.at(parts, 2) |> unescape_or_nil()
    %{acc | last_name: last, first_name: first, middle_name: middle}
  end

  defp apply_property(acc, "NICKNAME", _params, value),
    do: %{acc | nickname: unescape(value)}

  defp apply_property(acc, name, params, value) when name in ["BDAY", "X-KITH-BDAY"] do
    date = parse_date(value)

    year_unknown =
      date != nil and (String.starts_with?(value, "--") or apple_omit_year?(params, date))

    # Apple's 3.0 form `BDAY;X-APPLE-OMIT-YEAR=1604:1604-MM-DD` (also written
    # by DAVx5) has no birth year: store the leap-safe placeholder (CDV-115).
    date = if year_unknown, do: Date.new!(2000, date.month, date.day), else: date

    %{acc | birthdate: date, birthdate_year_unknown: year_unknown}
  end

  defp apply_property(acc, "ORG", _params, value) do
    company = value |> split_components(";") |> List.first() |> unescape()
    %{acc | company: company}
  end

  defp apply_property(acc, "TITLE", _params, value),
    do: %{acc | occupation: unescape(value)}

  defp apply_property(acc, "NOTE", _params, value),
    do: %{acc | description: unescape(value)}

  defp apply_property(acc, "UID", _params, value),
    do: %{acc | uid: unescape(value)}

  defp apply_property(acc, "TEL", params, value) do
    label = extract_type(params)
    %{acc | phones: [%{value: value |> unescape() |> phone_value(), label: label} | acc.phones]}
  end

  defp apply_property(acc, "EMAIL", params, value) do
    label = extract_type(params)
    %{acc | emails: [%{value: unescape(value), label: label} | acc.emails]}
  end

  defp apply_property(acc, "ADR", params, value) do
    label = extract_type(params)
    addr = parse_address(value, label)
    %{acc | addresses: [addr | acc.addresses]}
  end

  defp apply_property(acc, "URL", params, value) do
    label = extract_type(params)
    %{acc | urls: [%{value: unescape(value), label: label} | acc.urls]}
  end

  defp apply_property(acc, "IMPP", params, value) do
    label = extract_type(params)
    %{acc | impp: [%{value: unescape(value), label: label} | acc.impp]}
  end

  defp apply_property(acc, name, params, value)
       when name in ["X-SOCIALPROFILE", "X-TWITTER", "X-INSTAGRAM"] do
    label = extract_type(params) || social_label(name)
    %{acc | urls: [%{value: unescape(value), label: label} | acc.urls]}
  end

  defp apply_property(acc, "CATEGORIES", _params, value) do
    cats = split_unescaped(value, ",") |> Enum.map(&(String.trim(&1) |> unescape()))
    %{acc | categories: cats}
  end

  defp apply_property(acc, "GENDER", _params, value) do
    case String.split(value, ";", parts: 2) do
      [sex, text] -> %{acc | gender: unescape(sex), gender_text: unescape(text)}
      [sex] -> %{acc | gender: unescape(sex)}
    end
  end

  defp apply_property(acc, "X-GENDER", _params, value) do
    %{acc | gender_text: unescape(value)}
  end

  defp apply_property(acc, "X-KITH-RELATED", params, value),
    do: apply_property(acc, "RELATED", params, value)

  defp apply_property(acc, "RELATED", params, value) do
    type = extract_type(params) || "contact"
    %{acc | related: [%{value: unescape(value), type: type} | acc.related]}
  end

  defp apply_property(acc, "REV", _params, value),
    do: %{acc | rev: unescape(value)}

  defp apply_property(acc, "PHOTO", params, value) do
    %{acc | photo: parse_photo_data(params, value)}
  end

  defp apply_property(acc, _name, _params, _value), do: acc

  # ── Property Parsing ───────────────────────────────────────────────────

  defp parse_property(line) do
    case split_line(line) do
      {name_and_params, value} when is_binary(value) ->
        [name | params] = split_params(name_and_params)
        {name |> String.split(".") |> List.last() |> String.upcase(), parse_params(params), value}

      _ ->
        nil
    end
  end

  # RFC 6350 §3.3 / RFC 2426 §4: a param-value may be DQUOTE-quoted and then
  # contain ";", ":" and ",". These helpers split only outside quotes (CDV-89).

  @doc false
  def split_line(line) do
    case split_unquoted(line, ?:, 2) do
      [head, value] ->
        {head, value}

      # An unbalanced quote: fall back to the first colon rather than lose the value
      [head] ->
        case String.split(head, ":", parts: 2) do
          [head, value] -> {head, value}
          [head] -> {head, nil}
        end
    end
  end

  @doc false
  def split_params(head), do: split_unquoted(head, ?;, :infinity)

  @doc "Parameter `{KEY, values}` pairs of a property head, values unquoted."
  def params(head), do: head |> split_params() |> tl() |> param_pairs()

  defp param_pairs(params) do
    Enum.map(params, fn param ->
      case split_unquoted(param, ?=, 2) do
        [key, value] -> {String.upcase(key), param_values(value)}
        # Bare parameter (vCard 2.1 style): e.g., TEL;CELL:...
        [bare] -> {"TYPE", [bare]}
      end
    end)
  end

  # A quoted TYPE list (`TYPE="work,voice"`) is still a list of values.
  defp param_values(value), do: value |> String.replace("\"", "") |> String.split(",")

  defp split_unquoted(string, separator, parts),
    do: split_unquoted(string, separator, parts, false, [], [])

  defp split_unquoted(<<>>, _separator, _parts, _quoted, current, acc),
    do: Enum.reverse([current |> Enum.reverse() |> IO.iodata_to_binary() | acc])

  defp split_unquoted(rest, _separator, parts, _quoted, current, acc)
       when parts != :infinity and length(acc) == parts - 1,
       do: Enum.reverse([IO.iodata_to_binary([Enum.reverse(current), rest]) | acc])

  defp split_unquoted(<<?", rest::binary>>, separator, parts, quoted, current, acc),
    do: split_unquoted(rest, separator, parts, not quoted, [?" | current], acc)

  defp split_unquoted(<<separator, rest::binary>>, separator, parts, false, current, acc),
    do:
      split_unquoted(rest, separator, parts, false, [], [
        current |> Enum.reverse() |> IO.iodata_to_binary() | acc
      ])

  defp split_unquoted(<<byte, rest::binary>>, separator, parts, quoted, current, acc),
    do: split_unquoted(rest, separator, parts, quoted, [byte | current], acc)

  defp parse_params(params) do
    params
    |> param_pairs()
    |> Enum.reduce(%{}, fn {key, values}, acc -> Map.put(acc, key, Enum.join(values, ",")) end)
  end

  # ── Address Parsing ────────────────────────────────────────────────────

  defp parse_address(value, label) do
    parts = split_components(value, ";") |> Enum.take(7)

    %{
      label: label,
      line2: Enum.at(parts, 1) |> unescape_or_nil(),
      line1: Enum.at(parts, 2) |> unescape_or_nil(),
      city: Enum.at(parts, 3) |> unescape_or_nil(),
      province: Enum.at(parts, 4) |> unescape_or_nil(),
      postal_code: Enum.at(parts, 5) |> unescape_or_nil(),
      country: Enum.at(parts, 6) |> unescape_or_nil()
    }
  end

  # ── Photo Parsing ─────────────────────────────────────────────────

  @allowed_photo_types ~w(image/jpeg image/png image/gif image/webp)

  defp parse_photo_data(params, value) do
    encoding = Map.get(params, "ENCODING")

    cond do
      # vCard 4.0 data URI (RFC 6350 §6.2.4)
      String.starts_with?(value, "data:") ->
        case Regex.run(~r/^data:([^;]+);base64,(.+)$/s, value) do
          [_, content_type, b64] ->
            %{content_type: sanitize_photo_type(content_type), data: b64, encoding: :base64}

          _ ->
            nil
        end

      # vCard 3.0 inline binary (RFC 2426 §3.1.4) — ENCODING=b or ENCODING=BASE64
      encoding != nil and String.upcase(encoding) in ["B", "BASE64"] ->
        type_str = Map.get(params, "TYPE", "JPEG")
        content_type = sanitize_photo_type("image/" <> String.downcase(type_str))
        %{content_type: content_type, data: value, encoding: :base64}

      # URI reference (both versions)
      String.match?(value, ~r/^https?:\/\//) ->
        %{url: value}

      # Bare base64 with TYPE param but no ENCODING (compatibility)
      Map.has_key?(params, "TYPE") ->
        type_str = Map.get(params, "TYPE", "JPEG")
        content_type = sanitize_photo_type("image/" <> String.downcase(type_str))
        %{content_type: content_type, data: value, encoding: :base64}

      true ->
        nil
    end
  end

  defp sanitize_photo_type(ct) when ct in @allowed_photo_types, do: ct
  defp sanitize_photo_type(_), do: "image/jpeg"

  # ── Helpers ────────────────────────────────────────────────────────────

  @doc false
  def split_components(value, <<delimiter>>) do
    split_components(value, delimiter, [], [])
  end

  defp split_components(<<>>, _delimiter, current, parts),
    do: Enum.reverse([current |> Enum.reverse() |> IO.iodata_to_binary() | parts])

  defp split_components(<<92, escaped, rest::binary>>, delimiter, current, parts),
    do: split_components(rest, delimiter, [<<92, escaped>> | current], parts)

  defp split_components(<<delimiter, rest::binary>>, delimiter, current, parts),
    do:
      split_components(rest, delimiter, [], [
        current |> Enum.reverse() |> IO.iodata_to_binary() | parts
      ])

  defp split_components(<<byte, rest::binary>>, delimiter, current, parts),
    do: split_components(rest, delimiter, [<<byte>> | current], parts)

  defp split_unescaped(value, delimiter), do: split_components(value, delimiter)

  @doc false
  def phone_value(value), do: String.replace(value, ~r/\Atel:/i, "")

  defp extract_type(params) do
    case Map.get(params, "TYPE") do
      nil -> nil
      type -> type |> String.split(",") |> List.first() |> String.downcase() |> label_name()
    end
  end

  defp label_name("home"), do: "Home"
  defp label_name("work"), do: "Work"
  defp label_name("cell"), do: "Cell"
  defp label_name("fax"), do: "Fax"
  defp label_name("pref"), do: nil
  defp label_name(other), do: String.capitalize(other)

  defp social_label("X-TWITTER"), do: "Twitter"
  defp social_label("X-INSTAGRAM"), do: "Instagram"
  defp social_label(_), do: nil

  # The year Apple writes for "no year" (`X-APPLE-OMIT-YEAR=1604`); a card with
  # the parameter naming a different year keeps its real year.
  defp apple_omit_year?(params, %Date{year: year}) do
    case Map.get(params, "X-APPLE-OMIT-YEAR") do
      nil -> year == 1604
      omitted -> String.trim(omitted, "\"") == Integer.to_string(year)
    end
  end

  defp parse_date(str) do
    str = String.trim(str)

    cond do
      # ISO 8601: 1990-06-15
      String.match?(str, ~r/^\d{4}-\d{2}-\d{2}$/) ->
        case Date.from_iso8601(str) do
          {:ok, date} -> date
          _ -> nil
        end

      # Compact: 19900615
      String.match?(str, ~r/^\d{8}$/) ->
        compact =
          String.slice(str, 0, 4) <>
            "-" <> String.slice(str, 4, 2) <> "-" <> String.slice(str, 6, 2)

        case Date.from_iso8601(compact) do
          {:ok, date} -> date
          _ -> nil
        end

      # A leap-safe placeholder stores month/day; the separate flag prevents
      # exposing this implementation year to clients or age calculations.
      String.match?(str, ~r/^--\d{4}$/) ->
        parse_date("2000" <> String.replace_prefix(str, "--", ""))

      true ->
        nil
    end
  end

  @doc """
  Unescapes vCard property values.
  """
  def unescape(nil), do: nil

  def unescape(value) do
    Regex.replace(~r/\\([\\nN;,])/, value, fn _, escaped ->
      if escaped in ["n", "N"], do: "\n", else: escaped
    end)
  end

  defp unescape_or_nil(nil), do: nil
  defp unescape_or_nil(""), do: nil
  defp unescape_or_nil(str), do: unescape(str)
end
