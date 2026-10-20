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
    contacts =
      data
      |> normalize_line_endings()
      |> unfold_lines()
      |> split_vcards()
      |> Enum.map(&parse_vcard/1)
      |> Enum.reject(&is_nil/1)

    {:ok, contacts}
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
    ~r/BEGIN:VCARD\n(.*?)END:VCARD/si
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

    Enum.reduce(lines, base, &parse_line/2)
  end

  defp parse_line(line, acc) do
    case parse_property(line) do
      {name, params, value} ->
        head = line |> String.split(":", parts: 2) |> hd()
        property = %{"name" => name, "head" => head, "value" => value}
        acc = %{acc | properties: acc.properties ++ [property]}
        apply_property(acc, name, params, value)

      _ ->
        acc
    end
  end

  defp apply_property(acc, "FN", _params, value),
    do: %{acc | display_name: unescape(value)}

  defp apply_property(acc, "N", _params, value) do
    parts = String.split(value, ";", parts: 5)
    last = Enum.at(parts, 0) |> unescape_or_nil()
    first = Enum.at(parts, 1) |> unescape_or_nil()
    middle = Enum.at(parts, 2) |> unescape_or_nil()
    %{acc | last_name: last, first_name: first, middle_name: middle}
  end

  defp apply_property(acc, "NICKNAME", _params, value),
    do: %{acc | nickname: unescape(value)}

  defp apply_property(acc, "BDAY", _params, value),
    do: %{acc | birthdate: parse_date(value)}

  defp apply_property(acc, "ORG", _params, value) do
    company = value |> String.split(";") |> List.first() |> unescape()
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
    %{acc | phones: acc.phones ++ [%{value: unescape(value), label: label}]}
  end

  defp apply_property(acc, "EMAIL", params, value) do
    label = extract_type(params)
    %{acc | emails: acc.emails ++ [%{value: unescape(value), label: label}]}
  end

  defp apply_property(acc, "ADR", params, value) do
    label = extract_type(params)
    addr = parse_address(value, label)
    %{acc | addresses: acc.addresses ++ [addr]}
  end

  defp apply_property(acc, "URL", params, value) do
    label = extract_type(params)
    %{acc | urls: acc.urls ++ [%{value: unescape(value), label: label}]}
  end

  defp apply_property(acc, "IMPP", params, value) do
    label = extract_type(params)
    %{acc | impp: acc.impp ++ [%{value: unescape(value), label: label}]}
  end

  defp apply_property(acc, name, params, value)
       when name in ["X-SOCIALPROFILE", "X-TWITTER", "X-INSTAGRAM"] do
    label = extract_type(params) || social_label(name)
    %{acc | urls: acc.urls ++ [%{value: unescape(value), label: label}]}
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
    %{acc | related: acc.related ++ [%{value: unescape(value), type: type}]}
  end

  defp apply_property(acc, "REV", _params, value),
    do: %{acc | rev: unescape(value)}

  defp apply_property(acc, "PHOTO", params, value) do
    %{acc | photo: parse_photo_data(params, value)}
  end

  defp apply_property(acc, _name, _params, _value), do: acc

  # ── Property Parsing ───────────────────────────────────────────────────

  defp parse_property(line) do
    case String.split(line, ":", parts: 2) do
      [name_and_params, value] ->
        {name, params} = parse_name_params(name_and_params)
        {name |> String.split(".") |> List.last() |> String.upcase(), params, value}

      _ ->
        nil
    end
  end

  defp parse_name_params(str) do
    case String.split(str, ";", parts: 2) do
      [name] -> {name, %{}}
      [name, params_str] -> {name, parse_params(params_str)}
    end
  end

  defp parse_params(str) do
    str
    |> String.split(";")
    |> Enum.reduce(%{}, fn param, acc ->
      case String.split(param, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.upcase(key), value)
        # Bare parameter (vCard 2.1 style): e.g., TEL;CELL:...
        [bare] -> Map.put(acc, "TYPE", bare)
      end
    end)
  end

  # ── Address Parsing ────────────────────────────────────────────────────

  defp parse_address(value, label) do
    parts = String.split(value, ";", parts: 7)

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
  def split_components(str, delimiter), do: split_unescaped(str, delimiter)

  defp split_unescaped(str, delimiter) do
    Regex.split(~r/(?<!\\)#{Regex.escape(delimiter)}/, str)
  end

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

      # vCard 4.0 with dashes but no year: --0615
      String.match?(str, ~r/^--\d{4}$/) ->
        nil

      true ->
        nil
    end
  end

  @doc """
  Unescapes vCard property values.
  """
  def unescape(nil), do: nil

  def unescape(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\;", ";")
    |> String.replace("\\,", ",")
    |> String.replace("\\\\", "\\")
  end

  defp unescape_or_nil(nil), do: nil
  defp unescape_or_nil(""), do: nil
  defp unescape_or_nil(str), do: unescape(str)
end
