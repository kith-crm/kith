defmodule Kith.DAV.XMLBuilder do
  @moduledoc """
  Builds WebDAV/CardDAV XML responses.

  Uses simple string interpolation rather than a full XML library. This is
  sufficient for the well-defined DAV response vocabulary and avoids adding
  a dependency.
  """

  @doc "Wraps response elements in a DAV multistatus envelope."
  def multistatus(responses) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">
    #{Enum.join(responses, "\n")}
    </d:multistatus>
    """
  end

  @doc "Builds a single DAV response element with an href and propstat children."
  def response(href, propstats) do
    """
    <d:response>
    <d:href>#{escape(href)}</d:href>
    #{Enum.join(propstats, "\n")}
    </d:response>
    """
  end

  @doc "Builds a propstat element wrapping properties with an HTTP status."
  def propstat(props, status \\ "HTTP/1.1 200 OK") do
    """
    <d:propstat>
    <d:prop>
    #{Enum.join(props, "\n")}
    </d:prop>
    <d:status>#{status}</d:status>
    </d:propstat>
    """
  end

  @doc "Builds a property status with an optional DAV precondition child."
  def propstat(props, status, nil), do: propstat(props, status)

  def propstat(props, status, condition) do
    "<d:propstat><d:prop>#{Enum.join(props, "\n")}</d:prop>" <>
      "<d:status>#{status}</d:status><d:error>#{condition}</d:error></d:propstat>"
  end

  # ── Common DAV properties ──────────────────────────────────────────────

  def displayname(name), do: "<d:displayname>#{escape(name)}</d:displayname>"
  def resourcetype(types), do: "<d:resourcetype>#{types}</d:resourcetype>"
  def getcontenttype(type), do: "<d:getcontenttype>#{type}</d:getcontenttype>"
  def getetag(etag), do: "<d:getetag>\"#{escape(etag)}\"</d:getetag>"

  def getlastmodified(dt),
    do: "<d:getlastmodified>#{format_http_date(dt)}</d:getlastmodified>"

  # ── CardDAV-specific properties ────────────────────────────────────────

  def addressbook_description(desc),
    do: "<card:addressbook-description>#{escape(desc)}</card:addressbook-description>"

  def supported_address_data do
    ~s(<card:supported-address-data>) <>
      ~s(<card:address-data-type content-type="text/vcard" version="3.0"/>) <>
      ~s(<card:address-data-type content-type="text/vcard" version="4.0"/>) <>
      ~s(</card:supported-address-data>)
  end

  def address_data(vcard) do
    safe = String.replace(vcard, "]]>", "]]]]><![CDATA[>")
    "<card:address-data><![CDATA[#{safe}]]></card:address-data>"
  end

  # ── CalendarServer extensions (CTag) ───────────────────────────────────

  def getctag(ctag), do: "<cs:getctag>#{escape(ctag)}</cs:getctag>"

  # ── Sync / Discovery ──────────────────────────────────────────────────

  def sync_token(token), do: "<d:sync-token>#{escape(token)}</d:sync-token>"

  def current_user_principal(href),
    do: "<d:current-user-principal><d:href>#{escape(href)}</d:href></d:current-user-principal>"

  @doc "Builds an empty element for a property in an arbitrary namespace."
  def empty_element("", name), do: "<#{name} xmlns=\"\"/>"
  def empty_element(ns, name), do: "<x:#{name} xmlns:x=\"#{escape(ns)}\"/>"

  @doc "Builds a response element for a deleted resource in sync-collection (RFC 6578 §3.5)."
  def response_deleted(href), do: status_response(href, "HTTP/1.1 404 Not Found")

  @doc """
  Builds a response element carrying only a status, no propstat (RFC 4918
  §14.24): a deleted sync member, a missing multiget href (RFC 6352 §8.7).
  """
  def status_response(href, status) do
    """
    <d:response>
    <d:href>#{escape(href)}</d:href>
    <d:status>#{status}</d:status>
    </d:response>
    """
  end

  @doc """
  The response for the request-URI when a REPORT's results were truncated at
  the client's limit (RFC 6352 §8.6.1, RFC 5323 §5.17).
  """
  def truncated_response(href) do
    """
    <d:response>
    <d:href>#{escape(href)}</d:href>
    <d:status>HTTP/1.1 507 Insufficient Storage</d:status>
    <d:error><d:number-of-matches-within-limits/></d:error>
    <d:responsedescription>Only the first matching results were returned</d:responsedescription>
    </d:response>
    """
  end

  @doc "Builds a DAV precondition error response (RFC 6352 §10)."
  def precondition_error(precondition, message) do
    error_body("<card:#{precondition}/>", message)
  end

  @doc """
  Builds a DAV:error body around an already-built condition element (RFC 4918
  §16). `card:` (CardDAV) and `k:` (Kith, `https://kith.app/ns/`) are bound.
  """
  def error_body(condition_xml, message) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:error xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:k="https://kith.app/ns/">
    #{condition_xml}
    <d:description>#{escape(message)}</d:description>
    </d:error>
    """
  end

  @doc "Wraps response elements in a DAV multistatus envelope with a sync-token."
  def multistatus(responses, sync_token: token) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">
    #{Enum.join(responses, "\n")}
    #{sync_token(token)}
    </d:multistatus>
    """
  end

  def max_resource_size(size), do: "<card:max-resource-size>#{size}</card:max-resource-size>"

  def principal_url(href),
    do: "<d:principal-URL><d:href>#{escape(href)}</d:href></d:principal-URL>"

  def owner(href), do: "<d:owner><d:href>#{escape(href)}</d:href></d:owner>"

  def supported_collation_set do
    "<card:supported-collation-set>" <>
      "<card:supported-collation>i;unicode-casemap</card:supported-collation>" <>
      "</card:supported-collation-set>"
  end

  # ── XML escaping ──────────────────────────────────────────────────────

  @doc "Escapes XML special characters in text content."
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  def escape(text), do: escape(to_string(text))

  # ── Helpers ────────────────────────────────────────────────────────────

  defp format_http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp format_http_date(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_http_date()
  end

  defp format_http_date(_), do: ""
end
