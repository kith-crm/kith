defmodule Kith.DAV.XMLParser do
  @moduledoc """
  Parses WebDAV/CardDAV XML request bodies.

  Uses simple regex-based parsing rather than a full XML parser. DAV request
  bodies are well-structured and limited in vocabulary, so this approach is
  sufficient and avoids adding a dependency.
  """

  @doc """
  Parses a PROPFIND request body.

  Returns `{:ok, :allprop}`, `{:ok, :propname}`, or `{:ok, {:prop, props}}`
  where `props` is a list of atoms representing the requested properties.

  An empty body is treated as an allprop request per RFC 4918 Section 9.1.
  A body that is not well-formed UTF-8 XML returns `{:error, :invalid_xml}`.
  """
  def parse_propfind(body) when body in [nil, ""] do
    {:ok, :allprop}
  end

  def parse_propfind(body) do
    cond do
      String.trim(body) == "" ->
        {:ok, :allprop}

      parse_xml(body) == :error ->
        {:error, :invalid_xml}

      String.contains?(body, "<d:allprop") or String.contains?(body, "<D:allprop") ->
        {:ok, :allprop}

      String.contains?(body, "<d:propname") or String.contains?(body, "<D:propname") ->
        {:ok, :propname}

      true ->
        props = extract_requested_props(body)
        {:ok, {:prop, props}}
    end
  end

  @doc """
  Extracts href elements from an addressbook-multiget REPORT body.

  Returns `{:ok, hrefs}` where hrefs is a list of URI strings.
  """
  def parse_addressbook_multiget(body) do
    hrefs =
      Regex.scan(~r/<[dD]:href[^>]*>([^<]+)<\/[dD]:href>/i, body)
      |> Enum.map(fn [_, href] -> String.trim(href) end)

    {:ok, hrefs}
  end

  @doc """
  Extracts the sync-token from a sync-collection REPORT body.

  Returns `{:ok, token}` where token may be nil for an initial sync.
  """
  def parse_sync_collection(body) do
    token =
      case Regex.run(~r/<[dD]:sync-token[^>]*>([^<]*)<\/[dD]:sync-token>/i, body) do
        [_, token] when token != "" -> token
        _ -> nil
      end

    {:ok, token}
  end

  @doc """
  Parses an addressbook-query REPORT body.

  Returns `{:ok, filters}` where filters is a list of
  `%{property: name, match: text, match_type: type}` maps.

  Supports basic text-match on FN, EMAIL, TEL properties.
  """
  def parse_addressbook_query(body) do
    filters =
      Regex.scan(
        ~r/<card:prop-filter\s+name="([^"]+)"[^>]*>.*?<card:text-match[^>]*>([^<]+)<\/card:text-match>.*?<\/card:prop-filter>/si,
        body
      )
      |> Enum.map(fn [full_match, prop_name, text] ->
        match_type =
          case Regex.run(~r/match-type="([^"]+)"/, full_match) do
            [_, type] -> type
            _ -> "contains"
          end

        %{property: String.upcase(prop_name), match: String.trim(text), match_type: match_type}
      end)

    {:ok, filters}
  end

  @doc "Extracts the requested vCard version from an address-data element in a REPORT body."
  def parse_requested_vcard_version(body) do
    case Regex.run(~r{address-data[^>]*version="([^"]+)"}, body) do
      [_, "4.0"] -> :v40
      _ -> :v30
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  @known_props %{
    "displayname" => :displayname,
    "resourcetype" => :resourcetype,
    "getcontenttype" => :getcontenttype,
    "getetag" => :getetag,
    "getlastmodified" => :getlastmodified,
    "address-data" => :address_data,
    "getctag" => :getctag,
    "sync-token" => :sync_token,
    "current-user-principal" => :current_user_principal,
    "addressbook-home-set" => :addressbook_home_set,
    "supported-report-set" => :supported_report_set,
    "supported-address-data" => :supported_address_data,
    "principal-URL" => :principal_url,
    "owner" => :owner,
    "current-user-privilege-set" => :current_user_privilege_set,
    "max-resource-size" => :max_resource_size,
    "supported-collation-set" => :supported_collation_set
  }

  # Namespace-aware, non-validating parse with OTP's xmerl SAX parser.
  # Returns `{:ok, elements}`, the start tags in document order as
  # `{depth, namespace_uri, local_name}` (strings, so no atoms are created),
  # or `:error` for anything that is not well-formed UTF-8 XML. Entity
  # declarations are refused (no entity-expansion attacks).
  defp parse_xml(body) do
    opts = [event_fun: &sax_event/3, event_state: {0, []}, external_entities: :none]

    case :xmerl_sax_parser.stream(body, [:disallow_entities | opts]) do
      {:ok, {0, elements}, rest} ->
        if String.trim(to_string(rest)) == "", do: {:ok, Enum.reverse(elements)}, else: :error

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defp sax_event({:startElement, uri, local, _qname, _attrs}, _loc, {depth, acc}),
    do: {depth + 1, [{depth + 1, to_string(uri), to_string(local)} | acc]}

  defp sax_event({:endElement, _uri, _local, _qname}, _loc, {depth, acc}), do: {depth - 1, acc}
  defp sax_event(_event, _loc, state), do: state

  defp extract_requested_props(body) do
    for {name, atom} <- @known_props,
        String.contains?(body, name),
        do: atom
  end
end
