defmodule KithWeb.DAV.PropfindTest do
  @moduledoc """
  RFC 4918 — WebDAV PROPFIND and OPTIONS method tests.

  Covers: OPTIONS (§18), PROPFIND (§9.1), Multi-Status format (§13),
  discovery chain (§9.1 + RFC 5397 + RFC 6352 §7.1.1),
  Depth header (§9.1), collection properties (RFC 6352 §6.1),
  and address object resource properties (RFC 6352 §8.6).
  """
  use KithWeb.ConnCase, async: true

  import KithWeb.DAV.TestHelpers

  alias Kith.Contacts
  alias Kith.ContactsFixtures

  setup :setup_dav_user

  # ── RFC 4918 §18 — DAV header on OPTIONS ────────────────────────────────

  describe "RFC 4918 §18 — DAV header on OPTIONS" do
    test "OPTIONS MUST return DAV header with compliance class", context do
      conn = authed_dav(context, "OPTIONS", "/dav/")
      assert conn.status == 200
      [dav] = get_resp_header(conn, "dav")
      assert dav =~ "1"
    end

    test "OPTIONS MUST advertise supported methods in Allow header", context do
      conn = authed_dav(context, "OPTIONS", "/dav/")
      [allow] = get_resp_header(conn, "allow")

      for method <- ["OPTIONS", "GET", "PUT", "DELETE", "PROPFIND", "REPORT"] do
        assert allow =~ method
      end
    end

    test "DAV header MUST include 'addressbook' token (RFC 6352 §6.1)", context do
      conn = authed_dav(context, "OPTIONS", "/dav/")
      [dav] = get_resp_header(conn, "dav")
      assert dav =~ "addressbook"
    end
  end

  # ── RFC 4918 §9.1 — PROPFIND method requirements ───────────────────────

  describe "RFC 4918 §9.1 — PROPFIND method" do
    test "MUST return 207 Multi-Status", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      assert conn.status == 207
    end

    test "response Content-Type MUST be application/xml (RFC 4918 §13)", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/xml"
    end

    test "response body MUST contain multistatus XML element with DAV: namespace", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      body = conn.resp_body
      assert body =~ "<?xml"
      assert body =~ "multistatus"
      assert body =~ "DAV:"
    end

    test "empty PROPFIND body MUST be treated as allprop request (RFC 4918 §9.1)", context do
      conn = authed_dav(context, "PROPFIND", "/dav/", "")
      assert conn.status == 207
    end
  end

  # ── RFC 4918 §13 — Multi-Status response format ────────────────────────

  describe "RFC 4918 §13 — Multi-Status response format" do
    test "each response element MUST contain an href element",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "<d:href>"
    end

    test "each response element MUST contain at least one propstat element",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "<d:propstat>"
      assert conn.resp_body =~ "<d:status>"
      assert conn.resp_body =~ "200 OK"
    end

    test "DAV header MUST be present on 207 responses", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      assert get_resp_header(conn, "dav") != []
    end
  end

  # ── PROPFIND discovery chain ────────────────────────────────────────────

  describe "RFC 4918 — PROPFIND discovery chain" do
    test "root resource MUST include current-user-principal (RFC 5397)", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      assert conn.status == 207
      assert conn.resp_body =~ "current-user-principal"
      assert conn.resp_body =~ "/dav/principals/"
    end

    test "principal resource MUST include addressbook-home-set (RFC 6352 §7.1.1)", context do
      conn = authed_dav(context, "PROPFIND", "/dav/principals/")
      assert conn.status == 207
      assert conn.resp_body =~ "addressbook-home-set"
      assert conn.resp_body =~ "/dav/addressbooks/"
    end

    test "principal resource type MUST include principal (RFC 3744 §4)", context do
      conn = authed_dav(context, "PROPFIND", "/dav/principals/")
      assert conn.resp_body =~ "principal"
    end

    test "home set MUST list available address book collections", context do
      conn = authed_dav(context, "PROPFIND", "/dav/addressbooks/", propfind_body())
      assert conn.status == 207
      assert conn.resp_body =~ "/dav/addressbooks/default/"
    end

    test "full discovery chain resolves from root to addressbook", context do
      conn1 = authed_dav(context, "PROPFIND", "/dav/")
      assert conn1.resp_body =~ "/dav/principals/"

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PROPFIND", "/dav/principals/")

      assert conn2.resp_body =~ "/dav/addressbooks/"

      conn3 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PROPFIND", "/dav/addressbooks/", propfind_body())

      assert conn3.resp_body =~ "/dav/addressbooks/default/"

      conn4 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn4.status == 207
    end
  end

  # ── RFC 6352 §6.1 — address book collection properties ─────────────────

  describe "RFC 6352 §6.1 — address book collection properties" do
    test "resource type MUST include both collection and addressbook", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "collection"
      assert conn.resp_body =~ "addressbook"
    end

    test "MUST report displayname property", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "<d:displayname>"
      assert conn.resp_body =~ "Kith Contacts"
    end

    test "MUST report supported-address-data declaring vCard 3.0 (RFC 6352 §6.2.2)", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "supported-address-data"
      assert conn.resp_body =~ "text/vcard"
      assert conn.resp_body =~ "3.0"
    end

    test "MUST report supported-report-set (RFC 3253 §3.1.5)", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "supported-report-set"
      assert conn.resp_body =~ "addressbook-multiget"
      assert conn.resp_body =~ "sync-collection"
    end

    test "SHOULD include getctag for collection change detection (CalendarServer ext)",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "getctag"
    end

    test "getctag MUST change when collection contents change",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      conn1 =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      Process.sleep(1000)
      {:ok, _} = Contacts.update_contact(contact, %{first_name: "Changed"})

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [ctag1] =
        Regex.run(~r/<cs:getctag>([^<]+)<\/cs:getctag>/, conn1.resp_body, capture: :all_but_first)

      [ctag2] =
        Regex.run(~r/<cs:getctag>([^<]+)<\/cs:getctag>/, conn2.resp_body, capture: :all_but_first)

      assert ctag1 != ctag2
    end
  end

  # ── RFC 4918 §9.1 — Depth header on collections ────────────────────────

  describe "RFC 4918 §9.1 — PROPFIND Depth header on collections" do
    test "Depth:0 MUST return only the collection itself, not members",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert count_responses(conn.resp_body) == 1
    end

    test "Depth:1 MUST return the collection and its immediate members",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Bob"})
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Charlie"})

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.status == 207
      assert count_responses(conn.resp_body) == 4
    end

    test "Depth:1 on empty collection returns only the collection", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.status == 207
      assert count_responses(conn.resp_body) == 1
    end
  end

  # ── RFC 6352 §8.6 — address object resource properties in PROPFIND ─────

  describe "RFC 6352 §8.6 — address object resource properties in PROPFIND" do
    test "each member MUST report getetag property (RFC 4918 §15.6)",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "getetag"
    end

    test "each member MUST report getcontenttype as text/vcard",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "text/vcard"
    end

    test "each member MUST report getlastmodified property",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "getlastmodified"
    end

    test "member href MUST identify the address object resource",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "/dav/addressbooks/default/kith-contact-#{contact.id}.vcf"
    end

    test "deleted members MUST NOT appear in collection listing",
         %{account_id: account_id} = context do
      active = ContactsFixtures.contact_fixture(account_id, %{first_name: "Active"})
      deleted = ContactsFixtures.contact_fixture(account_id, %{first_name: "Deleted"})
      {:ok, _} = Contacts.soft_delete_contact(deleted)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert count_responses(conn.resp_body) == 2
      assert conn.resp_body =~ "kith-contact-#{active.id}.vcf"
      refute conn.resp_body =~ "kith-contact-#{deleted.id}.vcf"
    end

    test "archived members MUST NOT appear in collection listing",
         %{account_id: account_id} = context do
      active = ContactsFixtures.contact_fixture(account_id, %{first_name: "Active"})
      archived = ContactsFixtures.contact_fixture(account_id, %{first_name: "Archived"})
      {:ok, _} = Contacts.archive_contact(archived)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert count_responses(conn.resp_body) == 2
      assert conn.resp_body =~ "kith-contact-#{active.id}.vcf"
      refute conn.resp_body =~ "kith-contact-#{archived.id}.vcf"
    end
  end

  # ── RFC 4918 §9.1 — PROPFIND on individual address object ──────────────

  describe "RFC 4918 §9.1 — PROPFIND on individual address object" do
    test "MUST return 207 with properties for existing resource",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "PROPFIND", contact_path(contact))

      assert conn.status == 207
      assert conn.resp_body =~ "getetag"
      assert conn.resp_body =~ "getcontenttype"
    end

    test "MUST return 404 for non-existent resource", context do
      conn =
        authed_dav(context, "PROPFIND", "/dav/addressbooks/default/kith-contact-999999.vcf")

      assert conn.status == 404
    end

    test "MUST return 404 for malformed resource identifier", context do
      conn =
        authed_dav(context, "PROPFIND", "/dav/addressbooks/default/not-a-valid-uid.vcf")

      assert conn.status == 404
    end
  end

  # ── RFC 5397 §3 — current-user-principal on all resources ──────────────

  describe "RFC 5397 §3 — current-user-principal SHOULD be on all DAV resources" do
    test "principal resource MUST include current-user-principal", context do
      conn = authed_dav(context, "PROPFIND", "/dav/principals/")
      assert conn.status == 207
      assert conn.resp_body =~ "current-user-principal"
      assert conn.resp_body =~ "/dav/principals/"
    end

    test "home set resource MUST include current-user-principal", context do
      conn = authed_dav(context, "PROPFIND", "/dav/addressbooks/", propfind_body())
      assert conn.status == 207
      assert conn.resp_body =~ "current-user-principal"
      assert conn.resp_body =~ "/dav/principals/"
    end

    test "addressbook collection MUST include current-user-principal", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.status == 207
      assert conn.resp_body =~ "current-user-principal"
      assert conn.resp_body =~ "/dav/principals/"
    end

    test "individual contact MUST include current-user-principal",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "PROPFIND", contact_path(contact))
      assert conn.status == 207
      assert conn.resp_body =~ "current-user-principal"
      assert conn.resp_body =~ "/dav/principals/"
    end
  end

  # ── Defensive .well-known handling under /dav/ ─────────────────────────

  describe "defensive .well-known handling under /dav/" do
    test "PROPFIND to /dav/principals/.well-known/carddav redirects", context do
      conn = authed_dav(context, "PROPFIND", "/dav/principals/.well-known/carddav")
      assert conn.status == 301
      [location] = get_resp_header(conn, "location")
      assert location == "/dav/principals/"
    end

    test "PROPFIND to /dav/.well-known/carddav redirects", context do
      conn = authed_dav(context, "PROPFIND", "/dav/.well-known/carddav")
      assert conn.status == 301
      [location] = get_resp_header(conn, "location")
      assert location == "/dav/principals/"
    end
  end

  # ── Thunderbird-style discovery sequence ───────────────────────────────

  describe "Thunderbird-style discovery sequence" do
    test "completes discovery from well-known through to addressbook", context do
      # Step 1: PROPFIND /.well-known/carddav should redirect
      conn1 = dav_request(build_conn(), "PROPFIND", "/.well-known/carddav")
      assert conn1.status == 301
      [location1] = get_resp_header(conn1, "location")
      assert location1 == "/dav/principals/"

      # Step 2: Follow redirect — PROPFIND /dav/principals/
      conn2 = authed_dav(context, "PROPFIND", location1)
      assert conn2.status == 207
      assert conn2.resp_body =~ "current-user-principal"
      assert conn2.resp_body =~ "/dav/principals/"
      assert conn2.resp_body =~ "addressbook-home-set"
      assert conn2.resp_body =~ "/dav/addressbooks/"

      # Step 3: PROPFIND addressbook home set
      conn3 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PROPFIND", "/dav/addressbooks/", propfind_body())

      assert conn3.status == 207
      assert conn3.resp_body =~ "/dav/addressbooks/default/"

      # Step 4: PROPFIND the addressbook collection
      conn4 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn4.status == 207
      assert conn4.resp_body =~ "getctag"
      assert conn4.resp_body =~ "addressbook"

      # Step 5: Thunderbird fallback — .well-known relative to configured URL
      conn5 = authed_dav(context, "PROPFIND", "/dav/principals/.well-known/carddav")
      assert conn5.status == 301
      [location5] = get_resp_header(conn5, "location")
      assert location5 == "/dav/principals/"
    end
  end

  # ── Tier 3+4 — RFC 3744, RFC 6352, RFC 4918 additional properties ────

  describe "RFC 3744 §4.2 — principal-URL property" do
    test "principal resource includes principal-URL", context do
      conn = authed_dav(context, "PROPFIND", "/dav/principals/")
      assert conn.resp_body =~ "principal-URL"
      assert conn.resp_body =~ "/dav/principals/"
    end
  end

  describe "RFC 3744 §5.1 — owner property" do
    test "addressbook collection includes owner property", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "owner"
      assert conn.resp_body =~ "/dav/principals/"
    end
  end

  describe "RFC 3744 §5.4 — current-user-privilege-set" do
    test "addressbook collection advertises read and write privileges", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "current-user-privilege-set"
      assert conn.resp_body =~ "<d:read/>"
      assert conn.resp_body =~ "<d:write/>"
    end
  end

  describe "RFC 6352 §6.2.1 — max-resource-size" do
    test "addressbook collection advertises max-resource-size", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "max-resource-size"
    end
  end

  describe "RFC 6352 §6.2.3 — supported-collation-set" do
    test "addressbook collection advertises supported collation", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ "supported-collation-set"
      assert conn.resp_body =~ "i;unicode-casemap"
    end
  end

  describe "RFC 4918 §9.1.4 — Depth: infinity" do
    test "MUST return 403 Forbidden for Depth: infinity", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "infinity")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.status == 403
      assert conn.resp_body =~ "propfind-finite-depth"
    end
  end

  describe "RFC 4918 §8.2 — PROPPATCH stub" do
    test "returns 207 with 403 propstat for live properties", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propertyupdate xmlns:d="DAV:">
        <d:set><d:prop><d:displayname>New Name</d:displayname></d:prop></d:set>
      </d:propertyupdate>
      """

      conn = authed_dav(context, "PROPPATCH", "/dav/addressbooks/default/", body)
      assert conn.status == 207
      assert conn.resp_body =~ "403 Forbidden"
    end
  end

  # ── RFC 4918 §9.1 — PROPFIND request body filtering ───────────────────

  describe "RFC 4918 §9.1 — PROPFIND specific property requests" do
    test "requesting specific prop returns only that property", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:getetag/></d:prop>
      </d:propfind>
      """

      contact = ContactsFixtures.contact_fixture(context.account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PROPFIND", contact_path(contact), body)

      assert conn.status == 207
      assert conn.resp_body =~ "getetag"
      # Should NOT include unrequested properties
      refute conn.resp_body =~ "getcontenttype"
      refute conn.resp_body =~ "getlastmodified"
    end

    test "requesting unknown property ignores it, serves known props", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:">
        <d:prop><d:getetag/><d:unknown-property/></d:prop>
      </d:propfind>
      """

      contact = ContactsFixtures.contact_fixture(context.account_id)

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PROPFIND", contact_path(contact), body)

      assert conn.status == 207
      # Known prop is still served
      assert conn.resp_body =~ "getetag"
      # Unknown props are silently ignored (not in atom table)
      refute conn.resp_body =~ "unknown-property"
    end

    test "propname request returns empty property elements", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:">
        <d:propname/>
      </d:propfind>
      """

      conn = authed_dav(context, "PROPFIND", "/dav/principals/", body)
      assert conn.status == 207
      # Should have empty elements (self-closing tags)
      assert conn.resp_body =~ "<d:current-user-principal/>"
      assert conn.resp_body =~ "<d:resourcetype/>"
      assert conn.resp_body =~ "<card:addressbook-home-set/>"
      # Empty elements should NOT contain nested href values
      refute conn.resp_body =~ "<d:current-user-principal><d:href>"
    end
  end

  # ── CardDAV e2e regressions (docs/carddav-e2e.md) ─────────────────────

  describe "CardDAV e2e regressions" do
    test "CDV-01: OPTIONS Allow lists PROPPATCH", context do
      for path <- ["/dav/", "/dav/addressbooks/default/"] do
        conn = authed_dav(context, "OPTIONS", path)
        [allow] = get_resp_header(conn, "allow")
        methods = allow |> String.split(",") |> Enum.map(&String.trim/1)
        assert "PROPPATCH" in methods
      end
    end

    test "CDV-02: PROPFIND on the home set honours Depth 0", context do
      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/", propfind_body())

      assert conn.status == 207
      assert count_responses(conn.resp_body) == 1
      assert conn.resp_body =~ "<d:href>/dav/addressbooks/</d:href>"

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/", propfind_body())

      assert count_responses(conn.resp_body) == 2
    end

    test "CDV-03: address book offers a URI sync-token property", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:"><d:prop><d:sync-token/></d:prop></d:propfind>
      """

      conn =
        context.conn
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      refute conn.resp_body =~ "404 Not Found"
      assert [_, token] = Regex.run(~r{<d:sync-token>([^<]+)</d:sync-token>}, conn.resp_body)
      assert token =~ ~r/^[a-z][a-z0-9+.-]*:\S+$/i
    end
  end
end
