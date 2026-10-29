defmodule Kith.DAV.XMLParser do
  @moduledoc """
  Parses WebDAV/CardDAV XML request bodies.

  PROPFIND and PROPPATCH bodies are parsed with OTP's namespace-aware xmerl
  SAX parser, so element prefixes (`d:`, `D:`, Apple's `A:`, a default
  `xmlns="DAV:"`) don't matter. REPORT bodies are parsed the same way.
  """

  @dav "DAV:"
  @carddav "urn:ietf:params:xml:ns:carddav"
  @cs "http://calendarserver.org/ns/"

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
    {@dav, "group"} => :group,
    {@dav, "alternate-URI-set"} => :alternate_uri_set,
    {@dav, "group-member-set"} => :group_member_set,
    {@dav, "group-membership"} => :group_membership,
    {@dav, "supported-privilege-set"} => :supported_privilege_set,
    {@dav, "acl"} => :acl,
    {@dav, "acl-restrictions"} => :acl_restrictions,
    {@dav, "inherited-acl-set"} => :inherited_acl_set,
    {@dav, "principal-collection-set"} => :principal_collection_set,
    {@dav, "current-user-privilege-set"} => :current_user_privilege_set,
    {@carddav, "address-data"} => :address_data,
    {@carddav, "addressbook-home-set"} => :addressbook_home_set,
    {@carddav, "supported-address-data"} => :supported_address_data,
    {@carddav, "max-resource-size"} => :max_resource_size,
    {@carddav, "supported-collation-set"} => :supported_collation_set,
    {@cs, "getctag"} => :getctag
  }

  @doc """
  Parses a PROPFIND request body.

  Returns `{:ok, :allprop}`, `{:ok, {:allprop, included_props}}`,
  `{:ok, :propname}`, or `{:ok, {:prop, props}}`
  where `props` lists the requested properties: an atom for each property the
  server knows, `{namespace, local_name}` for any other.

  An empty body is treated as an allprop request per RFC 4918 Section 9.1.
  Malformed XML or an invalid selector combination returns `{:error, :invalid_xml}`.
  """
  def parse_propfind(body) when body in [nil, ""] do
    {:ok, :allprop}
  end

  def parse_propfind(body) do
    if String.trim(body) == "" do
      {:ok, :allprop}
    else
      case parse_tree(body) do
        {:ok, %{ns: @dav, name: "propfind"} = root} -> propfind_request(root)
        _ -> {:error, :invalid_xml}
      end
    end
  end

  defp propfind_request(root) do
    # RFC 4918 §§14.20/17: ignore unknown extensions (including their
    # descendants), then require exactly one selector. Include is valid only
    # with allprop; element order is immaterial.
    instructions =
      for %{ns: @dav, name: name} <- root.children,
          name in ["allprop", "propname", "prop", "include"],
          do: name

    selectors =
      Enum.filter(root.children, &(&1.ns == @dav and &1.name in instructions))

    valid_text? =
      String.trim(root.text) == "" and
        Enum.all?(selectors, fn selector ->
          String.trim(selector.text) == "" and
            (selector.name not in ["prop", "include"] or
               Enum.all?(selector.children, &(String.trim(&1.text) == "")))
        end)

    select_propfind(if(valid_text?, do: Enum.sort(instructions), else: []), root)
  end

  defp select_propfind(instructions, root) do
    case instructions do
      ["allprop"] -> {:ok, :allprop}
      ["allprop", "include"] -> {:ok, {:allprop, property_names(child(root, @dav, "include"))}}
      ["propname"] -> {:ok, :propname}
      ["prop"] -> {:ok, {:prop, property_names(child(root, @dav, "prop"))}}
      _ -> {:error, :invalid_xml}
    end
  end

  defp property_names(node) do
    node.children
    |> Enum.map(&Map.get(@known_props, {&1.ns, &1.name}, {&1.ns, &1.name}))
    |> Enum.uniq()
  end

  @doc """
  Parses a PROPPATCH (`DAV:propertyupdate`) body into ordered instructions.

  Each instruction contains `:action` (`:set` or `:remove`), `:property`
  (a known property atom or `{namespace, local_name}`), and `:value` (the
  property XML tree). Repeated properties and XML values are retained.
  Invalid instruction structure returns `{:error, :invalid_xml}`.
  """
  def parse_proppatch(body) do
    with {:ok, %{ns: @dav, name: "propertyupdate"} = root} <- parse_tree(body || ""),
         true <- String.trim(root.text) == "",
         operations when operations != [] <-
           Enum.filter(root.children, &(&1.ns == @dav and &1.name in ["set", "remove"])),
         {:ok, instructions} <- proppatch_instructions(operations) do
      {:ok, instructions}
    else
      _ -> {:error, :invalid_xml}
    end
  end

  defp proppatch_instructions(operations) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, acc} ->
      case proppatch_operation(operation) do
        {:ok, instructions} -> {:cont, {:ok, [instructions | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, instructions} -> {:ok, instructions |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp proppatch_operation(operation) do
    with [prop] <- dav_children(operation, ["prop"]),
         true <- valid_update_properties?(operation, prop) do
      action = update_action(operation.name)

      instructions =
        Enum.map(prop.children, &%{action: action, property: property_identity(&1), value: &1})

      {:ok, instructions}
    else
      _ -> {:error, :invalid_xml}
    end
  end

  defp valid_update_properties?(operation, prop) do
    blank_text?(operation) and blank_text?(prop) and prop.children != [] and
      valid_update_values?(operation.name, prop.children)
  end

  defp valid_update_values?("set", _properties), do: true

  defp valid_update_values?("remove", properties),
    do: Enum.all?(properties, &(&1.children == [] and &1.text == ""))

  defp update_action("set"), do: :set
  defp update_action("remove"), do: :remove

  @doc """
  Parses a REPORT body and identifies the report by its root element.

  Returns one of
  - `{:ok, {:multiget, %{hrefs: hrefs, props: props, version: version}}}`
  - `{:ok, {:sync_collection, %{token: token_or_nil, limit: limit, props: props, version: version}}}`
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
  Element prefixes don't matter, only namespaces.
  """
  def parse_report(body) do
    case parse_tree(body || "") do
      {:ok, %{ns: @dav, name: name} = root}
      when name in [
             "expand-property",
             "acl-principal-prop-set",
             "principal-match",
             "principal-property-search",
             "principal-search-property-set"
           ] ->
        principal_report_request(root)

      {:ok, root} ->
        {:ok, report_request(root)}

      :error ->
        {:error, :invalid_xml}
    end
  end

  @doc "Validates the structure of an ACL request without changing account policy."
  def parse_acl(body) do
    case parse_acl_tree(body) do
      {:ok, _root} -> :ok
      error -> error
    end
  end

  @doc false
  def parse_acl_tree(body) do
    with {:ok, %{ns: @dav, name: "acl"} = root} <- parse_tree(body || ""),
         true <- blank_text?(root),
         true <- Enum.all?(dav_children(root, ["ace"]), &valid_ace?/1) do
      {:ok, root}
    else
      _ -> {:error, :invalid_xml}
    end
  end

  defp valid_ace?(ace) do
    with true <- blank_text?(ace),
         [principal] <- dav_children(ace, ["principal"]),
         true <- blank_text?(principal),
         [identity] <- principal.children,
         true <- valid_ace_principal?(identity),
         [permission] <- dav_children(ace, ["grant", "deny"]),
         true <- blank_text?(permission),
         privileges when privileges != [] <- dav_children(permission, ["privilege"]) do
      Enum.all?(privileges, fn privilege ->
        blank_text?(privilege) and length(privilege.children) == 1 and
          Enum.all?(privilege.children, &empty_property?/1)
      end)
    else
      _ -> false
    end
  end

  defp valid_ace_principal?(%{ns: @dav, name: "href", children: [], text: text}),
    do: String.trim(text) != ""

  defp valid_ace_principal?(%{ns: @dav, name: name} = node)
       when name in ["all", "authenticated", "unauthenticated", "self"],
       do: empty_property?(node)

  defp valid_ace_principal?(%{ns: @dav, name: "property", children: [property]} = node),
    do: blank_text?(node) and empty_property?(property)

  defp valid_ace_principal?(_), do: false

  @doc false
  def parse_property_value(xml) do
    wrapper =
      ~s(<d:value xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">#{xml}</d:value>)

    case parse_tree(wrapper) do
      {:ok, %{children: [property], text: text}} ->
        if String.trim(text) == "", do: {:ok, property}, else: {:error, :invalid_xml}

      _ ->
        {:error, :invalid_xml}
    end
  end

  defp principal_report_request(root) do
    case principal_report_body(root) do
      {:ok, request} -> {:ok, {:principal_report, request}}
      _ -> {:error, :invalid_xml}
    end
  end

  defp principal_report_body(%{name: "expand-property"} = root) do
    with true <- blank_text?(root),
         {:ok, properties} <- expansion_properties(root, 0) do
      {:ok, %{type: :expand_property, properties: properties}}
    end
  end

  defp principal_report_body(%{name: "acl-principal-prop-set"} = root) do
    with true <- blank_text?(root),
         {:ok, props} <- principal_report_props(root) do
      {:ok, %{type: :acl_principal_prop_set, props: props}}
    end
  end

  defp principal_report_body(%{name: "principal-search-property-set"} = root) do
    if blank_text?(root) and root.children == [],
      do: {:ok, %{type: :principal_search_property_set}},
      else: :error
  end

  defp principal_report_body(%{name: "principal-match"} = root),
    do: principal_match_request(root)

  defp principal_report_body(%{name: "principal-property-search"} = root),
    do: principal_search_request(root)

  defp principal_match_request(root) do
    selectors = dav_children(root, ["self", "principal-property"])

    with true <- blank_text?(root),
         [selector] <- selectors,
         {:ok, props} <- principal_report_props(root),
         {:ok, match} <- principal_match_selector(selector) do
      {:ok, %{type: :principal_match, match: match, props: props}}
    end
  end

  defp principal_match_selector(%{name: "self", children: [], text: ""}), do: {:ok, :self}

  defp principal_match_selector(%{name: "principal-property", children: [property]} = node) do
    if blank_text?(node) and empty_property?(property),
      do: {:ok, {:property, property_identity(property)}},
      else: :error
  end

  defp principal_match_selector(_), do: :error

  defp principal_search_request(root) do
    searches = dav_children(root, ["property-search"])
    apply = dav_children(root, ["apply-to-principal-collection-set"])

    with true <- blank_text?(root) and searches != [],
         true <- length(apply) <= 1 and Enum.all?(apply, &empty_property?/1),
         {:ok, props} <- principal_report_props(root),
         {:ok, searches} <- parse_principal_searches(searches) do
      {:ok,
       %{
         type: :principal_property_search,
         searches: searches,
         props: props,
         apply_to_principal_collection_set: apply != []
       }}
    end
  end

  defp parse_principal_searches(searches) do
    Enum.reduce_while(searches, {:ok, []}, fn search, {:ok, acc} ->
      with true <- blank_text?(search),
           [prop] <- dav_children(search, ["prop"]),
           true <-
             blank_text?(prop) and prop.children != [] and
               Enum.all?(prop.children, &empty_property?/1),
           [%{children: []} = match] <- dav_children(search, ["match"]) do
        item = %{properties: Enum.map(prop.children, &property_identity/1), match: match.text}
        {:cont, {:ok, [item | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, searches} -> {:ok, Enum.reverse(searches)}
      error -> error
    end
  end

  defp principal_report_props(root) do
    case dav_children(root, ["prop"]) do
      [] ->
        {:ok, nil}

      [prop] ->
        if blank_text?(prop) and Enum.all?(prop.children, &empty_property?/1),
          do: {:ok, {:prop, Enum.map(prop.children, &property_identity/1)}},
          else: :error

      _ ->
        :error
    end
  end

  defp expansion_properties(_node, depth) when depth > 8, do: :error

  defp expansion_properties(node, depth) do
    Enum.reduce_while(dav_children(node, ["property"]), {:ok, []}, fn property, {:ok, acc} ->
      name = unqualified_attribute(property, "name", "")
      namespace = unqualified_attribute(property, "namespace", @dav)

      with true <- blank_text?(property) and valid_property_name?(name),
           {:ok, children} <- expansion_properties(property, depth + 1) do
        identity = Map.get(@known_props, {namespace, name}, {namespace, name})
        {:cont, {:ok, [%{property: identity, children: children} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, properties} -> {:ok, Enum.reverse(properties)}
      error -> error
    end
  end

  defp unqualified_attribute(node, name, default) do
    case Enum.find(node.attributes, &(&1.ns == "" and &1.name == name)) do
      nil -> default
      attribute -> attribute.value
    end
  end

  defp valid_property_name?(name), do: Regex.match?(~r/\A[\p{L}_][\p{L}\p{N}_.-]*\z/u, name)

  defp dav_children(node, names),
    do: Enum.filter(node.children, &(&1.ns == @dav and &1.name in names))

  defp blank_text?(node), do: String.trim(node.text) == ""
  defp empty_property?(node), do: node.children == [] and blank_text?(node)

  defp property_identity(node),
    do: Map.get(@known_props, {node.ns, node.name}, {node.ns, node.name})

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
     %{
       token: token,
       limit: limit(root, @dav),
       props: report_props(root),
       version: requested_version(root)
     }}
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
       limit: limit(root, @carddav),
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

  # `<limit><nresults>` in CARDDAV: (query) or DAV: (sync-collection)
  defp limit(root, ns) do
    with %{} = limit <- child(root, ns, "limit"),
         %{} = nresults <- child(limit, ns, "nresults") do
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

  # The properties asked for, as `parse_propfind/1` returns them.
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

  # Namespace-aware parse into a tree of
  # `%{ns: uri, name: local, attrs: %{local => value}, children: [...], text: text}`
  # (strings only, so no atoms are created). Entity declarations are refused.
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
    attributes =
      Enum.map(attrs, fn {uri, _prefix, name, value} ->
        %{ns: to_string(uri), name: to_string(name), value: to_string(value)}
      end)

    node = %{
      ns: to_string(uri),
      name: to_string(local),
      attrs: Map.new(attributes, &{&1.name, &1.value}),
      attributes: attributes,
      children: [],
      content: [],
      text: ""
    }

    [node | stack]
  end

  defp tree_event({:characters, chars}, _loc, [node | rest]) do
    value = to_string(chars)
    [%{node | text: node.text <> value, content: [{:text, value} | node.content]} | rest]
  end

  defp tree_event({:endElement, _uri, _local, _qname}, _loc, [node | rest]) do
    node = %{node | children: Enum.reverse(node.children), content: Enum.reverse(node.content)}

    case rest do
      [parent | above] ->
        [
          %{
            parent
            | children: [node | parent.children],
              content: [{:element, node} | parent.content]
          }
          | above
        ]

      [] ->
        [node]
    end
  end

  defp tree_event(_event, _loc, stack), do: stack
end
