defmodule Kith.DAV.PrincipalReports do
  @moduledoc """
  Account-scoped ACL principal reports and local DAV property expansion.

  The resolver receives only local DAV paths and must return properties from the
  caller's account and read snapshot. No HTTP requests are made. Principal-match
  receives the target collection's descendants in `target.members`; the other
  reports resolve existing principals through the account role view.
  """

  alias Kith.DAV.{AccessControl, XMLBuilder, XMLParser}

  @max_expansions 1_000
  @property_names %{
    current_user_principal: {"DAV:", "current-user-principal"},
    resourcetype: {"DAV:", "resourcetype"},
    displayname: {"DAV:", "displayname"},
    getetag: {"DAV:", "getetag"},
    getcontenttype: {"DAV:", "getcontenttype"},
    getlastmodified: {"DAV:", "getlastmodified"},
    supported_report_set: {"DAV:", "supported-report-set"},
    sync_token: {"DAV:", "sync-token"},
    principal_url: {"DAV:", "principal-URL"},
    owner: {"DAV:", "owner"},
    group: {"DAV:", "group"},
    alternate_uri_set: {"DAV:", "alternate-URI-set"},
    group_member_set: {"DAV:", "group-member-set"},
    group_membership: {"DAV:", "group-membership"},
    supported_privilege_set: {"DAV:", "supported-privilege-set"},
    current_user_privilege_set: {"DAV:", "current-user-privilege-set"},
    acl: {"DAV:", "acl"},
    acl_restrictions: {"DAV:", "acl-restrictions"},
    inherited_acl_set: {"DAV:", "inherited-acl-set"},
    principal_collection_set: {"DAV:", "principal-collection-set"},
    addressbook_home_set: {"urn:ietf:params:xml:ns:carddav", "addressbook-home-set"},
    address_data: {"urn:ietf:params:xml:ns:carddav", "address-data"},
    supported_address_data: {"urn:ietf:params:xml:ns:carddav", "supported-address-data"},
    max_resource_size: {"urn:ietf:params:xml:ns:carddav", "max-resource-size"},
    supported_collation_set: {"urn:ietf:params:xml:ns:carddav", "supported-collation-set"},
    getctag: {"http://calendarserver.org/ns/", "getctag"}
  }

  @doc "Returns {:ok, HTTP status, XML} or {:error, HTTP status, condition XML}."
  def render(scope, request, target, resolver) do
    render_report(scope, request, target, resolver)
  catch
    :expansion_limit -> {:error, 507, "<d:number-of-matches-within-limits/>"}
  end

  defp render_report(scope, %{type: :expand_property} = request, target, resolver) do
    hrefs = [target.href | Enum.map(Map.get(target, :members, []), & &1.href)] |> Enum.uniq()

    {responses, _remaining} =
      Enum.map_reduce(hrefs, @max_expansions, fn href, remaining ->
        expanded_response(scope, href, request.properties, resolver, remaining)
      end)

    {:ok, 207, XMLBuilder.multistatus(responses)}
  end

  defp render_report(scope, %{type: :acl_principal_prop_set} = request, _target, resolver) do
    responses =
      scope
      |> AccessControl.acl_principals()
      |> Enum.uniq_by(& &1.href)
      |> Enum.map(&principal_response(scope, &1, request.props, resolver))

    {:ok, 207, XMLBuilder.multistatus(responses)}
  end

  defp render_report(_scope, %{type: :principal_search_property_set}, target, _resolver) do
    if target.href in ["/dav/principals/users/", "/dav/principals/roles/"] do
      {:ok, 200, AccessControl.search_property_set()}
    else
      {:error, 403, "<d:supported-report/>"}
    end
  end

  defp render_report(scope, %{type: :principal_property_search} = request, target, resolver) do
    case AccessControl.search_principals(scope, request.searches) do
      {:ok, principals} ->
        principals =
          if request.apply_to_principal_collection_set,
            do: principals,
            else: Enum.filter(principals, &within?(&1.href, target.href))

        {:ok, 207,
         XMLBuilder.multistatus(
           Enum.map(principals, &principal_response(scope, &1, request.props, resolver))
         )}

      {:error, :unsupported_search_property} ->
        {:error, 403, "<k:supported-principal-search-property/>"}
    end
  end

  defp render_report(scope, %{type: :principal_match, match: :self} = request, target, resolver) do
    responses =
      scope
      |> AccessControl.matching_principals()
      |> Enum.filter(&within?(&1.href, target.href))
      |> Enum.map(&principal_response(scope, &1, request.props, resolver))

    {:ok, 207, XMLBuilder.multistatus(responses)}
  end

  defp render_report(
         scope,
         %{type: :principal_match, match: {:property, property}} = request,
         target,
         resolver
       ) do
    matching = scope |> AccessControl.matching_principals() |> Enum.map(& &1.href) |> MapSet.new()

    responses =
      target
      |> Map.get(:members, [])
      |> Enum.filter(&within?(&1.href, target.href))
      |> Enum.flat_map(
        &matching_member_response(scope, &1, property, matching, request.props, resolver)
      )

    {:ok, 207, XMLBuilder.multistatus(responses)}
  end

  defp matching_member_response(scope, member, property, matching, props, resolver) do
    with {:ok, properties} <- resource_properties(scope, member.href, resolver),
         true <- Enum.any?(hrefs(Map.get(properties, property)), &MapSet.member?(matching, &1)) do
      [property_response(member.href, properties, props)]
    else
      _ -> []
    end
  end

  defp principal_response(scope, principal, props, resolver) do
    {:ok, properties} = resource_properties(scope, principal.href, resolver)
    property_response(principal.href, properties, props)
  end

  defp property_response(href, _properties, nil),
    do: XMLBuilder.status_response(href, "HTTP/1.1 200 OK")

  defp property_response(href, properties, {:prop, requested}) do
    propstats =
      requested
      |> Enum.uniq()
      |> Enum.map(fn property ->
        case Map.fetch(properties, property) do
          {:ok, xml} -> XMLBuilder.propstat([xml])
          :error -> XMLBuilder.propstat([empty_property(property)], "HTTP/1.1 404 Not Found")
        end
      end)

    XMLBuilder.response(href, propstats)
  end

  defp resource_properties(scope, href, resolver) do
    if local_href?(href), do: local_properties(scope, href, resolver), else: :error
  end

  defp local_properties(scope, href, resolver) do
    case AccessControl.resolve_principal(scope, href) do
      {:ok, principal} ->
        properties = AccessControl.principal_properties(scope, principal)
        merge_resolved_properties(properties, resolver.(href))

      :error ->
        resolve_nonprincipal(href, resolver)
    end
  end

  defp merge_resolved_properties(properties, {:ok, extra}),
    do: {:ok, Map.merge(properties, extra)}

  defp merge_resolved_properties(properties, :error), do: {:ok, properties}

  defp resolve_nonprincipal(href, resolver) do
    if String.starts_with?(href, "/dav/principals/") and
         href not in ["/dav/principals/users/", "/dav/principals/roles/"] do
      :error
    else
      resolver.(href)
    end
  end

  defp expanded_response(_scope, _href, _properties, _resolver, 0), do: throw(:expansion_limit)

  defp expanded_response(scope, href, requested, resolver, remaining) do
    case resource_properties(scope, href, resolver) do
      {:ok, properties} ->
        {propstats, remaining} =
          Enum.map_reduce(
            requested,
            remaining - 1,
            &expanded_propstat(scope, properties, &1, resolver, &2)
          )

        {XMLBuilder.response(href, propstats), remaining}

      :error ->
        {XMLBuilder.status_response(href, "HTTP/1.1 404 Not Found"), remaining - 1}
    end
  end

  defp expanded_propstat(scope, properties, spec, resolver, budget) do
    case Map.fetch(properties, spec.property) do
      {:ok, xml} ->
        {xml, budget} = expand_value(scope, xml, spec.children, resolver, budget)
        {XMLBuilder.propstat([xml]), budget}

      :error ->
        {XMLBuilder.propstat([empty_property(spec.property)], "HTTP/1.1 404 Not Found"), budget}
    end
  end

  defp expand_value(_scope, xml, [], _resolver, remaining), do: {xml, remaining}

  defp expand_value(scope, xml, children, resolver, remaining) do
    {:ok, node} = XMLParser.parse_property_value(xml)

    render_node(
      node,
      fn href, budget -> expanded_response(scope, href, children, resolver, budget) end,
      remaining
    )
  end

  defp render_node(%{ns: "DAV:", name: "href", text: href}, expand, remaining),
    do: expand.(href, remaining)

  defp render_node(node, expand, remaining) do
    {content, remaining} =
      Enum.map_reduce(node.content, remaining, fn
        {:text, text}, budget -> {XMLBuilder.escape(text), budget}
        {:element, child}, budget -> render_node(child, expand, budget)
      end)

    {name, declarations} = qualified_name(node.ns, node.name, "x")

    attrs =
      Enum.with_index(node.attributes)
      |> Enum.map_join(fn {attribute, index} ->
        {name, ns} = qualified_name(attribute.ns, attribute.name, "a#{index}")
        ns <> " #{name}=\"#{XMLBuilder.escape(attribute.value)}\""
      end)

    {"<#{name}#{declarations}#{attrs}>#{Enum.join(content)}</#{name}>", remaining}
  end

  defp qualified_name("", name, _prefix), do: {name, ""}

  defp qualified_name("http://www.w3.org/XML/1998/namespace", name, _prefix),
    do: {"xml:#{name}", ""}

  defp qualified_name(ns, name, prefix),
    do: {"#{prefix}:#{name}", " xmlns:#{prefix}=\"#{XMLBuilder.escape(ns)}\""}

  defp hrefs(nil), do: []

  defp hrefs(xml) do
    case XMLParser.parse_property_value(xml) do
      {:ok, node} -> collect_hrefs(node)
      _ -> []
    end
  end

  defp collect_hrefs(%{ns: "DAV:", name: "href", text: href}), do: [href]
  defp collect_hrefs(node), do: Enum.flat_map(node.children, &collect_hrefs/1)

  defp within?(href, collection), do: href == collection or String.starts_with?(href, collection)

  defp local_href?(href),
    do: String.starts_with?(href, "/dav/") and not String.contains?(href, ["?", "#", "..", "\\"])

  defp empty_property(property) do
    {namespace, name} =
      if is_tuple(property), do: property, else: Map.fetch!(@property_names, property)

    XMLBuilder.empty_element(namespace, name)
  end
end
