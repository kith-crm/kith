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
  alias Kith.DAV.{Document, Store, UID}
  alias Kith.Repo
  alias Kith.VCard.Document, as: VCardDocument
  alias Kith.VCard.Parser

  @doc """
  Converts a Kith contact to a vCard string with a CardDAV UID.

  Preloads required associations if not already loaded.

  Options:
    - `:version` — `:v30` (default) for vCard 3.0, `:v40` for vCard 4.0
    - `:preloaded` — use the caller's loaded DAV snapshot (default: false)
  """
  def contact_to_vcard(%Contact{} = contact, opts \\ []) do
    version = Keyword.get(opts, :version, :v30)

    contact =
      if Keyword.get(opts, :preloaded, false) do
        contact
      else
        Store.ensure_rows(contact.account_id)
        Repo.preload(contact, Contacts.dav_preloads(), force: true)
      end

    Document.render(contact, Keyword.put(opts, :version, version))
  end

  @doc """
  Parses a vCard string into scalar attrs and nested data.

  Returns `{scalar_attrs, nested_data}` on success or `:error` on parse failure.

  `scalar_attrs` is a map suitable for `Contacts.create_contact/2`.
  `nested_data` contains `:emails`, `:phones`, `:urls`, `:addresses`, `:uid`.
  """
  def vcard_to_attrs(vcard_string, opts \\ []) do
    with {:ok, document} <- VCardDocument.parse(vcard_string),
         true <- length(VCardDocument.properties(document, "UID")) <= 1,
         public_document <- shared_input(document),
         parsed <- Parser.from_properties(public_document.properties, legacy_bday: false),
         {attrs, nested} <- normalize_identity(parsed, opts) do
      nested =
        nested
        |> Map.put(:dav_document, vcard_string)
        |> Map.put(:dav_parsed_document, document)
        |> Map.put(:related, relationship_entries(document))
        |> Map.put(
          :categories,
          document.properties
          |> Enum.filter(&(&1.normalized_name == "CATEGORIES"))
          |> Enum.flat_map(&Document.category_values(&1.value))
          |> Enum.uniq()
        )

      {attrs, nested}
    else
      _ -> :error
    end
  end

  defp relationship_entries(document) do
    document.properties
    |> Enum.filter(&(&1.normalized_name in ["RELATED", "X-KITH-RELATED"]))
    |> Enum.map(fn property ->
      params = Map.new(property.parameters, &{&1.normalized_name, &1.values})

      %{
        value: unescape(property.value),
        type: params |> Map.get("TYPE", ["contact"]) |> hd(),
        value_type: params |> Map.get("VALUE", ["uri"]) |> hd() |> String.downcase()
      }
    end)
  end

  defp unescape(value), do: Parser.unescape(value)

  defp shared_input(document) do
    allowed =
      ~w(VERSION UID FN N NICKNAME BDAY ORG TITLE EMAIL TEL URL ADR CATEGORIES RELATED X-KITH-RELATED PHOTO)

    %{document | properties: Enum.filter(document.properties, &(&1.normalized_name in allowed))}
  end

  defp normalize_identity(%{uid: nil} = parsed, opts), do: build_attrs(parsed, opts)

  defp normalize_identity(parsed, opts) do
    case UID.normalize(parsed.uid) do
      {:ok, uid} -> build_attrs(%{parsed | uid: uid}, opts)
      _ -> :error
    end
  end

  defp build_attrs(parsed, opts) do
    scalar_attrs =
      build_scalar_attrs(parsed)
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
end
