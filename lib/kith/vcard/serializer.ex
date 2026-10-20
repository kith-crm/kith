defmodule Kith.VCard.Serializer do
  @moduledoc """
  Serializes a contact (with preloaded associations) into a vCard string.

  Supports vCard 3.0 (RFC 2426, default) and vCard 4.0 (RFC 6350).

  - Line endings: CRLF (\\r\\n)
  - Property folding: at 75 octets
  - Structured values use semicolons as separators
  - Special characters (semicolons, commas, backslashes, newlines) must be escaped
  """

  alias Kith.VCard.Metadata

  @crlf "\r\n"

  @doc """
  Serializes a single contact into a vCard string.

  Options:
    - `:version` — `:v30` (default) for vCard 3.0, `:v40` for vCard 4.0

  The contact must have the following associations preloaded:
  - :addresses
  - :contact_fields (with :contact_field_type)
  - :gender
  - :tags
  - :relationships (with :relationship_type and :related_contact)
  """
  def serialize(%{} = contact, opts \\ []) do
    version = Keyword.get(opts, :version, :v30)

    [
      "BEGIN:VCARD",
      version_line(version),
      uid_line(contact, version, Keyword.get(opts, :include_uid, false)),
      fn_line(contact),
      n_line(contact),
      nickname_line(contact),
      bday_line(contact, version),
      org_line(contact),
      title_line(contact),
      note_line(contact),
      gender_line(contact, version),
      categories_line(contact),
      related_lines(contact, version),
      rev_line(contact, version),
      photo_line(contact, version),
      contact_field_lines(contact),
      address_lines(contact),
      "END:VCARD"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Metadata.merge(contact, version)
    |> Enum.map_join(@crlf, &fold_line/1)
    |> Kernel.<>(@crlf)
  end

  @doc """
  Serializes multiple contacts into a single vCard file (concatenated blocks).
  """
  def serialize_many(contacts, opts \\ []) do
    Enum.map_join(contacts, "", &serialize(&1, opts))
  end

  @doc false
  def uid_for(%{dav_uid: uid}, _version) when is_binary(uid), do: uid
  def uid_for(%{id: id}, :v30), do: "kith-contact-#{id}"
  def uid_for(%{id: id}, :v40), do: "urn:uuid:kith-contact-#{id}"

  defp uid_line(_contact, _version, false), do: nil

  defp uid_line(contact, version, true),
    do: identifier_line("UID", uid_for(contact, version), version)

  defp identifier_line(name, value, :v40) do
    if Metadata.uri?(value),
      do: name <> ":" <> value,
      else: name <> ";VALUE=text:" <> escape(value)
  end

  defp identifier_line(name, value, :v30), do: name <> ":" <> escape(value)

  # ── Version ───────────────────────────────────────────────────────────

  defp version_line(:v30), do: "VERSION:3.0"
  defp version_line(:v40), do: "VERSION:4.0"

  # ── Identity Fields ──────────────────────────────────────────────────────

  defp fn_line(%{display_name: name}) when is_binary(name) and name != "" do
    "FN:" <> escape(name)
  end

  defp fn_line(%{first_name: first, last_name: last}) do
    name = [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if name != "" do
      "FN:" <> escape(name)
    end
  end

  defp n_line(contact) do
    last = escape(contact.last_name || "")
    first = escape(contact.first_name || "")
    middle = escape(Map.get(contact, :middle_name) || "")
    "N:#{last};#{first};#{middle};;"
  end

  defp nickname_line(%{nickname: nil}), do: nil
  defp nickname_line(%{nickname: ""}), do: nil
  defp nickname_line(%{nickname: nick}), do: "NICKNAME:" <> escape(nick)

  defp bday_line(%{birthdate: nil}, _version), do: nil

  defp bday_line(%{birthdate: date, birthdate_year_unknown: true}, version) do
    month_day = Calendar.strftime(date, "%m%d")
    name = if version == :v40, do: "BDAY", else: "X-KITH-BDAY"
    name <> ":--" <> month_day
  end

  defp bday_line(%{birthdate: date}, :v40), do: "BDAY:" <> Calendar.strftime(date, "%Y%m%d")

  defp bday_line(%{birthdate: date}, :v30) do
    "BDAY:" <> Date.to_iso8601(date)
  end

  defp org_line(%{company: nil}), do: nil
  defp org_line(%{company: ""}), do: nil
  defp org_line(%{company: company}), do: "ORG:" <> escape(company)

  defp title_line(%{occupation: nil}), do: nil
  defp title_line(%{occupation: ""}), do: nil
  defp title_line(%{occupation: occ}), do: "TITLE:" <> escape(occ)

  defp note_line(%{description: nil}), do: nil
  defp note_line(%{description: ""}), do: nil
  defp note_line(%{description: desc}), do: "NOTE:" <> escape(desc)

  # ── REV ──────────────────────────────────────────────────────────────

  defp rev_line(contact, version) do
    case Map.get(contact, :updated_at) do
      %DateTime{} = dt ->
        timestamp =
          if version == :v40,
            do: Calendar.strftime(dt, "%Y%m%dT%H%M%SZ"),
            else: DateTime.to_iso8601(dt)

        "REV:" <> timestamp

      _ ->
        nil
    end
  end

  # ── GENDER (version-aware) ──────────────────────────────────────────

  defp gender_line(%{gender: %{name: name}}, :v30) when is_binary(name) and name != "",
    do: "X-GENDER:" <> escape(name)

  defp gender_line(%{gender: %{name: name}}, :v40) when is_binary(name) and name != "" do
    {sex, text} = gender_to_rfc6350(name)
    if text, do: "GENDER:#{sex};#{escape(text)}", else: "GENDER:#{sex}"
  end

  defp gender_line(_, _), do: nil

  defp gender_to_rfc6350("Male"), do: {"M", nil}
  defp gender_to_rfc6350("Female"), do: {"F", nil}
  defp gender_to_rfc6350(other), do: {"O", other}

  # ── CATEGORIES ──────────────────────────────────────────────────────

  defp categories_line(contact) do
    case Map.get(contact, :tags, []) do
      tags when is_list(tags) and tags != [] ->
        "CATEGORIES:" <> Enum.map_join(tags, ",", &escape_category(&1.name))

      _ ->
        nil
    end
  end

  defp escape_category(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\r\n", "\\n")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\n")
  end

  # ── RELATED (version-aware) ─────────────────────────────────────────

  defp related_lines(contact, version) do
    case Map.get(contact, :relationships, []) do
      rels when is_list(rels) and rels != [] -> do_related_lines(rels, version)
      _ -> []
    end
  end

  defp do_related_lines(rels, :v30) do
    Enum.flat_map(rels, fn rel ->
      name = display_name_for_related(rel.related_contact)
      label = map_relationship_to_label(rel.relationship_type.name)
      group = "kithrel#{rel.id}"
      ["#{group}.X-ABRELATEDNAMES:#{escape(name)}", "#{group}.X-ABLabel:#{label}"]
    end)
  end

  defp do_related_lines(rels, :v40) do
    Enum.map(rels, fn rel ->
      type = relationship_type_to_vcard(rel.relationship_type.name)
      uid = rel.related_contact |> Map.put_new(:id, rel.related_contact_id) |> uid_for(:v40)
      identifier_line("RELATED;TYPE=#{type}", uid, :v40)
    end)
  end

  defp display_name_for_related(%{display_name: name}) when is_binary(name) and name != "",
    do: name

  defp display_name_for_related(%{first_name: first, last_name: last}) do
    [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp display_name_for_related(_), do: ""

  @doc false
  def relationship_type_to_vcard(name) do
    case String.downcase(name) do
      n when n in ["spouse", "husband", "wife"] -> "spouse"
      n when n in ["parent", "mother", "father"] -> "parent"
      n when n in ["child", "son", "daughter"] -> "child"
      n when n in ["sibling", "brother", "sister"] -> "sibling"
      "friend" -> "friend"
      n when n in ["colleague", "coworker", "co-worker"] -> "colleague"
      _ -> "contact"
    end
  end

  defp map_relationship_to_label(name) do
    case String.downcase(name) do
      n when n in ["spouse", "husband", "wife"] -> "_$!<Spouse>!$_"
      n when n in ["parent", "mother", "father"] -> "_$!<Parent>!$_"
      n when n in ["child", "son", "daughter"] -> "_$!<Child>!$_"
      n when n in ["sibling", "brother", "sister"] -> "_$!<Sibling>!$_"
      "friend" -> "_$!<Friend>!$_"
      _ -> name
    end
  end

  # ── PHOTO (version-aware) ───────────────────────────────────────────

  defp photo_line(contact, version) do
    case Map.get(contact, :avatar_data) do
      %{binary: binary, content_type: ct} -> do_photo_line(binary, ct, version)
      _ -> nil
    end
  end

  defp do_photo_line(binary, ct, :v30) do
    type = ct |> String.split("/") |> List.last() |> String.upcase()
    b64 = Base.encode64(binary)
    "PHOTO;ENCODING=b;TYPE=#{type}:#{b64}"
  end

  defp do_photo_line(binary, ct, :v40) do
    b64 = Base.encode64(binary)
    "PHOTO:data:#{ct};base64,#{b64}"
  end

  # ── Contact Fields (TEL, EMAIL, URL, X-SOCIALPROFILE, IMPP) ────────────

  defp contact_field_lines(%{contact_fields: fields}) when is_list(fields) do
    Enum.map(fields, &contact_field_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp contact_field_lines(_), do: []

  defp contact_field_line(%{contact_field_type: %{protocol: protocol}} = field) do
    vcard_label = field.contact_field_type.vcard_label
    type_param = type_param_from_label(field.label)

    case normalize_protocol(protocol) do
      "tel" ->
        "TEL#{type_param}:#{escape(field.value)}"

      "mailto" ->
        "EMAIL#{type_param}:#{escape(field.value)}"

      "https" ->
        if vcard_label && String.starts_with?(vcard_label, "X-") do
          "#{vcard_label}#{type_param}:#{escape(field.value)}"
        else
          "URL#{type_param}:#{escape(field.value)}"
        end

      "http" ->
        "URL#{type_param}:#{escape(field.value)}"

      _ ->
        if vcard_label do
          "#{vcard_label}#{type_param}:#{escape(field.value)}"
        end
    end
  end

  defp contact_field_line(_), do: nil

  defp normalize_protocol(nil), do: ""

  defp normalize_protocol(protocol),
    do: protocol |> String.trim_trailing("://") |> String.trim_trailing(":")

  defp type_param_from_label(nil), do: ""
  defp type_param_from_label(""), do: ""

  defp type_param_from_label(label) do
    type =
      case String.downcase(label) do
        "home" -> "HOME"
        "work" -> "WORK"
        "cell" -> "CELL"
        "mobile" -> "CELL"
        "fax" -> "FAX"
        "personal" -> "HOME"
        "business" -> "WORK"
        _ -> String.upcase(label)
      end

    ";TYPE=" <> Metadata.param_value(type)
  end

  # ── Addresses ──────────────────────────────────────────────────────────

  defp address_lines(%{addresses: addresses}) when is_list(addresses) do
    Enum.map(addresses, &address_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp address_lines(_), do: []

  defp address_line(addr) do
    type_param = type_param_from_label(addr.label)

    # ADR: PO Box;Extended;Street;City;Region;PostalCode;Country
    components = [
      "",
      escape(addr.line2 || ""),
      escape(addr.line1 || ""),
      escape(addr.city || ""),
      escape(addr.province || ""),
      escape(addr.postal_code || ""),
      escape(addr.country || "")
    ]

    "ADR#{type_param}:" <> Enum.join(components, ";")
  end

  # ── Line Folding (RFC 2426 §2.6) ──────────────────────────────────────

  # Lines longer than 75 octets MUST be folded with CRLF + space.
  defp fold_line(line) when byte_size(line) <= 75, do: line

  defp fold_line(line) do
    fold_line(line, 75, [])
    |> Enum.reverse()
    |> Enum.join("\r\n ")
  end

  defp fold_line(<<>>, _max, acc), do: acc

  defp fold_line(rest, max, acc) do
    size = utf8_chunk_size(rest, min(max, byte_size(rest)))
    <<chunk::binary-size(size), remaining::binary>> = rest
    # Continue lines use 74 octets (75 minus the leading space)
    fold_line(remaining, 74, [chunk | acc])
  end

  defp utf8_chunk_size(rest, size) do
    if String.valid?(binary_part(rest, 0, size)),
      do: size,
      else: utf8_chunk_size(rest, size - 1)
  end

  # ── Escaping ───────────────────────────────────────────────────────────

  @doc """
  Escapes special characters in vCard property values.

  In vCard 3.0:
  - Backslash → \\\\
  - Semicolon → \\;
  - Comma → \\,
  - Newline → \\n
  """
  def escape(nil), do: ""

  def escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\r\n", "\\n")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\n")
  end
end
