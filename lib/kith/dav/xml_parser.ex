defmodule Kith.DAV.XMLParser do
  @moduledoc """
  Parses WebDAV/CardDAV XML request bodies.

  PROPFIND and PROPPATCH bodies are parsed with OTP's namespace-aware xmerl
  SAX parser, so element prefixes (`d:`, `D:`, Apple's `A:`, a default
  `xmlns="DAV:"`) don't matter. REPORT bodies still use regex extraction.
  """

  @dav "DAV:"
  @carddav "urn:ietf:params:xml:ns:carddav"
  @cs "http://calendarserver.org/ns/"

  @doc """
  Parses a PROPFIND request body.

  Returns `{:ok, :allprop}`, `{:ok, :propname}`, or `{:ok, {:prop, props}}`
  where `props` lists the requested properties: an atom for each property the
  server knows, `{namespace, local_name}` for any other.

  An empty body is treated as an allprop request per RFC 4918 Section 9.1.
  A body that is not well-formed UTF-8 XML returns `{:error, :invalid_xml}`.
  """
  def parse_propfind(body) when body in [nil, ""] do
    {:ok, :allprop}
  end

  def parse_propfind(body) do
    if String.trim(body) == "" do
      {:ok, :allprop}
    else
      case parse_xml(body) do
        {:ok, [{1, @dav, "propfind"} | elements]} -> {:ok, propfind_request(elements)}
        _ -> {:error, :invalid_xml}
      end
    end
  end

  defp propfind_request(elements) do
    instructions = for {2, @dav, name} <- elements, do: name

    cond do
      "propname" in instructions -> :propname
      "prop" in instructions -> {:prop, requested_props(elements, 2)}
      true -> :allprop
    end
  end

  @doc """
  Parses a PROPPATCH (`DAV:propertyupdate`) body.

  Returns `{:ok, props}` listing the properties named by every `set` and
  `remove` instruction, or `{:error, :invalid_xml}`.
  """
  def parse_proppatch(body) do
    case parse_xml(body || "") do
      {:ok, [{1, @dav, "propertyupdate"} | elements]} -> {:ok, requested_props(elements, 3)}
      _ -> {:error, :invalid_xml}
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
    {@dav, "displayname"} => :displayname,
    {@dav, "resourcetype"} => :resourcetype,
    {@dav, "getcontenttype"} => :getcontenttype,
    {@dav, "getetag"} => :getetag,
    {@dav, "getlastmodified"} => :getlastmodified,
    {@dav, "sync-token"} => :sync_token,
    {@dav, "current-user-principal"} => :current_user_principal,
    {@dav, "supported-report-set"} => :supported_report_set,
    {@dav, "principal-URL"} => :principal_url,
    {@dav, "owner"} => :owner,
    {@dav, "current-user-privilege-set"} => :current_user_privilege_set,
    {@carddav, "address-data"} => :address_data,
    {@carddav, "addressbook-home-set"} => :addressbook_home_set,
    {@carddav, "supported-address-data"} => :supported_address_data,
    {@carddav, "max-resource-size"} => :max_resource_size,
    {@carddav, "supported-collation-set"} => :supported_collation_set,
    {@cs, "getctag"} => :getctag
  }

  # The props named by the children of the `DAV:prop` elements found at
  # `depth` (2 inside `propfind`, 3 inside `propertyupdate/set|remove`).
  # Known props become atoms; unknown ones stay `{namespace, local_name}`.
  defp requested_props(elements, depth) do
    elements
    |> children_of(depth, {@dav, "prop"})
    |> Enum.map(&Map.get(@known_props, &1, &1))
    |> Enum.uniq()
  end

  defp children_of(elements, depth, parent) do
    {_inside, names} =
      Enum.reduce(elements, {false, []}, fn {d, ns, name}, {inside, acc} ->
        cond do
          d == depth -> {{ns, name} == parent, acc}
          d < depth -> {false, acc}
          d == depth + 1 and inside -> {inside, [{ns, name} | acc]}
          true -> {inside, acc}
        end
      end)

    Enum.reverse(names)
  end

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
end
