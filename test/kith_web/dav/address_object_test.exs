defmodule KithWeb.DAV.AddressObjectTest do
  @moduledoc """
  RFC 6352 §8.6 — GET address object resource
  RFC 2426     — vCard 3.0 format requirements
  RFC 6352 §5.1 — PUT to create/update address objects
  RFC 4918 §9.6 — DELETE address objects
  RFC 7232 §2.3 — ETag format and behavior
  """
  use KithWeb.ConnCase, async: true

  import Kith.Factory
  import KithWeb.DAV.TestHelpers

  alias Kith.Contacts
  alias Kith.ContactsFixtures

  setup :setup_dav_user

  test "PUT preserves family-only and formatted-only native names",
       %{account_id: aid} = context do
    for {name, structured, first, last} <- [
          {"Family Only", "N:Family Only;;;;\r\n", "", "Family Only"},
          {"Formatted Only", "", "Formatted Only", nil}
        ] do
      resource = "#{String.replace(name, " ", "-")}.vcf"
      href = "/dav/addressbooks/default/#{resource}"
      body = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\n#{structured}END:VCARD\r\n"
      assert authed_dav(context, "PUT", href, body).status == 201
      card = authed_dav(context, "GET", href).resp_body
      assert card =~ "FN:#{name}\r\n"
      assert card =~ "N:#{last};#{first};;;\r\n"
      assert authed_dav(context, "PUT", href, card).status == 204
      assert authed_dav(context, "GET", href).resp_body =~ "FN:#{name}\r\n"
      stored = Kith.DAV.Store.get_by_resource_name(aid, resource)
      assert stored.first_name == first
      assert stored.last_name == last
      assert stored.display_name == name
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 6352 §8.6 — GET address object resource
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 6352 §8.6 — GET address object resource" do
    test "Content-Type MUST be text/vcard (RFC 6352 §5.1)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/vcard"
    end

    test "response MUST include ETag header (RFC 6352 §5.1)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      [etag] = get_resp_header(conn, "etag")
      assert etag != ""
    end

    test "ETag MUST be a quoted string (RFC 7232 §2.3)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      [etag] = get_resp_header(conn, "etag")
      assert Regex.match?(~r/^(W\/)?"[^"]*"$/, etag)
    end

    test "MUST return 404 for non-existent address object", context do
      conn =
        authed_dav(context, "GET", "/dav/addressbooks/default/kith-contact-999999.vcf")

      assert conn.status == 404
    end

    test "MUST return 404 for deleted address object",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      {:ok, _} = Contacts.soft_delete_contact(contact)

      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 2426 — vCard 3.0 format in GET response
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 2426 — vCard 3.0 format in GET response" do
    test "body MUST begin with BEGIN:VCARD and end with END:VCARD",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      body = conn.resp_body
      assert String.starts_with?(body, "BEGIN:VCARD")
      assert body |> String.trim_trailing() |> String.ends_with?("END:VCARD")
    end

    test "vCard MUST contain VERSION:3.0 property", %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ "VERSION:3.0"
    end

    test "vCard MUST contain FN (formatted name) property (RFC 2426 §3.1.1)",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{first_name: "Zara", last_name: "Quinn"})

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^FN:/m
      assert conn.resp_body =~ "Zara"
    end

    test "vCard MUST contain N (structured name) property (RFC 2426 §3.1.2)",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{first_name: "Zara", last_name: "Quinn"})

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^N:/m
    end

    test "vCard MUST contain UID property for CardDAV (RFC 6352 §6.3.2)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^UID:/m
    end

    test "vCard MUST include BDAY when contact has birthdate",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1990-06-15]
        })

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ "BDAY:1990-06-15"
    end

    test "vCard MUST include ORG when contact has company",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          company: "Acme Corp"
        })

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^ORG:/m
      assert conn.resp_body =~ "Acme Corp"
    end

    test "vCard MUST include ADR when contact has addresses",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})

      ContactsFixtures.address_fixture(contact, %{
        "label" => "Home",
        "line1" => "123 Main St",
        "city" => "Springfield"
      })

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^ADR/m
      assert conn.resp_body =~ "123 Main St"
      assert conn.resp_body =~ "Springfield"
    end

    test "vCard MUST include EMAIL when contact has email fields",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})
      email_type = insert(:contact_field_type, protocol: "mailto", vcard_label: "EMAIL")

      ContactsFixtures.contact_field_fixture(contact, email_type.id, %{
        "value" => "alice@example.com"
      })

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^EMAIL/m
      assert conn.resp_body =~ "alice@example.com"
    end

    test "vCard MUST include TEL when contact has phone fields",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})
      tel_type = insert(:contact_field_type, protocol: "tel", vcard_label: "TEL")

      ContactsFixtures.contact_field_fixture(contact, tel_type.id, %{
        "value" => "+1-555-0123"
      })

      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ ~r/^TEL/m
      assert conn.resp_body =~ "+15550123"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 6352 §5.1 — PUT to create new address object
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 6352 §5.1 — PUT to create new address object" do
    test "MUST return 201 Created when resource is new", context do
      vcard = build_vcard("New", "Contact")

      conn =
        authed_dav(context, "PUT", "/dav/addressbooks/default/kith-contact-999999.vcf", vcard)

      assert conn.status == 201
    end

    test "PUT response has no ETag header on creation", context do
      vcard = build_vcard("New", "Contact")

      conn =
        authed_dav(context, "PUT", "/dav/addressbooks/default/kith-contact-999999.vcf", vcard)

      assert conn.status == 201
      assert get_resp_header(conn, "etag") == []
    end

    test "created resource MUST be retrievable via GET", context do
      vcard = build_vcard("Created", "ViaDAV", nickname: "Davy")

      conn1 =
        authed_dav(context, "PUT", "/dav/addressbooks/default/kith-contact-999999.vcf", vcard)

      assert conn1.status == 201

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [_, discovered_href] =
        Regex.run(~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>}, conn2.resp_body)

      conn3 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", discovered_href)

      assert conn3.status == 200
      assert conn3.resp_body =~ "Created"
      assert conn3.resp_body =~ "ViaDAV"
    end

    test "server MUST reject vCard missing required properties (first_name)", context do
      invalid = "BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE:no name\r\nEND:VCARD\r\n"

      conn =
        authed_dav(context, "PUT", "/dav/addressbooks/default/kith-contact-999999.vcf", invalid)

      assert conn.status in 400..499
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 6352 §5.1 — PUT to update existing address object
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 6352 §5.1 — PUT to update existing address object" do
    test "MUST return 204 No Content when resource already exists",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Original"})
      vcard = build_vcard("Updated", "Name")

      conn = authed_dav(context, "PUT", contact_path(contact), vcard)

      assert conn.status == 204
    end

    test "PUT response has no ETag header on update",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      vcard = build_vcard("Updated", "Contact")

      conn = authed_dav(context, "PUT", contact_path(contact), vcard)

      assert get_resp_header(conn, "etag") == []
    end

    test "updated properties MUST be reflected in subsequent GET",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Original"})
      vcard = build_vcard("Modified", "Person", company: "NewCorp")

      conn1 = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn1.status == 204

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      assert conn2.status == 200
      assert conn2.resp_body =~ "Modified"
      assert conn2.resp_body =~ "Person"
      assert conn2.resp_body =~ "NewCorp"
    end

    test "ETag MUST change after successful update (RFC 7232 §2.3)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Original"})

      conn1 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      [etag_before] = get_resp_header(conn1, "etag")

      Process.sleep(1000)
      vcard = build_vcard("Updated", "Name")
      conn2 = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn2.status == 204
      [etag_after] = authed_dav(context, "GET", contact_path(contact)) |> get_resp_header("etag")

      assert etag_before != etag_after
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 4918 §9.6 — DELETE address object
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 4918 §9.6 — DELETE address object" do
    test "MUST return 204 No Content on successful deletion",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "DELETE", contact_path(contact))

      assert conn.status == 204
    end

    test "deleted resource MUST return 404 on subsequent GET",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      conn1 = authed_dav(context, "DELETE", contact_path(contact))
      assert conn1.status == 204

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      assert conn2.status == 404
    end

    test "deleted resource MUST NOT appear in collection listing",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      authed_dav(context, "DELETE", contact_path(contact))

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      refute conn.resp_body =~ "kith-contact-#{contact.id}.vcf"
    end

    test "MUST return 404 when deleting non-existent resource", context do
      conn =
        authed_dav(context, "DELETE", "/dav/addressbooks/default/kith-contact-999999.vcf")

      assert conn.status == 404
    end
  end

  # ── RFC 7232 §3 — Conditional requests (If-Match / If-None-Match) ─────

  describe "RFC 7232 §3 — conditional requests" do
    test "PUT with correct If-Match succeeds (204)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      # GET to retrieve ETag
      conn_get = authed_dav(context, "GET", contact_path(contact))
      [etag] = get_resp_header(conn_get, "etag")

      vcard = build_vcard("Updated", "Person")

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-match", etag)
        |> dav_request("PUT", contact_path(contact), vcard)

      assert conn.status == 204
    end

    test "PUT with wrong If-Match returns 412 Precondition Failed",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      vcard = build_vcard("Updated", "Person")

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-match", "\"stale-etag-value\"")
        |> dav_request("PUT", contact_path(contact), vcard)

      assert conn.status == 412
    end

    test "PUT without If-Match header proceeds normally",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      vcard = build_vcard("Updated", "Person")
      conn = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn.status == 204
    end

    test "DELETE with correct If-Match succeeds (204)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn_get = authed_dav(context, "GET", contact_path(contact))
      [etag] = get_resp_header(conn_get, "etag")

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-match", etag)
        |> dav_request("DELETE", contact_path(contact))

      assert conn.status == 204
    end

    test "DELETE with wrong If-Match returns 412",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-match", "\"stale-etag\"")
        |> dav_request("DELETE", contact_path(contact))

      assert conn.status == 412
    end

    test "PUT with If-None-Match: * to existing resource returns 412",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      vcard = build_vcard("New", "Person")

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-none-match", "*")
        |> dav_request("PUT", contact_path(contact), vcard)

      assert conn.status == 412
    end

    test "PUT with If-None-Match: * to new resource succeeds (201)", context do
      vcard = build_vcard("Brand", "New")

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-none-match", "*")
        |> dav_request("PUT", "/dav/addressbooks/default/kith-contact-999999.vcf", vcard)

      assert conn.status == 201
    end
  end

  # ── Round-trip contact fields via PUT/GET ──────────────────────────────

  describe "PUT/GET round-trip for contact fields" do
    test "PUT vCard with email and phone, GET returns them",
         context do
      vcard =
        build_vcard("Jane", "Doe",
          email: "jane@example.com",
          phone: "+15551234567"
        )

      path = "/dav/addressbooks/default/kith-contact-new-1.vcf"
      conn = authed_dav(context, "PUT", path, vcard)
      assert conn.status == 201

      # The server assigns its own UID, so we need to find the contact
      # via PROPFIND to get its actual path
      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      # Extract the contact href from PROPFIND response
      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.status == 200
      assert conn_get.resp_body =~ "jane@example.com"
      assert conn_get.resp_body =~ "+15551234567"
    end

    test "PUT update replaces contact fields (not appends)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      # First PUT with one email
      vcard1 = build_vcard("Jane", "Doe", email: "old@example.com")
      conn1 = authed_dav(context, "PUT", contact_path(contact), vcard1)
      assert conn1.status == 204

      # Second PUT with different email
      vcard2 = build_vcard("Jane", "Doe", email: "new@example.com")

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PUT", contact_path(contact), vcard2)

      assert conn2.status == 204

      # GET should show only the new email, not both
      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      assert conn_get.resp_body =~ "new@example.com"
      refute conn_get.resp_body =~ "old@example.com"
    end
  end

  # ── RFC 6352 §5.1 — PUT Content-Type validation ───────────────────────

  describe "RFC 6352 §5.1 — PUT Content-Type validation" do
    test "PUT with wrong Content-Type returns 415 Unsupported Media Type", context do
      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("content-type", "application/json")
        |> dispatch(
          KithWeb.Endpoint,
          "PUT",
          "/dav/addressbooks/default/kith-contact-new.vcf",
          "{}"
        )

      assert conn.status == 415
    end

    test "PUT with invalid vCard body returns 403 with precondition error", context do
      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("content-type", "text/vcard")
        |> dispatch(
          KithWeb.Endpoint,
          "PUT",
          "/dav/addressbooks/default/kith-contact-new.vcf",
          "not a vcard"
        )

      assert conn.status == 403
      assert conn.resp_body =~ "valid-address-data"
    end
  end

  # ── RFC 2426 §2.6 — vCard line folding ─────────────────────────────────

  describe "RFC 2426 §2.6 — vCard line folding" do
    test "vCard lines longer than 75 octets are folded",
         %{account_id: account_id} = context do
      long_desc = String.duplicate("A", 200)

      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Test",
          description: long_desc
        })

      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.status == 200
      # Folded lines have CRLF followed by a space
      assert conn.resp_body =~ "\r\n "
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 2426 §3.1.2 — N property with middle name
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 2426 §3.1.2 — N property with middle name" do
    test "vCard MUST include middle name in N property when present",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          last_name: "Smith",
          middle_name: "Marie"
        })

      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.resp_body =~ "N:Smith;Alice;Marie;;"
    end

    test "PUT vCard with middle name round-trips via GET", context do
      vcard = build_vcard("Jane", "Doe", middle_name: "Elizabeth")

      conn =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/kith-contact-999999.vcf",
          vcard
        )

      assert conn.status == 201

      # Find the created contact via PROPFIND
      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "N:Doe;Jane;Elizabeth;;"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 2426 §3.6.4 — REV (revision timestamp)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 2426 §3.6.4 — REV property" do
    test "vCard MUST include REV with ISO 8601 timestamp",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.resp_body =~ ~r/^REV:\d{4}-\d{2}-\d{2}T/m
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 2426 §3.6.1 — CATEGORIES (tags) round-trip
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 2426 §3.6.1 — CATEGORIES round-trip" do
    test "vCard MUST include CATEGORIES when contact has tags",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      {:ok, tag} = Contacts.create_tag(account_id, %{"name" => "Family"})
      Contacts.tag_contact(contact, tag)

      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.resp_body =~ "CATEGORIES:Family"
    end

    test "vCard MUST NOT include CATEGORIES when contact has no tags",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))
      refute conn.resp_body =~ "CATEGORIES"
    end

    test "PUT vCard with CATEGORIES creates tags and round-trips via GET", context do
      vcard = build_vcard("Jane", "Doe", categories: ["Family", "VIP"])

      conn =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/kith-contact-999999.vcf",
          vcard
        )

      assert conn.status == 201

      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "CATEGORIES:"
      assert conn_get.resp_body =~ "Family"
      assert conn_get.resp_body =~ "VIP"
    end

    test "PUT vCard replaces existing tags (not appends)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      vcard1 = build_vcard("Jane", "Doe", categories: ["OldTag"])
      conn1 = authed_dav(context, "PUT", contact_path(contact), vcard1)
      assert conn1.status == 204

      vcard2 = build_vcard("Jane", "Doe", categories: ["NewTag"])

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("PUT", contact_path(contact), vcard2)

      assert conn2.status == 204

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      assert conn_get.resp_body =~ "NewTag"
      refute conn_get.resp_body =~ "OldTag"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # X-GENDER / GENDER round-trip
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GENDER round-trip" do
    test "vCard 3.0 MUST include X-GENDER when contact has gender",
         %{account_id: account_id} = context do
      genders = Contacts.list_genders(account_id)
      gender = Enum.find(genders, &(&1.name == "Male"))

      contact =
        ContactsFixtures.contact_fixture(account_id, %{gender_id: gender.id})

      conn = authed_dav(context, "GET", contact_path(contact))
      assert conn.resp_body =~ "X-GENDER:Male"
    end

    test "PUT vCard with X-GENDER resolves to gender_id and round-trips",
         context do
      vcard = build_vcard("Jane", "Doe", gender: "Female")

      conn =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/kith-contact-999999.vcf",
          vcard
        )

      assert conn.status == 201

      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "X-GENDER:Female"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 2426 §3.1.4 / RFC 6350 §6.2.4 — PHOTO round-trip
  # ═══════════════════════════════════════════════════════════════════════════

  describe "PHOTO round-trip" do
    test "vCard MUST NOT include PHOTO when contact has no avatar",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))
      refute conn.resp_body =~ "PHOTO"
    end

    # Note: Testing PHOTO with avatar requires actual file storage which
    # may not be available in the test environment. The serializer unit tests
    # cover the PHOTO generation logic directly.
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # RFC 6352 §8.3 — Content negotiation
  # ═══════════════════════════════════════════════════════════════════════════

  describe "RFC 6352 §8.3 — content negotiation" do
    test "GET with Accept: text/vcard;version=4.0 returns vCard 4.0",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("accept", "text/vcard;version=4.0")
        |> dav_request("GET", contact_path(contact))

      assert conn.status == 200
      assert conn.resp_body =~ "VERSION:4.0"
      refute conn.resp_body =~ "VERSION:3.0"
      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "version=4.0"
    end

    test "GET without version preference defaults to vCard 3.0",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      conn = authed_dav(context, "GET", contact_path(contact))

      assert conn.resp_body =~ "VERSION:3.0"
    end

    test "supported-address-data advertises both 3.0 and 4.0", context do
      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "0")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert conn.resp_body =~ ~s(version="3.0")
      assert conn.resp_body =~ ~s(version="4.0")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Comprehensive PUT/GET round-trip for ALL scalar fields
  # ═══════════════════════════════════════════════════════════════════════════

  describe "PUT/GET round-trip — all scalar fields" do
    test "birthdate round-trips via BDAY property", context do
      vcard = build_vcard("Alice", "Test", birthdate: "1990-06-15")
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "BDAY:1990-06-15"
    end

    test "nickname round-trips via NICKNAME property", context do
      vcard = build_vcard("Alice", "Test", nickname: "Ali")
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "NICKNAME:Ali"
    end

    test "occupation round-trips via TITLE property", context do
      vcard = build_vcard("Alice", "Test", occupation: "Software Engineer")
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "TITLE:Software Engineer"
    end

    test "description round-trips via NOTE property", context do
      vcard = build_vcard("Alice", "Test", note: "Met at conference 2024")
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "NOTE:Met at conference 2024"
    end

    test "company round-trips via ORG property", context do
      vcard = build_vcard("Alice", "Test", company: "Acme Corp")
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "ORG:Acme Corp"
    end

    test "all scalar fields round-trip together", context do
      vcard =
        build_vcard("Alice", "Test",
          middle_name: "Marie",
          nickname: "Ali",
          birthdate: "1990-06-15",
          company: "Acme Corp",
          occupation: "Engineer",
          note: "Best friend"
        )

      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      body = conn_get.resp_body
      assert body =~ "N:Test;Alice;Marie;;"
      assert body =~ "NICKNAME:Ali"
      assert body =~ "BDAY:1990-06-15"
      assert body =~ "ORG:Acme Corp"
      assert body =~ "TITLE:Engineer"
      assert body =~ "NOTE:Best friend"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # PUT/GET round-trip — field clearing (PUT without field clears it)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "PUT/GET round-trip — field clearing" do
    test "PUTting vCard without BDAY clears existing birthdate",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1990-06-15]
        })

      # Verify birthdate is serialized first
      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "BDAY:1990-06-15"

      # PUT vCard without BDAY
      vcard = build_vcard("Alice", "Updated")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      # Verify birthdate is cleared
      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      refute conn_get2.resp_body =~ "BDAY"
    end

    test "PUTting vCard without NICKNAME clears existing nickname",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          nickname: "Ali"
        })

      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "NICKNAME:Ali"

      vcard = build_vcard("Alice", "Updated")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      refute conn_get2.resp_body =~ "NICKNAME"
    end

    test "PUTting vCard without ORG clears existing company",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          company: "OldCorp"
        })

      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "ORG:OldCorp"

      vcard = build_vcard("Alice", "Updated")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      refute conn_get2.resp_body =~ "ORG"
    end

    test "PUTting vCard without TITLE clears existing occupation",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          occupation: "Engineer"
        })

      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "TITLE:Engineer"

      vcard = build_vcard("Alice", "Updated")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      refute conn_get2.resp_body =~ "TITLE"
    end

    test "PUTting vCard without NOTE clears existing description",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          description: "Old note"
        })

      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "NOTE:Old note"

      vcard = build_vcard("Alice", "Updated")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      refute conn_get2.resp_body =~ "NOTE"
    end

    test "PUTting vCard without middle name clears existing middle_name",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          last_name: "Smith",
          middle_name: "Marie"
        })

      conn_get1 = authed_dav(context, "GET", contact_path(contact))
      assert conn_get1.resp_body =~ "N:Smith;Alice;Marie;;"

      vcard = build_vcard("Alice", "Smith")
      conn_put = authed_dav(context, "PUT", contact_path(contact), vcard)
      assert conn_put.status == 204

      conn_get2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", contact_path(contact))

      assert conn_get2.resp_body =~ "N:Smith;Alice;;;"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # PUT/GET round-trip — IMPP (RFC 6350 §6.4.3)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "PUT/GET round-trip — IMPP" do
    test "PUT vCard with IMPP stores and re-serializes the field", context do
      vcard = build_vcard("Alice", "Test", impp: ["xmpp:alice@chat.example.com"])
      {href, _} = put_and_find(context, vcard)

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      # IMPP should be stored as a contact field and re-serialized
      # The exact property name depends on the serializer's handling of the field type
      assert conn_get.resp_body =~ ~r/IMPP.*alice@chat\.example\.com/
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # vCard 4.0 PUT round-trips
  # ═══════════════════════════════════════════════════════════════════════════

  describe "vCard 4.0 PUT round-trip" do
    test "PUT vCard 4.0 with GENDER:F resolves to gender and round-trips",
         context do
      vcard = build_vcard_v40("Jane", "Doe", gender: "F")

      conn =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/kith-contact-999999.vcf",
          vcard
        )

      assert conn.status == 201

      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      # GET as v3.0 — should show X-GENDER:Female
      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "X-GENDER:Female"

      # GET as v4.0 — should show GENDER:F
      conn_get40 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("accept", "text/vcard;version=4.0")
        |> dav_request("GET", href)

      assert conn_get40.resp_body =~ "GENDER:F"
    end

    test "PUT vCard 4.0 with compact BDAY round-trips", context do
      vcard = build_vcard_v40("Jane", "Doe", birthdate: "19900615")

      conn =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/kith-contact-999999.vcf",
          vcard
        )

      assert conn.status == 201

      conn_list =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [href] =
        Regex.scan(
          ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
          conn_list.resp_body,
          capture: :all_but_first
        )
        |> List.flatten()

      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", href)

      assert conn_get.resp_body =~ "BDAY:1990-06-15"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════════════

  # Creates a contact via PUT and returns {href, conn} for the created resource
  defp put_and_find(context, vcard) do
    path = "/dav/addressbooks/default/kith-contact-new-#{System.unique_integer([:positive])}.vcf"
    conn = authed_dav(context, "PUT", path, vcard)
    assert conn.status == 201

    conn_list =
      build_conn()
      |> basic_auth(context.user.email, dav_password())
      |> put_req_header("depth", "1")
      |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

    [href] =
      Regex.scan(
        ~r{<d:href>(/dav/addressbooks/default/[^<]+\.vcf)</d:href>},
        conn_list.resp_body,
        capture: :all_but_first
      )
      |> List.flatten()

    {href, conn}
  end

  describe "GET with If-None-Match" do
    test "GET with a matching If-None-Match is 304 with the ETag and no body",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      [etag] = authed_dav(context, "GET", contact_path(contact)) |> get_resp_header("etag")

      get = fn inm ->
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-none-match", inm)
        |> dav_request("GET", contact_path(contact))
      end

      for inm <- [etag, "W/#{etag}", ~s("other", #{etag}), "*"] do
        conn = get.(inm)
        assert conn.status == 304, "If-None-Match: #{inm} -> #{conn.status}"
        assert conn.resp_body == ""
        assert get_resp_header(conn, "etag") == [etag]
      end

      assert get.(~s("other")).status == 200
    end
  end

  test "a stored resource name is the only GET identity", context do
    contact = ContactsFixtures.contact_fixture(context.account_id)
    href = contact_path(contact)
    assert authed_dav(context, "GET", href).status == 200

    assert authed_dav(context, "GET", "/dav/addressbooks/default/kith-contact-#{contact.id}.vcf").status ==
             404

    {:ok, _} = Contacts.archive_contact(contact)
    assert authed_dav(context, "GET", href).status == 404
  end

  test "PUT to a trashed contact's href is 409 and does not restore it",
       %{account_id: aid} = context do
    contact = ContactsFixtures.contact_fixture(aid)
    path = contact_path(contact)
    {:ok, _} = Contacts.soft_delete_contact(contact)
    assert authed_dav(context, "PUT", path, build_vcard("Changed", "Name")).status == 409
    assert Kith.Repo.get!(Kith.Contacts.Contact, contact.id).deleted_at
  end

  test "PUT changing the UID of an existing card is 409", %{account_id: aid} = context do
    contact = ContactsFixtures.contact_fixture(aid)

    assert authed_dav(
             context,
             "PUT",
             contact_path(contact),
             build_vcard("Changed", "Name", uid: "different")
           ).status == 409
  end

  test "PUT to an archived contact's href is 409 and does not unarchive it",
       %{account_id: aid} = context do
    contact = ContactsFixtures.contact_fixture(aid)
    path = contact_path(contact)
    {:ok, _} = Contacts.archive_contact(contact)
    assert authed_dav(context, "PUT", path, build_vcard("Changed", "Name")).status == 409
    assert Kith.Repo.get!(Kith.Contacts.Contact, contact.id).is_archived
  end

  test "PUT of a new card whose UID a trashed contact holds is 409",
       %{account_id: aid} = context do
    contact = ContactsFixtures.contact_fixture(aid)
    path = contact_path(contact)
    contact = Kith.Repo.preload(contact, :dav)
    {:ok, _} = Contacts.soft_delete_contact(contact)

    response =
      authed_dav(
        context,
        "PUT",
        "/dav/addressbooks/default/new.vcf",
        build_vcard("New", "Name", uid: contact.dav.uid)
      )

    assert response.status == 409
    assert response.resp_body =~ "no-uid-conflict"
    assert response.resp_body =~ path
    assert Kith.DAV.Store.get_by_resource_name(aid, "new.vcf") == nil
  end

  test "PUT retains extras and replaces them on update", context do
    path = "/dav/addressbooks/default/extras.vcf"

    body =
      String.replace(
        build_vcard("Extra", "Fields", uid: "extra-uid"),
        "END:VCARD",
        "X-CUSTOM:verbatim\r\nitem1.X-CUSTOM:drop\r\nEND:VCARD"
      )

    assert authed_dav(context, "PUT", path, body).status == 201
    stored = authed_dav(context, "GET", path).resp_body
    assert stored =~ "UID:extra-uid"
    assert stored =~ "X-CUSTOM:verbatim"
    refute stored =~ "item1.X-CUSTOM"

    assert authed_dav(context, "PUT", path, build_vcard("Extra", "Fields", uid: "extra-uid")).status ==
             204

    refute authed_dav(context, "GET", path).resp_body =~ "X-CUSTOM"
  end

  test "invalid creation leaves no contact or identity", %{account_id: aid} = context do
    before_count = Contacts.count_contacts(aid)

    response =
      authed_dav(
        context,
        "PUT",
        "/dav/addressbooks/default/invalid.vcf",
        "BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE:no name\r\nEND:VCARD\r\n"
      )

    assert response.status == 403
    assert response.resp_body =~ "valid-address-data"
    assert Contacts.count_contacts(aid) == before_count
    assert Kith.DAV.Store.get_by_resource_name(aid, "invalid.vcf") == nil
  end

  test "a child validation failure rolls back creation and update",
       %{account_id: aid} = context do
    path = "/dav/addressbooks/default/rollback.vcf"
    count = Contacts.count_contacts(aid)
    invalid = build_vcard("Rollback", "Card", email: String.duplicate("x", 256))
    assert authed_dav(context, "PUT", path, invalid).status == 403
    assert Contacts.count_contacts(aid) == count
    assert Kith.DAV.Store.get_by_resource_name(aid, "rollback.vcf") == nil

    assert authed_dav(
             context,
             "PUT",
             path,
             build_vcard("Original", "Card", email: "ok@example.com")
           ).status == 201

    before_write = authed_dav(context, "GET", path)
    assert authed_dav(context, "PUT", path, invalid).status == 403
    after_write = authed_dav(context, "GET", path)
    assert after_write.resp_body == before_write.resp_body
    assert get_resp_header(after_write, "etag") == get_resp_header(before_write, "etag")
  end

  test "GET PUT round trip retains normalized address labels and native geocoding",
       %{account_id: aid} = context do
    contact = ContactsFixtures.contact_fixture(aid)

    addresses =
      for label <- ["Business", "Personal", "CuStOm"] do
        ContactsFixtures.address_fixture(contact, %{
          "label" => label,
          "latitude" => 31.5,
          "longitude" => 35.2
        })
      end

    path = contact_path(contact)
    serialized = authed_dav(context, "GET", path).resp_body
    assert authed_dav(context, "PUT", path, serialized).status == 204
    retained = Kith.Repo.preload(contact, :addresses, force: true).addresses
    assert Enum.sort(Enum.map(retained, & &1.id)) == Enum.sort(Enum.map(addresses, & &1.id))
    assert Enum.all?(retained, &(&1.latitude == 31.5 and &1.longitude == 35.2))
  end

  for hidden <- [false, true] do
    @hidden_holder hidden
    test "UID mutation reports the actual #{if hidden, do: "hidden", else: "visible"} holder href",
         %{account_id: aid} = context do
      target = ContactsFixtures.contact_fixture(aid)
      holder = ContactsFixtures.contact_fixture(aid)
      target_path = contact_path(target)
      holder_path = contact_path(holder)
      holder = Kith.Repo.preload(holder, :dav)
      if @hidden_holder, do: Contacts.soft_delete_contact(holder)

      response =
        authed_dav(
          context,
          "PUT",
          target_path,
          build_vcard("Changed", "Name", uid: holder.dav.uid)
        )

      assert response.status == 409
      assert response.resp_body =~ "no-uid-conflict"
      assert response.resp_body =~ "<d:href>#{holder_path}</d:href>"
      refute response.resp_body =~ "<d:href>#{target_path}</d:href>"
    end
  end
end
