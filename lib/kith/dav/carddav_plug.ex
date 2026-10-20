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
  alias Kith.DAV.{Auth, VCardAdapter, XMLBuilder, XMLParser}

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
      {:ok, body, conn} when byte_size(body) <= @max_resource_size -> fun.(conn, body)
      {:ok, _too_big, conn} -> send_resp(conn, 413, "Request Entity Too Large")
      {:more, _partial, conn} -> send_resp(conn, 413, "Request Entity Too Large")
      {:error, _} -> send_resp(conn, 400, "Bad Request")
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
    responses = [addressbook_response(conn, request_type, contacts)]

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

  defp handle_report(conn) do
    {:ok, body, conn} = read_body(conn)

    cond do
      String.contains?(body, "addressbook-multiget") ->
        handle_multiget_report(conn, body)

      String.contains?(body, "sync-collection") ->
        handle_sync_collection_report(conn, body)

      String.contains?(body, "addressbook-query") ->
        handle_addressbook_query_report(conn, body)

      true ->
        send_resp(conn, 400, "Unsupported REPORT type")
    end
  end

  defp handle_multiget_report(conn, body) do
    {:ok, hrefs} = XMLParser.parse_addressbook_multiget(body)
    version = XMLParser.parse_requested_vcard_version(body)

    responses =
      Enum.map(hrefs, fn href ->
        raw = href |> String.trim() |> String.split("/") |> List.last()

        case decode_resource_name(raw) |> found_contact(conn) do
          nil ->
            XMLBuilder.response(href, [
              XMLBuilder.propstat([], "HTTP/1.1 404 Not Found")
            ])

          contact ->
            vcard = VCardAdapter.contact_to_vcard(contact, version: version)
            etag = compute_etag(contact)

            XMLBuilder.response(href, [
              XMLBuilder.propstat([
                XMLBuilder.getetag(etag),
                XMLBuilder.getcontenttype("text/vcard; charset=utf-8"),
                XMLBuilder.address_data(vcard)
              ])
            ])
        end
      end)

    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp handle_sync_collection_report(conn, body) do
    {:ok, client_token} = XMLParser.parse_sync_collection(body)
    version = XMLParser.parse_requested_vcard_version(body)
    aid = account_id(conn)

    {active_responses, deleted_responses} =
      case parse_sync_token(client_token) do
        nil ->
          # Initial sync: return all contacts, no deletions
          contacts = list_contacts_for_dav(conn)
          {Enum.map(contacts, &sync_contact_response(&1, version)), []}

        since ->
          # Incremental sync: only changes since token timestamp
          modified = Contacts.list_contacts_modified_since(aid, since)
          deleted = Contacts.list_contacts_deleted_since(aid, since)

          active = Enum.map(modified, &sync_contact_response(&1, version))

          removed =
            Enum.map(deleted, fn contact ->
              XMLBuilder.response_deleted(contact_href(contact))
            end)

          {active, removed}
      end

    token = generate_sync_token()
    xml = XMLBuilder.multistatus(active_responses ++ deleted_responses, sync_token: token)
    send_dav_response(conn, 207, xml)
  end

  defp sync_contact_response(contact, version) do
    etag = compute_etag(contact)
    vcard = VCardAdapter.contact_to_vcard(contact, version: version, include_photo: false)

    XMLBuilder.response(contact_href(contact), [
      XMLBuilder.propstat([
        XMLBuilder.getetag(etag),
        XMLBuilder.address_data(vcard)
      ])
    ])
  end

  # ── addressbook-query REPORT (RFC 6352 §8.6) ──────────────────────────

  defp handle_addressbook_query_report(conn, body) do
    {:ok, filters} = XMLParser.parse_addressbook_query(body)
    version = XMLParser.parse_requested_vcard_version(body)
    contacts = list_contacts_for_dav(conn)

    matching =
      Enum.filter(contacts, fn contact ->
        Enum.all?(filters, &contact_matches_filter?(contact, &1))
      end)

    responses = Enum.map(matching, &sync_contact_response(&1, version))
    send_dav_response(conn, 207, XMLBuilder.multistatus(responses))
  end

  defp contact_matches_filter?(contact, %{property: prop, match: text, match_type: type}) do
    value = contact_property_value(contact, prop)
    match_text(value, text, type)
  end

  defp contact_property_value(contact, "FN") do
    [contact.first_name, contact.last_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp contact_property_value(contact, "N") do
    [contact.last_name, contact.first_name] |> Enum.reject(&is_nil/1) |> Enum.join(";")
  end

  defp contact_property_value(contact, prop) when prop in ["EMAIL", "TEL"] do
    protocol = if prop == "EMAIL", do: "mailto", else: "tel"

    contact.contact_fields
    |> Enum.filter(fn cf ->
      cf.contact_field_type.protocol &&
        String.starts_with?(cf.contact_field_type.protocol, protocol)
    end)
    |> Enum.map_join("\n", & &1.value)
  end

  defp contact_property_value(_contact, _prop), do: ""

  defp match_text(value, text, "contains"),
    do: String.contains?(String.downcase(value), String.downcase(text))

  defp match_text(value, text, "starts-with"),
    do: String.starts_with?(String.downcase(value), String.downcase(text))

  defp match_text(value, text, "ends-with"),
    do: String.ends_with?(String.downcase(value), String.downcase(text))

  defp match_text(value, text, "equals"), do: String.downcase(value) == String.downcase(text)

  defp match_text(value, text, _),
    do: String.contains?(String.downcase(value), String.downcase(text))

  # ── GET ────────────────────────────────────────────────────────────────

  defp handle_get_contact(conn, name) do
    version = requested_vcard_version(conn)

    case find_contact(conn, name) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        etag = compute_etag(contact)
        conn = put_resp_header(conn, "etag", "\"#{etag}\"")

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
        String.valid?(body) &&
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

      {:error, {:uid_conflict, holder}} ->
        xml =
          XMLBuilder.error_body(
            "<card:no-uid-conflict><d:href>#{contact_href(holder)}</d:href></card:no-uid-conflict>",
            "This UID is already used by another address object"
          )

        send_dav_response(conn, 409, xml)

      # A concurrent PUT created the same name first (unique index): run the
      # PUT again, now against that contact, as an update (CDV-25).
      {:error, %Ecto.Changeset{errors: [{:dav_resource_name, _} | _]}} when retry? ->
        put_contact(conn, target, scalar_attrs, nested_data, false)

      {:error, _} ->
        send_invalid_vcard(conn)
    end
  end

  defp put_transaction(conn, {aid, name}, scalar_attrs, nested_data) do
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

  defp send_put_response(conn, status, contact) do
    conn
    |> put_resp_header("etag", "\"#{compute_etag(contact)}\"")
    |> send_resp(status, "")
  end

  # ── DELETE ─────────────────────────────────────────────────────────────

  defp handle_delete_contact(conn, name) do
    case find_contact(conn, name) do
      nil ->
        send_resp(conn, 404, "Not Found")

      contact ->
        authorize(conn, :delete, fn -> delete_contact(conn, contact) end)
    end
  end

  defp delete_contact(conn, contact) do
    # RFC 7232 §3.1: If-Match — only delete if ETag matches
    case check_if_match(conn, contact) do
      :precondition_failed ->
        send_resp(conn, 412, "Precondition Failed")

      :ok ->
        Contacts.soft_delete_contact(contact)
        send_resp(conn, 204, "")
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
        strong = {false, compute_etag(contact)}

        if String.trim(header) == "*" or strong in entity_tags(header),
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
        String.trim(header) == "*" or Enum.any?(entity_tags(header), &(elem(&1, 1) == etag))
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
    with [_, id_str] <- Regex.run(~r/\Akith-contact-([1-9]\d{0,17})\.vcf\z/, name),
         %Contact{dav_resource_name: nil} = contact <- get.(String.to_integer(id_str)) do
      contact
    else
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
    Contacts.list_contacts(account_id(conn), preload: Contacts.dav_preloads())
  end

  defp list_contacts_for_propfind(conn) do
    import Ecto.Query

    Contact
    |> Kith.Scope.scope_active(account_id(conn))
    |> where([c], c.is_archived == false)
    |> select([c], map(c, [:id, :updated_at, :dav_revision, :dav_resource_name]))
    |> Kith.Repo.all()
  end

  # R4: `dav_revision` changes on every write of the contact row (CDV-17)
  defp compute_etag(%{id: id, dav_revision: revision}) do
    data = "#{id}-#{revision}"

    :crypto.hash(:md5, data)
    |> Base.encode16(case: :lower)
  end

  defp generate_sync_token do
    "https://kith.app/ns/sync/#{DateTime.to_unix(DateTime.utc_now())}"
  end

  defp parse_sync_token(nil), do: nil
  defp parse_sync_token(""), do: nil

  defp parse_sync_token(token) do
    with [_, ts] <- Regex.run(~r{/ns/sync/(\d+)$}, token),
         {unix, ""} <- Integer.parse(ts),
         {:ok, dt} <- DateTime.from_unix(unix) do
      dt
    else
      _ -> nil
    end
  end

  defp addressbook_response(_conn, request_type, contacts) do
    ctag =
      case contacts do
        # A fixed value: an empty book must not look changed on every poll.
        # It still differs from every non-empty ctag (a Unix timestamp).
        [] ->
          "0"

        contacts ->
          contacts
          |> Enum.map(& &1.updated_at)
          |> Enum.max(DateTime)
          |> DateTime.to_unix()
          |> to_string()
      end

    props = [
      current_user_principal: XMLBuilder.current_user_principal("/dav/principals/"),
      resourcetype: XMLBuilder.resourcetype("<d:collection/><card:addressbook/>"),
      displayname: XMLBuilder.displayname("Kith Contacts"),
      getctag: XMLBuilder.getctag(ctag),
      # RFC 6578 §4: a collection supporting sync-collection exposes DAV:sync-token
      sync_token: XMLBuilder.sync_token(generate_sync_token()),
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
