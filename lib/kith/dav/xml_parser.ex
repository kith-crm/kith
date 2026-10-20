defmodule Kith.DAV.XMLParser do
  @moduledoc """
  Parses WebDAV/CardDAV XML request bodies.

  PROPFIND and PROPPATCH bodies are parsed with OTP's namespace-aware xmerl
  SAX parser, so element prefixes (`d:`, `D:`, Apple's `A:`, a default
  `xmlns="DAV:"`) don't matter. REPORT bodies are parsed the same way (CDV-40).
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
  Parses a REPORT body and identifies the report by its root element.

  Returns one of
  - `{:ok, {:multiget, %{hrefs: hrefs, props: props, version: version}}}`
  - `{:ok, {:sync_collection, %{token: token_or_nil, props: props, version: version}}}`
  - `{:ok, {:query, %{filter: filter, limit: limit, props: props, version: version}}}`
  - `{:ok, {:unsupported, {namespace, local_name}}}` for any other root
  - `{:error, :invalid_xml}` for a body that is not well-formed UTF-8 XML

  `filter` is the `CARDDAV:filter` (RFC 6352 §10.5) as
  `%{test: test, prop_filters: [prop_filter]}`, each prop filter
  `%{name: name, test: test, is_not_defined: boolean, text_matches: [text_match],
  param_filters: [%{name: name, is_not_defined: boolean, text_match: text_match | nil}]}`
  and each text match `%{text: text, collation: c, negate: boolean, match_type: t}`.
  `props` is `:allprop`, `:propname` or `{:prop, props}` like `parse_propfind/1`.
  Attribute defaults are applied, values are not validated. `limit` is the
  `CARDDAV:limit/nresults` text, or nil.
  Element prefixes don't matter, only namespaces (CDV-40).
  """
  def parse_report(body) do
    case parse_tree(body || "") do
      {:ok, root} -> {:ok, report_request(root)}
      :error -> {:error, :invalid_xml}
    end
  end

  defp report_request(%{ns: @carddav, name: "addressbook-multiget"} = root) do
    hrefs = for %{ns: @dav, name: "href"} = el <- root.children, do: String.trim(text(el))
    {:multiget, %{hrefs: hrefs, props: report_props(root), version: requested_version(root)}}
  end

  defp report_request(%{ns: @dav, name: "sync-collection"} = root) do
    token =
      case child(root, @dav, "sync-token") do
        nil -> nil
        el -> el |> text() |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      end

    {:sync_collection,
     %{token: token, props: report_props(root), version: requested_version(root)}}
  end

  defp report_request(%{ns: @carddav, name: "addressbook-query"} = root) do
    filter =
      case child(root, @carddav, "filter") do
        nil -> %{test: "anyof", prop_filters: []}
        el -> %{test: Map.get(el.attrs, "test", "anyof"), prop_filters: prop_filters(el)}
      end

    {:query,
     %{
       filter: filter,
       limit: limit(root),
       props: report_props(root),
       version: requested_version(root)
     }}
  end

  defp report_request(root), do: {:unsupported, {root.ns, root.name}}

  defp prop_filters(filter) do
    for %{ns: @carddav, name: "prop-filter"} = el <- filter.children do
      %{
        name: el.attrs |> Map.get("name", "") |> String.upcase(),
        test: Map.get(el.attrs, "test", "anyof"),
        is_not_defined: child(el, @carddav, "is-not-defined") != nil,
        text_matches:
          for(%{ns: @carddav, name: "text-match"} = tm <- el.children, do: text_match(tm)),
        param_filters:
          for(%{ns: @carddav, name: "param-filter"} = pf <- el.children, do: param_filter(pf))
      }
    end
  end

  defp param_filter(el) do
    %{
      name: el.attrs |> Map.get("name", "") |> String.upcase(),
      is_not_defined: child(el, @carddav, "is-not-defined") != nil,
      text_match:
        case child(el, @carddav, "text-match") do
          nil -> nil
          tm -> text_match(tm)
        end
    }
  end

  defp text_match(el) do
    %{
      text: String.trim(text(el)),
      collation: Map.get(el.attrs, "collation", "i;unicode-casemap"),
      negate: Map.get(el.attrs, "negate-condition", "no") == "yes",
      match_type: Map.get(el.attrs, "match-type", "contains")
    }
  end

  defp limit(root) do
    with %{} = limit <- child(root, @carddav, "limit"),
         %{} = nresults <- child(limit, @carddav, "nresults") do
      String.trim(text(nresults))
    end
  end

  # The vCard version asked for by `DAV:prop/CARDDAV:address-data@version`.
  defp requested_version(root) do
    with %{} = prop <- child(root, @dav, "prop"),
         %{attrs: %{"version" => "4.0"}} <- child(prop, @carddav, "address-data") do
      :v40
    else
      _ -> :v30
    end
  end

  defp child(%{children: children}, ns, name),
    do: Enum.find(children, &(&1.ns == ns and &1.name == name))

  defp text(%{text: text}), do: text

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

  # The properties asked for, as `parse_propfind/1` returns them (CDV-44).
  defp report_props(root) do
    cond do
      child(root, @dav, "propname") ->
        :propname

      prop = child(root, @dav, "prop") ->
        {:prop,
         prop.children
         |> Enum.map(&Map.get(@known_props, {&1.ns, &1.name}, {&1.ns, &1.name}))
         |> Enum.uniq()}

      true ->
        :allprop
    end
  end

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

  # Namespace-aware parse into a tree of
  # `%{ns: uri, name: local, attrs: %{local => value}, children: [...], text: text}`
  # (strings only, so no atoms are created). Same safety rules as `parse_xml/1`.
  defp parse_tree(body) do
    opts = [event_fun: &tree_event/3, event_state: [], external_entities: :none]

    case :xmerl_sax_parser.stream(body, [:disallow_entities | opts]) do
      {:ok, [%{} = root], rest} ->
        if String.trim(to_string(rest)) == "", do: {:ok, root}, else: :error

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defp tree_event({:startElement, uri, local, _qname, attrs}, _loc, stack) do
    attrs =
      Map.new(attrs, fn {_uri, _prefix, name, value} -> {to_string(name), to_string(value)} end)

    node = %{ns: to_string(uri), name: to_string(local), attrs: attrs, children: [], text: ""}
    [node | stack]
  end

  defp tree_event({:characters, chars}, _loc, [node | rest]),
    do: [%{node | text: node.text <> to_string(chars)} | rest]

  defp tree_event({:endElement, _uri, _local, _qname}, _loc, [node | rest]) do
    node = %{node | children: Enum.reverse(node.children)}

    case rest do
      [parent | above] -> [%{parent | children: [node | parent.children]} | above]
      [] -> [node]
    end
  end

  defp tree_event(_event, _loc, stack), do: stack
end
