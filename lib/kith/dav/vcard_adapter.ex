defmodule Kith.DAV.VCardAdapter do
  @moduledoc """
  Bidirectional conversion between Kith contacts and vCard 3.0 format
  for the CardDAV server.

  Delegates to the existing `Kith.VCard.Serializer` and `Kith.VCard.Parser`
  modules, loading stored CardDAV identities and adapting the
  parser output into changeset-compatible attribute maps.
  """

  alias Kith.Contacts
  alias Kith.Contacts.Contact
  alias Kith.DAV.Store
  alias Kith.Repo
  alias Kith.Storage
  alias Kith.VCard.{Parser, Serializer}

  @doc """
  Converts a Kith contact to a vCard string with a CardDAV UID.

  Preloads required associations if not already loaded.

  Options:
    - `:version` — `:v30` (default) for vCard 3.0, `:v40` for vCard 4.0
    - `:preloaded` — use the caller's loaded DAV snapshot (default: false)
  """
  def contact_to_vcard(%Contact{} = contact, opts \\ []) do
    version = Keyword.get(opts, :version, :v30)
    include_photo = Keyword.get(opts, :include_photo, true)

    contact =
      if Keyword.get(opts, :preloaded, false) do
        contact
      else
        Store.ensure_rows(contact.account_id)
        Repo.preload(contact, Contacts.dav_preloads(), force: true)
      end

    contact = if include_photo, do: maybe_load_avatar_data(contact), else: contact

    Serializer.serialize(contact, version: version, include_uid: true)
  end

  @doc """
  Parses a vCard string into scalar attrs and nested data.

  Returns `{scalar_attrs, nested_data}` on success or `:error` on parse failure.

  `scalar_attrs` is a map suitable for `Contacts.create_contact/2`.
  `nested_data` contains `:emails`, `:phones`, `:urls`, `:addresses`, `:uid`.
  """
  def vcard_to_attrs(vcard_string, opts \\ []) do
    case Parser.parse(vcard_string) do
      {:ok, [parsed | _]} -> build_attrs(parsed, opts)
      _ -> :error
    end
  end

  defp build_attrs(parsed, opts) do
    account_id = Keyword.get(opts, :account_id)

    scalar_attrs =
      build_scalar_attrs(parsed)
      |> maybe_resolve_gender(parsed, account_id)
      |> maybe_strip_nils(opts)

    nested_data = build_nested_data(parsed)
    {scalar_attrs, nested_data}
  end

  defp build_scalar_attrs(parsed) do
    %{
      "first_name" => parsed.first_name || if(is_nil(parsed.last_name), do: parsed.display_name),
      "last_name" => parsed.last_name,
      "middle_name" => parsed.middle_name,
      "nickname" => parsed.nickname,
      "company" => parsed.company,
      "occupation" => parsed.occupation,
      "description" => parsed.description,
      "birthdate" => parsed.birthdate && Date.to_iso8601(parsed.birthdate),
      "birthdate_year_unknown" => parsed.birthdate_year_unknown
    }
  end

  defp build_nested_data(parsed) do
    %{
      emails: parsed.emails || [],
      phones: parsed.phones || [],
      urls: parsed.urls || [],
      addresses: parsed.addresses || [],
      uid: parsed.uid,
      categories: parsed.categories || [],
      related: parsed.related || [],
      impp: parsed.impp || [],
      photo: parsed.photo
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp maybe_strip_nils(attrs, opts) do
    if Keyword.get(opts, :strip_nils, true) do
      attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    else
      attrs
    end
  end

  # ── Avatar loading ──────────────────────────────────────────────────

  defp maybe_load_avatar_data(%Contact{avatar: nil} = contact), do: contact

  defp maybe_load_avatar_data(%Contact{avatar: key} = contact) do
    max_embed = Application.get_env(:kith, :max_vcard_photo_embed_bytes, 512 * 1024)

    case Storage.read(key) do
      {:ok, binary} when byte_size(binary) <= max_embed ->
        ct = Storage.content_type(key)
        %{contact | avatar_data: %{binary: binary, content_type: ct}}

      _ ->
        contact
    end
  end

  # ── Gender resolution ───────────────────────────────────────────────

  defp maybe_resolve_gender(attrs, _parsed, nil), do: attrs

  defp maybe_resolve_gender(attrs, parsed, account_id) do
    gender_name = resolve_gender_name(parsed.gender, parsed.gender_text)
    gender_record = gender_name && find_gender_by_name(account_id, gender_name)

    if gender_record,
      do: Map.put(attrs, "gender_id", gender_record.id),
      else: attrs
  end

  defp find_gender_by_name(account_id, name) do
    downcased = String.downcase(name)

    account_id
    |> Kith.Contacts.list_genders()
    |> Enum.find(fn g -> String.downcase(g.name) == downcased end)
  end

  defp resolve_gender_name("M", _), do: "Male"
  defp resolve_gender_name("F", _), do: "Female"
  defp resolve_gender_name("O", text) when is_binary(text) and text != "", do: text
  defp resolve_gender_name("N", _), do: nil
  defp resolve_gender_name("U", _), do: nil
  defp resolve_gender_name(nil, text) when is_binary(text) and text != "", do: text
  defp resolve_gender_name(_, _), do: nil
end
