defmodule Kith.DAV.CardDAVPlug do
  @moduledoc """
  CardDAV server implementation as a Phoenix Plug.

  Handles the WebDAV/CardDAV protocol methods (PROPFIND, REPORT, GET, PUT,
  DELETE, OPTIONS) to provide bidirectional contact sync with DAV clients
  such as Apple Contacts, DAVx5 (Android), and Thunderbird.

  ## URL structure

      /dav/                              — DAV root (discovery)
      /dav/principals/                   — user principal
      /dav/addressbooks/                 — addressbook home set
      /dav/addressbooks/default/         — default address book collection
      /dav/addressbooks/default/:uid.vcf — individual contact resource

  ## Authentication

  All requests require HTTP Basic Auth (via `Kith.DAV.Auth`).
  """

  import Plug.Conn

  alias Kith.Contacts
  alias Kith.Contacts.Contact
  alias Kith.DAV.{AddressObject, AddressQuery, Auth, Store, VCardAdapter, XMLBuilder, XMLParser}
  alias Kith.Repo

  @behaviour Plug

  # Mapping from property atoms (as parsed by XMLParser) to their empty XML element
  # for propname responses and 404 propstat identification.
  @prop_empty_elements %{
    current_user_principal: "<d:current-user-principal/>",
    resourcetype: "<d:resourcetype/>",
    displayname: "<d:displayname/>",
    getetag: "<d:getetag/>",
    getcontenttype: "<d:getcontenttype/>",
    getlastmodified: "<d:getlastmodified/>",
    address_data: "<card:address-data/>",
    addressbook_home_set: "<card:addressbook-home-set/>",
    supported_address_data: "<card:supported-address-data/>",
    supported_report_set: "<d:supported-report-set/>",
    getctag: "<cs:getctag/>",
    sync_token: "<d:sync-token/>",
    principal_url: "<d:principal-URL/>",
    owner: "<d:owner/>",
    current_user_privilege_set: "<d:current-user-privilege-set/>",
    max_resource_size: "<card:max-resource-size/>",
    supported_collation_set: "<card:supported-collation-set/>"
  }

  @max_resource_size 1_048_576
  @drain_limit 16 * 1_048_576

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = Auth.require_auth(conn)
    if conn.halted, do: conn, else: route(conn)
  end

  defp route(conn) do
    path = conn.request_path |> String.trim_trailing("/")
    dispatch(conn, conn.method, path_segments(path))
  end

  defp dispatch(conn, "OPTIONS", _), do: handle_options(conn)
  defp dispatch(conn, "PROPFIND", ["dav"]), do: propfind(conn, &handle_root_propfind/2)

  defp dispatch(conn, "PROPFIND", ["dav", "principals"]),
    do: propfind(conn, &handle_principal_propfind/2)

  defp dispatch(conn, "PROPFIND", ["dav", "addressbooks"]),
    do: propfind(conn, &handle_home_propfind/2)

  defp dispatch(conn, "PROPFIND", ["dav", "addressbooks", "default"]),
    do: propfind(conn, &handle_addressbook_propfind/2)

  defp dispatch(conn, "PROPFIND", ["dav", "addressbooks", "default", _uid]),
    do: propfind(conn, &handle_contact_propfind/2)

  defp dispatch(conn, "REPORT", ["dav", "addressbooks", "default"]), do: handle_report(conn)

  # RFC 6352 §8.7: addressbook-multiget may target an address object
  defp dispatch(conn, "REPORT", ["dav", "addressbooks", "default", raw]),
    do: handle_member_report(conn, raw)

  # Existing resources that support no report: 403 supported-report
  defp dispatch(conn, "REPORT", segments)
       when segments in [["dav"], ["dav", "principals"], ["dav", "addressbooks"]],
       do: with_body(conn, &unsupported_report/2)

  defp dispatch(conn, "GET", ["dav", "addressbooks", "default", raw]),
    do: handle_get_contact(conn, raw)

  defp dispatch(conn, "PUT", ["dav", "addressbooks", "default", raw]),
    do: authorize(conn, :update, fn -> handle_put_contact(conn, raw) end)

  defp dispatch(conn, "DELETE", ["dav", "addressbooks", "default", raw]),
    do: authorize(conn, :delete, fn -> handle_delete_contact(conn, raw) end)

  # RFC 4918 §8.2: PROPPATCH stub — live properties cannot be modified
  defp dispatch(conn, "PROPPATCH", ["dav", "addressbooks", "default"]),
    do: handle_proppatch(conn)

  # RFC 9110 §15.5.6: a collection exists but cannot be deleted or replaced
  # over DAV, so DELETE / PUT there is a 405 with Allow, not a 404.
  defp dispatch(conn, method, ["dav", "addressbooks", "default"])
       when method in ["DELETE", "PUT"],
       do: method_not_allowed(conn, "OPTIONS, PROPFIND, PROPPATCH, REPORT")

  defp dispatch(conn, method, segments)
       when method in ["DELETE", "PUT"] and
              segments in [["dav"], ["dav", "principals"], ["dav", "addressbooks"]],
       do: method_not_allowed(conn, "OPTIONS, PROPFIND")

  # Redirect .well-known/carddav appearing as sub-path (Thunderbird fallback per RFC 6764)
  defp dispatch(conn, _, segments) do
    if ".well-known" in segments and "carddav" in segments do
      conn
      |> put_resp_header("location", "/dav/principals/")
      |> send_resp(301, "")
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp method_not_allowed(conn, allow) do
    conn
    |> put_resp_header("allow", allow)
    |> send_resp(405, "Method Not Allowed")
  end

  defp path_segments(path) do
    path |> String.split("/") |> Enum.reject(&(&1 == ""))
  end

  defp account_id(conn), do: conn.assigns.current_scope.account.id

  defp authorize(conn, action, fun) do
    if Kith.Policy.can?(conn.assigns.current_scope.user, action, :contact),
      do: fun.(),
      else: send_resp(conn, 403, "Forbidden")
  end

  defp handle_options(conn) do
    conn
    |> put_resp_header("dav", "1, 2, 3, addressbook")
    |> put_resp_header("allow", "OPTIONS, GET, PUT, DELETE, PROPFIND, PROPPATCH, REPORT")
    |> send_resp(200, "")
  end

  # Parses the PROPFIND body and hands the request type to `handler`.
  # A body that is not well-formed XML is a 400 (RFC 4918 §8.7).
  defp propfind(conn, handler) do
    with_body(conn, fn conn, body ->
      case XMLParser.parse_propfind(body) do
        {:ok, request_type} -> handler.(conn, request_type)
        {:error, _} -> send_resp(conn, 400, "Bad Request")
      end
    end)
  end

  # Reads a request body (XML or vCard) of at most the advertised max-resource-size;
  # anything larger is a 413, never a MatchError.
  # Bandit ignores `:length` for a chunked body and returns it whole, so the
  # size of what was read is checked too.
  defp with_body(conn, fun) do
    case read_body(conn, length: @max_resource_size) do
      {:ok, body, conn} when byte_size(body) <= @max_resource_size ->
        fun.(conn, body)

      {:ok, _too_big, conn} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:more, _partial, conn} ->
        conn |> drain_body(@drain_limit) |> send_resp(413, "Request Entity Too Large")

      {:error, _} ->
        send_resp(conn, 400, "Bad Request")
    end
  end

  # Reads and discards the rest of an oversized body (bounded) before the 413,
  # so the connection is clean and a client still uploading reads the answer
  # instead of a reset (RFC 9112 §9.6). Past the bound the connection is closed.
  defp drain_body(conn, budget) when budget <= 0,
    do: put_resp_header(conn, "connection", "close")

  defp drain_body(conn, budget) do
    case read_body(conn, length: @max_resource_size) do
      {:ok, _rest, conn} -> conn
      {:more, chunk, conn} -> drain_body(conn, budget - byte_size(chunk))
      {:error, _} -> put_resp_header(conn, "connection", "close")
    end
  end

  defp handle_root_propfind(conn, request_type) do
    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/>")
    ]

    propstats = build_propstats(request_type, props)
    xml = XMLBuilder.multistatus([XMLBuilder.response("/dav/", propstats)])
    send_dav_response(conn, 207, xml)
  end

  defp handle_principal_propfind(conn, request_type) do
    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      principal_url: XMLBuilder.principal_url("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/><d:principal/>"),
      addressbook_home_set:
        "<card:addressbook-home-set><d:href>/dav/addressbooks/</d:href></card:addressbook-home-set>"
    ]

    propstats = build_propstats(request_type, props)
    xml = XMLBuilder.multistatus([XMLBuilder.response("/dav/principals/", propstats)])
    send_dav_response(conn, 207, xml)
  end

  defp handle_home_propfind(conn, request_type) do
    home_props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/>"),
      displayname: XMLBuilder.displayname("Address Books")
    ]

    default_props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/><card:addressbook/>"),
      displayname: XMLBuilder.displayname("Kith Contacts"),
      supported_address_data: XMLBuilder.supported_address_data()
    ]

    home = XMLBuilder.response("/dav/addressbooks/", build_propstats(request_type, home_props))

    # RFC 4918 §9.1: Depth 0 is the home set alone. A missing Depth header keeps
    # the historical behaviour of listing the child address book.
    responses =
      if get_req_header(conn, "depth") == ["0"] do
        [home]
      else
        [
          home,
          XMLBuilder.response(
            "/dav/addressbooks/default/",
            build_propstats(request_type, default_props)
          )
        ]
      end

    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp handle_addressbook_propfind(conn, request_type) do
    depth = get_req_header(conn, "depth") |> List.first("0")

    # RFC 4918 §9.1.4: Reject Depth: infinity
    if depth == "infinity" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:error xmlns:d="DAV:"><d:propfind-finite-depth/></d:error>
      """

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(403, xml)
    else
      handle_addressbook_propfind_depth(conn, request_type, depth)
    end
  end

  defp handle_addressbook_propfind_depth(conn, request_type, depth) do
    responses = [addressbook_response(conn, request_type)]
    contacts = list_contacts_for_propfind(conn)

    responses =
      if depth != "0" do
        responses ++ Enum.map(contacts, &contact_member_response(&1, request_type))
      else
        responses
      end

    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp contact_member_response(contact, request_type) do
    etag = compute_etag(contact)

    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      getetag: XMLBuilder.getetag(etag),
      getcontenttype: XMLBuilder.getcontenttype("text/vcard; charset=utf-8"),
      getlastmodified: XMLBuilder.getlastmodified(contact.updated_at)
    ]

    XMLBuilder.response(
      Store.href(contact),
      build_propstats(request_type, props)
    )
  end

  defp handle_contact_propfind(conn, request_type) do
    uid = List.last(path_segments(conn.request_path))

    case find_contact_by_name(conn, uid) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        xml = XMLBuilder.multistatus([contact_member_response(contact, request_type)])
        send_dav_response(conn, 207, xml)
    end
  end

  defp handle_report(conn), do: with_body(conn, &report/2)

  defp report(conn, body) do
    case XMLParser.parse_report(body) do
      {:ok, {:multiget, request}} -> handle_multiget_report(conn, request)
      {:ok, {:sync_collection, request}} -> handle_sync_collection_report(conn, request)
      {:ok, {:query, request}} -> handle_addressbook_query_report(conn, request)
      {:ok, _} -> send_precondition_failed(conn, "<d:supported-report/>")
      {:error, _} -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_member_report(conn, name) do
    case find_contact_by_name(conn, name) do
      nil ->
        send_resp(conn, 404, "Not Found")

      _contact ->
        with_body(conn, &member_report/2)
    end
  end

  defp member_report(conn, body) do
    case XMLParser.parse_report(body) do
      {:ok, {:multiget, request}} -> handle_multiget_report(conn, request)
      {:ok, _other} -> send_precondition_failed(conn, "<d:supported-report/>")
      {:error, _} -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp unsupported_report(conn, body) do
    case XMLParser.parse_report(body) do
      {:ok, _report} -> send_precondition_failed(conn, "<d:supported-report/>")
      {:error, _} -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp send_precondition_failed(conn, condition) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(403, XMLBuilder.error_body(condition, "Precondition failed"))
  end

  defp with_limit(conn, request, handler) do
    case Integer.parse(request.limit) do
      {limit, ""} when limit > 0 -> handler.(conn, %{request | limit: limit})
      _ -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_multiget_report(conn, request) do
    Store.ensure_rows(account_id(conn))
    names = Enum.map(request.hrefs, &resource_name/1)

    contacts =
      Store.get_by_resource_names(account_id(conn), Enum.reject(names, &is_nil/1))
      |> Map.values()
      |> Repo.preload(Contacts.dav_preloads())
      |> Map.new(&{&1.dav.resource_name, &1})

    responses =
      Enum.zip(request.hrefs, names)
      |> Enum.map(fn {href, name} ->
        multiget_response(Map.get(contacts, name), href, request)
      end)

    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp handle_sync_collection_report(conn, %{limit: limit} = request) when is_binary(limit),
    do: with_limit(conn, request, &handle_sync_collection_report/2)

  defp handle_sync_collection_report(conn, request) do
    Store.ensure_rows(account_id(conn))
    state = Store.sync_state(account_id(conn))

    case parse_sync_token(request.token) do
      :invalid ->
        send_precondition_failed(conn, "<d:valid-sync-token/>")

      since when is_integer(since) and (since < state.floor or since > state.token) ->
        send_precondition_failed(conn, "<d:valid-sync-token/>")

      since ->
        send_sync_changes(conn, request, state, since)
    end
  end

  defp send_sync_changes(conn, request, state, since) do
    contacts = Store.list_changed_since(account_id(conn), since || 0)
    contacts = if is_nil(since), do: Enum.filter(contacts, &visible?/1), else: contacts

    if request.limit && length(contacts) > request.limit do
      send_dav_response(
        conn,
        507,
        XMLBuilder.error_body("<d:number-of-matches-within-limits/>", "Too many changes")
      )
    else
      responses = Enum.map(contacts, &member_report_response(&1, request))

      send_dav_response(
        conn,
        207,
        XMLBuilder.multistatus(responses, sync_token: "https://kith.app/ns/sync/#{state.token}")
      )
    end
  end

  defp multiget_response(nil, href, _request), do: XMLBuilder.response_deleted(href)
  defp multiget_response(contact, _href, request), do: member_report_response(contact, request)

  defp member_report_response(contact, request) do
    if visible?(contact),
      do: report_contact_response(contact, request),
      else: XMLBuilder.response_deleted(Store.href(contact))
  end

  defp report_contact_response(contact, request, prepared_card \\ nil) do
    props = [
      getetag: XMLBuilder.getetag(compute_etag(contact)),
      getcontenttype: XMLBuilder.getcontenttype("text/vcard; charset=utf-8"),
      getlastmodified: XMLBuilder.getlastmodified(contact.updated_at)
    ]

    props =
      if request.props == :allprop or
           (is_tuple(request.props) and :address_data in elem(request.props, 1)) do
        props ++
          [
            address_data:
              XMLBuilder.address_data(
                prepared_card ||
                  VCardAdapter.contact_to_vcard(contact,
                    version: request.version,
                    preloaded: true
                  )
              )
          ]
      else
        props
      end

    props =
      if request.props == :propname,
        do: props ++ [address_data: empty_prop(:address_data)],
        else: props

    XMLBuilder.response(Store.href(contact), build_propstats(request.props, props))
  end

  defp handle_addressbook_query_report(conn, %{limit: limit} = request) when is_binary(limit),
    do: with_limit(conn, request, &handle_addressbook_query_report/2)

  defp handle_addressbook_query_report(conn, request) do
    Store.ensure_rows(account_id(conn))

    case AddressQuery.validate(request.filter) do
      {:error, condition} ->
        name =
          if condition == :supported_collation,
            do: "supported-collation",
            else: "supported-filter"

        send_precondition_failed(conn, "<card:#{name}/>")

      :ok ->
        include_photo = Enum.any?(request.filter.prop_filters, &(&1.name == "PHOTO"))

        matching =
          list_contacts_for_dav(conn)
          |> Enum.flat_map(&query_match(&1, request, include_photo))

        responses =
          matching
          |> Enum.take(request.limit || length(matching))
          |> Enum.map(fn {contact, card} -> report_contact_response(contact, request, card) end)

        responses =
          if request.limit && length(matching) > request.limit do
            responses ++
              [
                "<d:response><d:href>/dav/addressbooks/default/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status><d:error><d:number-of-matches-within-limits/></d:error></d:response>"
              ]
          else
            responses
          end

        send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
    end
  end

  defp query_match(contact, request, include_photo) do
    card =
      VCardAdapter.contact_to_vcard(contact,
        version: request.version,
        preloaded: true,
        include_photo: include_photo
      )

    if AddressQuery.matches?(card, request.filter),
      do: [{contact, if(include_photo, do: card)}],
      else: []
  end

  defp none_match?(header, etag) do
    header == "*" or
      Enum.any?(
        String.split(header, ~r/\s*,\s*/),
        &(String.replace_prefix(&1, "W/", "") == "\"#{etag}\"")
      )
  end

  defp handle_get_contact(conn, uid) do
    version = requested_vcard_version(conn)

    case find_contact_by_name(conn, uid) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        vcard = VCardAdapter.contact_to_vcard(contact, version: version, preloaded: true)
        etag = compute_etag(contact)
        content_type = vcard_content_type(version)

        conn =
          conn
          |> put_resp_content_type(content_type, "utf-8")
          |> put_resp_header("etag", "\"#{etag}\"")

        if Enum.any?(get_req_header(conn, "if-none-match"), &none_match?(&1, etag)),
          do: send_resp(conn, 304, ""),
          else: send_resp(conn, 200, vcard)
    end
  end

  defp handle_put_contact(conn, raw) do
    media_type =
      get_req_header(conn, "content-type")
      |> List.first("")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    cond do
      not AddressObject.valid_name?(raw) ->
        send_resp(conn, 400, "Bad Request")

      media_type not in ["text/vcard", "text/x-vcard"] ->
        send_resp(conn, 415, "Unsupported Media Type")

      true ->
        with_body(conn, &AddressObject.put(&1, raw, &2))
    end
  end

  defp handle_delete_contact(conn, raw), do: AddressObject.delete(conn, raw)

  defp handle_proppatch(conn),
    do: authorize(conn, :update, fn -> with_body(conn, &proppatch/2) end)

  defp proppatch(conn, body) do
    case XMLParser.parse_proppatch(body) do
      {:ok, props} ->
        # All properties are live (server-managed) — cannot be modified (RFC 4918 §9.2)
        xml =
          XMLBuilder.multistatus([
            XMLBuilder.response("/dav/addressbooks/default/", [
              XMLBuilder.propstat(Enum.map(props, &empty_prop/1), "HTTP/1.1 403 Forbidden")
            ])
          ])

        send_dav_response(conn, 207, xml)

      _ ->
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp find_contact_by_name(conn, raw) do
    Store.ensure_rows(account_id(conn))

    case Store.get_by_resource_name(account_id(conn), URI.decode(raw)) do
      nil ->
        nil

      contact ->
        if visible?(contact), do: Repo.preload(contact, Contacts.dav_preloads()), else: nil
    end
  end

  defp visible?(contact), do: is_nil(contact.deleted_at) and not contact.is_archived

  defp resource_name(href) do
    path = URI.parse(href).path || ""

    case String.split(path, "/", trim: true) do
      ["dav", "addressbooks", "default", name] -> URI.decode(name)
      _ -> nil
    end
  end

  defp list_contacts_for_dav(conn) do
    Store.ensure_rows(account_id(conn))
    Contacts.list_contacts(account_id(conn), preload: Contacts.dav_preloads())
  end

  defp list_contacts_for_propfind(conn) do
    Store.ensure_rows(account_id(conn))
    import Ecto.Query

    Contact
    |> Kith.Scope.scope_active(account_id(conn))
    |> where([c], c.is_archived == false)
    |> preload(:dav)
    |> Repo.all()
  end

  defp compute_etag(%{dav: %{revision: revision}}), do: to_string(revision)

  defp parse_sync_token(nil), do: nil
  defp parse_sync_token(""), do: nil

  defp parse_sync_token(token) do
    case Regex.run(~r/\Ahttps:\/\/kith\.app\/ns\/sync\/(\d+)\z/, token) do
      [_, revision] -> String.to_integer(revision)
      _ -> :invalid
    end
  end

  defp addressbook_response(conn, request_type) do
    Store.ensure_rows(account_id(conn))
    state = Store.sync_state(account_id(conn))
    ctag = to_string(state.token)

    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/><card:addressbook/>"),
      displayname: XMLBuilder.displayname("Kith Contacts"),
      getctag: XMLBuilder.getctag(ctag),
      sync_token: XMLBuilder.sync_token("https://kith.app/ns/sync/" <> ctag),
      supported_address_data: XMLBuilder.supported_address_data(),
      max_resource_size: XMLBuilder.max_resource_size(1_048_576),
      supported_collation_set: XMLBuilder.supported_collation_set(),
      owner: XMLBuilder.owner("/dav/principals/"),
      current_user_privilege_set: XMLBuilder.current_user_privilege_set(),
      supported_report_set: supported_report_set()
    ]

    XMLBuilder.response("/dav/addressbooks/default/", build_propstats(request_type, props))
  end

  defp supported_report_set do
    "<d:supported-report-set>" <>
      "<d:supported-report><d:report><card:addressbook-multiget/></d:report></d:supported-report>" <>
      "<d:supported-report><d:report><card:addressbook-query/></d:report></d:supported-report>" <>
      "<d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report>" <>
      "</d:supported-report-set>"
  end

  # Builds propstat elements based on the PROPFIND request type.
  # `available_props` is a keyword list of `[{atom_key, xml_string}]`.
  # Returns a list of propstat XML strings.
  defp build_propstats(request_type, available_props) do
    case request_type do
      :allprop ->
        [XMLBuilder.propstat(Keyword.values(available_props))]

      :propname ->
        elements =
          available_props
          |> Keyword.keys()
          |> Enum.map(&empty_prop/1)

        [XMLBuilder.propstat(elements)]

      {:prop, requested} ->
        requested_set = MapSet.new(requested)
        available_keys = available_props |> Keyword.keys() |> MapSet.new()

        found =
          available_props
          |> Enum.filter(fn {k, _v} -> MapSet.member?(requested_set, k) end)
          |> Keyword.values()

        missing =
          MapSet.difference(requested_set, available_keys)
          |> MapSet.to_list()
          |> Enum.map(&empty_prop/1)

        propstats = []
        propstats = if found != [], do: [XMLBuilder.propstat(found) | propstats], else: propstats

        propstats =
          if missing != [],
            do: [XMLBuilder.propstat(missing, "HTTP/1.1 404 Not Found") | propstats],
            else: propstats

        Enum.reverse(propstats)
    end
  end

  # Empty element naming a prop: known atoms use their canonical prefix,
  # unknown `{namespace, name}` props keep their own namespace (RFC 4918 §9.1).
  defp empty_prop({ns, name}), do: XMLBuilder.empty_element(ns, name)
  defp empty_prop(key), do: Map.fetch!(@prop_empty_elements, key)

  defp requested_vcard_version(conn) do
    accept = get_req_header(conn, "accept") |> List.first("")
    if String.contains?(accept, "version=4.0"), do: :v40, else: :v30
  end

  defp vcard_content_type(:v40), do: "text/vcard; version=4.0"
  defp vcard_content_type(_), do: "text/vcard"

  defp send_dav_response(conn, status, xml) do
    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("dav", "1, 2, 3, addressbook")
    |> send_resp(status, xml)
  end
end
