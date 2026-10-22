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
  alias Kith.DAV.{AddressQuery, Auth, VCardAdapter, XMLBuilder, XMLParser}

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
    addressbook_home_set: "<card:addressbook-home-set/>",
    supported_address_data: "<card:supported-address-data/>",
    supported_report_set: "<d:supported-report-set/>",
    getctag: "<cs:getctag/>",
    sync_token: "<d:sync-token/>",
    principal_url: "<d:principal-URL/>",
    owner: "<d:owner/>",
    current_user_privilege_set: "<d:current-user-privilege-set/>",
    max_resource_size: "<card:max-resource-size/>",
    supported_collation_set: "<card:supported-collation-set/>",
    address_data: "<card:address-data/>"
  }

  # RFC 6352 §6.2.1, advertised on the address book
  @max_resource_size 1_048_576

  # How much of an oversized body is read and discarded before answering 413
  @drain_limit 16 * 1_048_576

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = Auth.require_auth(conn)
    if conn.halted, do: conn, else: route(conn)
  end

  # ── Routing ────────────────────────────────────────────────────────────

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

  # RFC 6352 §8.7: addressbook-multiget may target an address object (CDV-55)
  defp dispatch(conn, "REPORT", ["dav", "addressbooks", "default", raw]),
    do: with_resource_name(conn, raw, &handle_member_report/2)

  # Existing resources that support no report: 403 supported-report (CDV-55)
  defp dispatch(conn, "REPORT", segments)
       when segments in [["dav"], ["dav", "principals"], ["dav", "addressbooks"]],
       do: with_body(conn, &unsupported_report/2)

  defp dispatch(conn, "GET", ["dav", "addressbooks", "default", raw]),
    do: with_resource_name(conn, raw, &handle_get_contact/2)

  defp dispatch(conn, "PUT", ["dav", "addressbooks", "default", raw]),
    do: with_resource_name(conn, raw, &handle_put_contact/2)

  defp dispatch(conn, "DELETE", ["dav", "addressbooks", "default", raw]),
    do: with_resource_name(conn, raw, &handle_delete_contact/2)

  # RFC 4918 §8.2: PROPPATCH stub — live properties cannot be modified
  defp dispatch(conn, "PROPPATCH", ["dav", "addressbooks", "default"]),
    do: handle_proppatch(conn)

  # RFC 9110 §15.5.6: a collection exists but cannot be deleted or replaced
  # over DAV, so DELETE / PUT there is a 405 with Allow, not a 404 (CDV-22).
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

  # Hands the percent-decoded resource name (the last path segment) to `fun`.
  # A name that cannot be a member of the book is a 400 (CDV-13).
  defp with_resource_name(conn, raw, fun) do
    case decode_resource_name(raw) do
      {:ok, name} -> fun.(conn, name)
      :error -> send_resp(conn, 400, "Bad Request")
    end
  end

  # R6: writes go through Kith.Policy, so a viewer is read-only over DAV.
  defp authorize(conn, action, fun) do
    if Kith.Policy.can?(conn.assigns.current_scope.user, action, :contact),
      do: fun.(),
      else: send_resp(conn, 403, "Forbidden")
  end

  # ── OPTIONS ────────────────────────────────────────────────────────────

  defp handle_options(conn) do
    conn
    |> put_resp_header("dav", "1, 2, 3, addressbook")
    |> put_resp_header("allow", "OPTIONS, GET, PUT, DELETE, PROPFIND, PROPPATCH, REPORT")
    |> send_resp(200, "")
  end

  # ── PROPFIND body ──────────────────────────────────────────────────────

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
  # anything larger is a 413 (R8), never a MatchError.
  # Bandit ignores `:length` for a chunked body and returns it whole, so the
  # size of what was read is checked too (CDV-23).
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

  # ── Root PROPFIND ──────────────────────────────────────────────────────

  defp handle_root_propfind(conn, request_type) do
    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/>")
    ]

    propstats = build_propstats(request_type, props)
    xml = XMLBuilder.multistatus([XMLBuilder.response("/dav/", propstats)])
    send_dav_response(conn, 207, xml)
  end

  # ── Principal PROPFIND ─────────────────────────────────────────────────

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

  # ── Home set PROPFIND ──────────────────────────────────────────────────

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

  # ── Address book PROPFIND ──────────────────────────────────────────────

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
    contacts = list_contacts_for_propfind(conn)
    responses = [addressbook_response(conn, request_type)]

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
      getetag: XMLBuilder.getetag(etag),
      getcontenttype: XMLBuilder.getcontenttype("text/vcard; charset=utf-8"),
      getlastmodified: XMLBuilder.getlastmodified(contact.updated_at)
    ]

    XMLBuilder.response(contact_href(contact), build_propstats(request_type, props))
  end

  # ── Contact PROPFIND ───────────────────────────────────────────────────

  defp handle_contact_propfind(conn, request_type) do
    raw = List.last(path_segments(conn.request_path))

    case decode_resource_name(raw) |> found_contact(conn) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        etag = compute_etag(contact)

        props = [
          current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
          getetag: XMLBuilder.getetag(etag),
          getcontenttype: XMLBuilder.getcontenttype("text/vcard; charset=utf-8"),
          getlastmodified: XMLBuilder.getlastmodified(contact.updated_at)
        ]

        propstats = build_propstats(request_type, props)
        xml = XMLBuilder.multistatus([XMLBuilder.response(conn.request_path, propstats)])
        send_dav_response(conn, 207, xml)
    end
  end

  # ── REPORT ─────────────────────────────────────────────────────────────

  # The body goes through the same capped reader as PUT/PROPFIND (R8, CDV-39).
  defp handle_report(conn), do: with_body(conn, &report/2)

  # The report is identified by its namespaced root element, not by a
  # substring of the body (CDV-40). RFC 3253 §3.6: an unknown report is a 403
  # with the DAV:supported-report precondition; malformed XML is a 400.
  defp report(conn, body) do
    case XMLParser.parse_report(body) do
      {:ok, {:multiget, request}} -> handle_multiget_report(conn, request)
      {:ok, {:sync_collection, request}} -> handle_sync_collection_report(conn, request)
      {:ok, {:query, request}} -> handle_addressbook_query_report(conn, request)
      {:ok, {:unsupported, _root}} -> send_precondition_failed(conn, "<d:supported-report/>")
      {:error, _} -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_member_report(conn, name) do
    case find_contact(conn, name) do
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

  defp handle_multiget_report(conn, %{hrefs: hrefs} = request) do
    contacts = multiget_contacts(conn, hrefs)

    responses =
      Enum.map(hrefs, fn href ->
        multiget_response(Map.get(contacts, multiget_name(href)), href, request)
      end)

    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp multiget_response(contact, href, %{props: props, version: version}) do
    case contact do
      # RFC 6352 §8.7: a missing member is a bare 404 status (CDV-42)
      nil ->
        XMLBuilder.status_response(href, "HTTP/1.1 404 Not Found")

      contact ->
        report_member_response(contact, props, version, fn ->
          VCardAdapter.contact_to_vcard(contact, version: version)
        end)
    end
  end

  # A multiget href (absolute URL or path, any equivalent percent-encoding)
  # names a member only if its path is in this address book; the response then
  # carries the member's own href, so every spelling gives one result (CDV-41).
  defp multiget_name(href) do
    with %URI{path: path} when is_binary(path) <- URI.parse(href),
         ["dav", "addressbooks", "default", raw] <- path_segments(path),
         {:ok, name} <- decode_resource_name(raw) do
      name
    else
      _ -> nil
    end
  end

  # Resolves every href with one query per kind and one preload pass, however
  # many hrefs there are (a per-href lookup was an N+1, CDV-106). Returns
  # `%{resource name => contact}`; names that resolve to nothing are absent.
  defp multiget_contacts(conn, hrefs) do
    aid = account_id(conn)
    names = hrefs |> Enum.map(&multiget_name/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    by_name = Contacts.get_contacts_by_dav_names(aid, names)

    default_ids =
      for name <- names, not is_map_key(by_name, name), id = default_name_id(name), do: id

    by_id = Contacts.get_active_contacts_by_ids(aid, default_ids)

    resolved =
      for name <- names,
          contact = multiget_resolve(name, by_name, by_id),
          do: {name, contact}

    {names, contacts} = Enum.unzip(resolved)
    names |> Enum.zip(Contacts.preload_for_dav(contacts)) |> Map.new()
  end

  # Same precedence as `find_contact/2`: a stored name wins, even if the
  # contact is archived (then it is hidden, R5); otherwise the default name.
  defp multiget_resolve(name, by_name, by_id) do
    case Map.fetch(by_name, name) do
      {:ok, %Contact{is_archived: false} = contact} ->
        contact

      {:ok, _archived} ->
        nil

      :error ->
        case Map.get(by_id, default_name_id(name)) do
          %Contact{dav_resource_name: nil, is_archived: false} = contact -> contact
          _ -> nil
        end
    end
  end

  defp handle_sync_collection_report(conn, %{token: client_token} = request) do
    # Read before the contacts are, so the new token covers no write this
    # response misses (CDV-46).
    state = conn |> account_id() |> Contacts.dav_sync_state()

    case parse_sync_token(client_token, state) do
      :invalid ->
        # R3 / RFC 6578 §3.2: never fall back to a full sync silently (CDV-47)
        send_precondition_failed(conn, "<d:valid-sync-token/>")

      since ->
        send_sync_responses(conn, since, request, state)
    end
  end

  defp send_sync_responses(conn, since, %{props: props, version: version} = request, state) do
    with {:ok, limit} <- parse_limit(request.limit),
         responses = sync_responses(conn, since, props, version),
         true <- limit == nil or length(responses) <= limit do
      xml = XMLBuilder.multistatus(responses, sync_token: sync_token(state))
      send_dav_response(conn, 207, xml)
    else
      {:error, :bad_limit} ->
        send_resp(conn, 400, "Bad Request")

      false ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(
          507,
          XMLBuilder.error_body("<d:number-of-matches-within-limits/>", "Too many changes")
        )
    end
  end

  defp sync_responses(conn, since, props, version) do
    case since do
      :initial ->
        # Initial sync: every member, no removals
        conn
        |> list_contacts_for_dav()
        |> Enum.map(&sync_contact_response(&1, props, version))

      since ->
        # Incremental: every contact written since the token; a trashed or
        # archived one is a removal (R5), shown as a bare 404 (RFC 6578 §3.5)
        conn
        |> account_id()
        |> Contacts.list_contacts_changed_since(since)
        |> Enum.map(fn
          %Contact{deleted_at: nil, is_archived: false} = contact ->
            sync_contact_response(contact, props, version)

          contact ->
            XMLBuilder.response_deleted(contact_href(contact))
        end)
    end
  end

  defp sync_contact_response(contact, props, version) do
    report_member_response(contact, props, version, fn ->
      VCardAdapter.contact_to_vcard(contact, version: version, include_photo: false)
    end)
  end

  # A member's response in any REPORT, holding only the properties the client
  # asked for (unknown ones in a 404 propstat). The vCard is built only when
  # address-data is wanted (CDV-44).
  defp report_member_response(contact, props, version, vcard_fun) do
    address_data =
      if props == :allprop or (match?({:prop, _}, props) and :address_data in elem(props, 1)),
        do: XMLBuilder.address_data(vcard_fun.())

    available = [
      getetag: XMLBuilder.getetag(compute_etag(contact)),
      getcontenttype: XMLBuilder.getcontenttype(vcard_content_type(version) <> "; charset=utf-8"),
      getlastmodified: XMLBuilder.getlastmodified(contact.updated_at),
      address_data: address_data
    ]

    XMLBuilder.response(contact_href(contact), build_propstats(props, available))
  end

  # ── addressbook-query REPORT (RFC 6352 §8.6) ──────────────────────────

  # RFC 6352 §8.6: the filter is evaluated on the vCard each member is served
  # as; an unsupported filter or collation is a 403 precondition rather than a
  # silent match-all, and CARDDAV:limit truncates with a 507 for the
  # collection (§8.6.1) (CDV-43).
  defp handle_addressbook_query_report(conn, %{filter: filter, limit: limit} = request) do
    %{props: props, version: version} = request

    with :ok <- AddressQuery.validate(filter),
         {:ok, limit} <- parse_limit(limit) do
      matching =
        conn
        |> list_contacts_for_dav()
        |> Stream.map(
          &{&1, VCardAdapter.contact_to_vcard(&1, version: version, include_photo: false)}
        )
        |> Stream.filter(fn {_contact, vcard} -> AddressQuery.matches?(vcard, filter) end)
        |> then(&if(limit, do: Enum.take(&1, limit + 1), else: Enum.to_list(&1)))

      {matching, truncated?} =
        if limit && length(matching) > limit,
          do: {Enum.take(matching, limit), true},
          else: {matching, false}

      responses = Enum.map(matching, &query_member_response(&1, props, version))

      responses =
        if truncated?,
          do: responses ++ [XMLBuilder.truncated_response("/dav/addressbooks/default/")],
          else: responses

      send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
    else
      {:error, :supported_collation} ->
        send_precondition_failed(conn, "<card:supported-collation/>")

      {:error, :supported_filter} ->
        send_precondition_failed(conn, "<card:supported-filter/>")

      {:error, :bad_limit} ->
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp query_member_response({contact, vcard}, props, version),
    do: report_member_response(contact, props, version, fn -> vcard end)

  defp parse_limit(nil), do: {:ok, nil}

  defp parse_limit(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :bad_limit}
    end
  end

  # ── GET ────────────────────────────────────────────────────────────────

  defp handle_get_contact(conn, name) do
    version = requested_vcard_version(conn)

    case find_contact(conn, name) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        etag = compute_etag(contact)
        conn = conn |> put_resp_header("etag", "\"#{etag}\"") |> put_resp_header("vary", "accept")

        # RFC 7232 §3.2 / §4.1: a matching If-None-Match on GET is a 304
        if none_match_fails?(conn, etag) do
          send_resp(conn, 304, "")
        else
          vcard = VCardAdapter.contact_to_vcard(contact, version: version)

          conn
          |> put_resp_content_type(vcard_content_type(version), "utf-8")
          |> send_resp(200, vcard)
        end
    end
  end

  # ── PUT ────────────────────────────────────────────────────────────────

  defp handle_put_contact(conn, name) do
    # RFC 6352 §5.1: Content-Type MUST be text/vcard; the pre-RFC 6350
    # text/x-vcard that older clients send is accepted too (CDV-19).
    media_type =
      get_req_header(conn, "content-type")
      |> List.first("")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type in ["text/vcard", "text/x-vcard"] do
      # R8: a vCard over max-resource-size is a 413, never a 500 (CDV-20)
      with_body(conn, &do_put_contact(&1, name, &2))
    else
      send_resp(conn, 415, "Unsupported Media Type")
    end
  end

  defp do_put_contact(conn, name, body) do
    aid = account_id(conn)
    existing = find_contact(conn, name)

    authorize(conn, if(existing, do: :update, else: :create), fn ->
      parsed =
        VCardAdapter.vcard_to_attrs(body, strip_nils: false, account_id: aid)

      case parsed do
        {scalar_attrs, nested_data} ->
          put_contact(conn, {aid, name}, scalar_attrs, nested_data)

        _ ->
          send_invalid_vcard(conn)
      end
    end)
  end

  # RFC 6352 §6.3.2.1: a vCard the server cannot store fails the
  # CARDDAV:valid-address-data precondition
  defp send_invalid_vcard(conn) do
    xml = XMLBuilder.precondition_error("valid-address-data", "Invalid vCard format")
    send_dav_response(conn, 422, xml)
  end

  # RFC 6352 §6.3.2.1 (CARDDAV:no-uid-conflict): a new resource may not reuse
  # the UID of another visible contact — its stored UID, or the default
  # `kith-contact-<id>` UID of a contact without one (CDV-28).
  defp check_uid_conflict(_aid, nil), do: :ok

  defp check_uid_conflict(aid, uid) do
    case Contacts.get_contact_by_dav_uid(aid, uid) || default_uid_contact(aid, uid) do
      nil -> :ok
      holder -> {:error, {:uid_conflict, holder}}
    end
  end

  defp default_uid_contact(aid, uid) do
    with [_, id] <- Regex.run(~r/\A(?:urn:uuid:)?kith-contact-([1-9]\d{0,17})\z/, uid),
         %Contact{dav_uid: nil, is_archived: false} = contact <-
           Contacts.get_contact(aid, String.to_integer(id)) do
      contact
    else
      _ -> nil
    end
  end

  # One PUT is one transaction (CDV-21). The target row is read FOR UPDATE and
  # the preconditions are evaluated on that locked row, so two writers holding
  # the same ETag cannot both win and their child sets cannot mix (CDV-24).
  defp put_contact(conn, target, scalar_attrs, nested_data, retry? \\ true) do
    case put_transaction(conn, target, scalar_attrs, nested_data) do
      {:ok, {status, contact}} ->
        send_put_response(conn, status, contact)

      {:error, :precondition_failed} ->
        send_resp(conn, 412, "Precondition Failed")

      {:error, :transient_conflict} ->
        conn |> put_resp_header("retry-after", "1") |> send_resp(503, "Service Unavailable")

      # A concurrent writer took the UID first: the visible-UID unique index
      # stands in for the check (CDV-36)
      {:error, %Ecto.Changeset{errors: [{:dav_uid, _} | _]} = changeset} ->
        uid = Ecto.Changeset.get_field(changeset, :dav_uid)
        holder = Contacts.get_contact_by_dav_uid(elem(target, 0), uid)
        send_uid_conflict(conn, holder)

      {:error, {:uid_conflict, holder}} ->
        send_uid_conflict(conn, holder)

      # A concurrent PUT created the same name first (unique index): run the
      # PUT again, now against that contact, as an update (CDV-25).
      {:error, %Ecto.Changeset{errors: [{:dav_resource_name, _} | _]}} when retry? ->
        put_contact(conn, target, scalar_attrs, nested_data, false)

      {:error, _} ->
        send_invalid_vcard(conn)
    end
  end

  # RFC 6352 §6.3.2.1: names the resource already holding the UID, if visible
  defp send_uid_conflict(conn, holder) do
    href = if holder, do: "<d:href>#{contact_href(holder)}</d:href>", else: ""

    xml =
      XMLBuilder.error_body(
        "<card:no-uid-conflict>#{href}</card:no-uid-conflict>",
        "This UID is already used by another address object"
      )

    send_dav_response(conn, 409, xml)
  end

  # A PUT can deadlock with a concurrent writer of a related contact: renaming
  # A locks A, then touches the contacts owning a relationship to A (CDV-100),
  # while the other writer holds one of those and wants A. Postgres aborts one
  # side; the aborted PUT is replayed once, then answered 503 (CDV-101, R51).
  @transient_codes [:deadlock_detected, :serialization_failure]

  defp put_transaction(conn, target, scalar_attrs, nested_data, attempts \\ 2) do
    run_put_transaction(conn, target, scalar_attrs, nested_data)
  rescue
    e in Postgrex.Error ->
      cond do
        e.postgres[:code] not in @transient_codes -> reraise e, __STACKTRACE__
        attempts > 1 -> put_transaction(conn, target, scalar_attrs, nested_data, attempts - 1)
        true -> {:error, :transient_conflict}
      end
  end

  defp run_put_transaction(conn, {aid, name}, scalar_attrs, nested_data) do
    Kith.Repo.transaction(fn ->
      target = lock_put_target(conn, name)

      case write_put_target(conn, aid, target, {scalar_attrs, nested_data}) do
        {:ok, status, contact} -> {status, contact}
        {:error, reason} -> Kith.Repo.rollback(reason)
      end
    end)
  end

  # `{:visible, contact}`, `{:hidden, contact}` (trashed or archived) or
  # `{:missing, name}`; a found contact is re-read under a row lock.
  defp lock_put_target(conn, name) do
    case find_unarchived_or_archived(conn, name) || find_trashed_contact(conn, name) do
      nil -> {:missing, name}
      contact -> contact |> Contacts.lock_contact() |> put_target(name)
    end
  end

  defp put_target(nil, name), do: {:missing, name}

  defp put_target(%Contact{deleted_at: nil, is_archived: false} = contact, _name),
    do: {:visible, contact}

  defp put_target(%Contact{} = contact, _name), do: {:hidden, contact}

  defp write_put_target(conn, aid, {:visible, contact}, {scalar_attrs, nested_data}) do
    # RFC 7232 §3.1 / §3.2 on the locked, current representation
    if none_match_fails?(conn, compute_etag(contact)) or
         check_if_match(conn, contact) == :precondition_failed do
      {:error, :precondition_failed}
    else
      with {:ok, contact} <- overwrite_contact(contact, aid, scalar_attrs, nested_data),
           do: {:ok, 204, contact}
    end
  end

  defp write_put_target(conn, aid, target, data) do
    # RFC 7232 §3.1: any If-Match (even `*`) fails when the resource is missing
    if get_req_header(conn, "if-match") == [],
      do: create_contact(aid, target, data),
      else: {:error, :precondition_failed}
  end

  # R18 / R21: a PUT to the href of a trashed or archived contact brings that
  # contact back and overwrites it, instead of creating a duplicate beside it
  # (CDV-18, CDV-27).
  defp create_contact(aid, {:hidden, hidden}, {scalar_attrs, nested_data}) do
    # The contact rejoins the collection: neither the card's UID nor the one it
    # already carries may be held by a visible contact (CDV-35)
    with :ok <- check_uid_conflict(aid, nested_data.uid),
         :ok <- check_uid_conflict(aid, hidden.dav_uid),
         {:ok, shown} <- unhide(hidden),
         {:ok, contact} <- overwrite_contact(shown, aid, scalar_attrs, nested_data),
         do: {:ok, 201, contact}
  end

  defp create_contact(aid, {:missing, name}, {scalar_attrs, nested_data}) do
    identity = %{dav_resource_name: name, dav_uid: nested_data.uid}

    with :ok <- check_uid_conflict(aid, nested_data.uid),
         {:ok, contact} <- Contacts.create_contact(aid, scalar_attrs),
         {:ok, contact} <- Contacts.put_dav_identity(contact, identity),
         {:ok, _} <- Contacts.replace_contact_children(contact, aid, nested_data),
         do: {:ok, 201, Contacts.touch_contact!(contact)}
  end

  defp unhide(contact) do
    restored =
      if contact.deleted_at, do: Contacts.restore_contact(contact), else: {:ok, contact}

    with {:ok, contact} <- restored do
      if contact.is_archived, do: Contacts.unarchive_contact(contact), else: {:ok, contact}
    end
  end

  # PUT replaces the whole representation: scalars, then children, then a touch
  defp overwrite_contact(contact, aid, scalar_attrs, nested_data) do
    with {:ok, updated} <- Contacts.update_contact(contact, scalar_attrs),
         {:ok, _} <- Contacts.replace_contact_children(updated, aid, nested_data),
         do: {:ok, Contacts.touch_contact!(updated)}
  end

  # RFC 6352 §6.3.2.3: this server reserializes PUT bodies; clients must GET
  # the stored representation before using its strong validator.
  defp send_put_response(conn, status, _contact), do: send_resp(conn, status, "")

  # ── DELETE ─────────────────────────────────────────────────────────────

  defp handle_delete_contact(conn, name) do
    case find_contact(conn, name) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        authorize(conn, :delete, fn -> delete_contact(conn, contact) end)
    end
  end

  # RFC 7232 §3.1: If-Match is evaluated on the row read under its lock, in the
  # transaction that trashes it, so a concurrent PUT cannot be trashed with a
  # stale ETag; a failed write is not answered 204 (CDV-118, as CDV-24 for PUT).
  defp delete_contact(conn, contact) do
    result =
      Kith.Repo.transaction(fn ->
        with %Contact{deleted_at: nil, is_archived: false} = locked <-
               Contacts.lock_contact(contact),
             :ok <- check_if_match(conn, locked),
             {:ok, _} <- Contacts.soft_delete_contact(locked) do
          :deleted
        else
          :precondition_failed -> Kith.Repo.rollback(:precondition_failed)
          {:error, reason} -> Kith.Repo.rollback(reason)
          _gone_or_hidden -> Kith.Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, :deleted} -> send_resp(conn, 204, "")
      {:error, :precondition_failed} -> send_resp(conn, 412, "Precondition Failed")
      {:error, :not_found} -> send_resp(conn, 404, "Not Found")
      {:error, _changeset} -> send_resp(conn, 500, "Internal Server Error")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # ── PROPPATCH stub (RFC 4918 §8.2) ────────────────────────────────────

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

  # RFC 7232 §3.1: If-Match is `*` or a list of entity tags, compared strongly:
  # a weak `W/` tag never matches (CDV-14).
  defp check_if_match(conn, contact) do
    case get_req_header(conn, "if-match") do
      [] ->
        :ok

      values ->
        header = Enum.join(values, ",")
        strong = [{false, compute_etag(contact)}]

        if String.trim(header) == "*" or Enum.any?(entity_tags(header), &(&1 in strong)),
          do: :ok,
          else: :precondition_failed
    end
  end

  # RFC 7232 §3.2: If-None-Match is `*` or a list of entity tags, compared
  # weakly. True when the condition is false, i.e. the current tag is listed.
  defp none_match_fails?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [] ->
        false

      values ->
        header = Enum.join(values, ",")

        String.trim(header) == "*" or
          Enum.any?(entity_tags(header), &(elem(&1, 1) in List.wrap(etag)))
    end
  end

  # RFC 7232 §2.3: `entity-tag = [ W/ ] DQUOTE *etagc DQUOTE`, comma-separated.
  defp entity_tags(header) do
    ~r{(W/)?"([^"]*)"}
    |> Regex.scan(header)
    |> Enum.map(fn [_, weak, tag] -> {weak != "", tag} end)
  end

  # R2: a contact is found by the resource name a client stored for it, else by
  # the default `kith-contact-<id>.vcf` name of a contact that has no stored name.
  # `name` is already percent-decoded. R5: an archived contact is hidden from
  # DAV, so it is not found here (CDV-27).
  defp find_contact(conn, name) do
    case find_unarchived_or_archived(conn, name) do
      %Contact{is_archived: false} = contact -> contact
      _ -> nil
    end
  end

  defp find_unarchived_or_archived(conn, name) do
    Contacts.get_contact_by_dav_name(account_id(conn), name) ||
      find_contact_by_default_name(conn, name)
  end

  defp found_contact({:ok, name}, conn), do: find_contact(conn, name)
  defp found_contact(:error, _conn), do: nil

  defp find_contact_by_default_name(conn, name) do
    default_name_contact(name, &Contacts.get_contact(account_id(conn), &1))
  end

  # The trashed contact `name` would address if it were active (CDV-18).
  defp find_trashed_contact(conn, name) do
    aid = account_id(conn)

    Contacts.get_trashed_contact_by_dav_name(aid, name) ||
      default_name_contact(name, &Contacts.get_trashed_contact(aid, &1))
  end

  # Only the canonical id (no leading zeros) resolves, so a contact has one
  # default href; `kith-contact-05.vcf` is an ordinary client name (CDV-34).
  defp default_name_contact(name, get) do
    with id when is_integer(id) <- default_name_id(name),
         %Contact{dav_resource_name: nil} = contact <- get.(id) do
      contact
    else
      _ -> nil
    end
  end

  defp default_name_id(name) do
    case Regex.run(~r/\Akith-contact-([1-9]\d{0,17})\.vcf\z/, name) do
      [_, id_str] -> String.to_integer(id_str)
      _ -> nil
    end
  end

  # A resource name is one well-escaped path segment that decodes to valid UTF-8
  # of at most 255 bytes, with no slash, backslash or control character, and is
  # not a dot segment (CDV-13).
  defp decode_resource_name(raw) do
    name = if String.match?(raw, ~r/\A(?:[^%]|%[0-9A-Fa-f]{2})*\z/), do: URI.decode(raw)

    if is_binary(name) and String.valid?(name) and byte_size(name) <= 255 and
         name not in [".", ".."] and not String.match?(name, ~r{[/\\\x00-\x1f\x7f]}),
       do: {:ok, name},
       else: :error
  end

  # The one place a contact's href is built: its stored client name (R2), else
  # the default name, percent-encoded as a single path segment.
  defp contact_href(%{dav_resource_name: name}) when is_binary(name),
    do: "/dav/addressbooks/default/" <> URI.encode(name, &URI.char_unreserved?/1)

  defp contact_href(%{id: id}), do: "/dav/addressbooks/default/kith-contact-#{id}.vcf"

  defp list_contacts_for_dav(conn) do
    account_id(conn) |> Contacts.list_contacts() |> Contacts.preload_for_dav()
  end

  defp list_contacts_for_propfind(conn) do
    import Ecto.Query

    Contact
    |> Kith.Scope.scope_active(account_id(conn))
    |> where([c], c.is_archived == false)
    |> select([c], map(c, [:id, :updated_at, :dav_revision, :dav_resource_name]))
    |> Kith.Repo.all()
  end

  # R4: `dav_revision` changes on every write of the contact row (CDV-17).
  # R42: one strong tag for both vCard versions, so ETag-only listings
  # (PROPFIND, sync, multiget) match whatever version a client GETs (CDV-90).
  defp compute_etag(%{id: id, dav_revision: revision}) do
    data = "#{id}-#{revision}"

    :crypto.hash(:md5, data)
    |> Base.encode16(case: :lower)
  end

  @sync_token_prefix "https://kith.app/ns/sync/"

  # R3: a token is `<epoch>-<seq>` (R25, CDV-54), e.g.
  # `https://kith.app/ns/sync/3f9a1c0b7d2e-4711`.
  defp sync_token(%{epoch: epoch, seq: seq}), do: "#{@sync_token_prefix}#{epoch}-#{seq}"

  # `:initial` for no token, the token's `seq` for one this database could
  # have issued to this account, `:invalid` for anything else: another epoch
  # (restore, PITR), a position not reached yet, or one older than a hard
  # delete it cannot express (CDV-47, CDV-48, CDV-52, CDV-54).
  defp parse_sync_token(nil, _state), do: :initial

  defp parse_sync_token(token, %{epoch: epoch, seq: current, floor: floor}) do
    with @sync_token_prefix <> position <- token,
         [_, ^epoch, seq] <- Regex.run(~r/\A([0-9a-f]{12})-(\d{1,18})\z/, position),
         seq = String.to_integer(seq),
         true <- seq >= floor and seq <= current do
      seq
    else
      _ -> :invalid
    end
  end

  defp addressbook_response(conn, request_type) do
    # The ctag is the sync seq: both move with every committed change (CDV-53)
    state = conn |> account_id() |> Contacts.dav_sync_state()
    ctag = to_string(state.seq)

    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/><card:addressbook/>"),
      displayname: XMLBuilder.displayname("Kith Contacts"),
      getctag: XMLBuilder.getctag(ctag),
      # RFC 6578 §4: a collection supporting sync-collection exposes DAV:sync-token
      sync_token: XMLBuilder.sync_token(sync_token(state)),
      supported_address_data: XMLBuilder.supported_address_data(),
      max_resource_size: XMLBuilder.max_resource_size(@max_resource_size),
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

  # ── PROPFIND property filtering (RFC 4918 §9.1) ───────────────────────

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
