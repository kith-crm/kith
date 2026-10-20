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
        authed_dav(context, "PUT", "/dav/addressbooks/default/new-999999.vcf", vcard)

      assert conn.status == 201
    end

    test "response MUST include ETag header on creation (RFC 6352 §5.1)", context do
      vcard = build_vcard("New", "Contact")

      conn =
        authed_dav(context, "PUT", "/dav/addressbooks/default/new-999999.vcf", vcard)

      assert conn.status == 201
      assert get_resp_header(conn, "etag") != []
    end

    test "created resource MUST be retrievable via GET", context do
      vcard = build_vcard("Created", "ViaDAV", nickname: "Davy")

      conn1 =
        authed_dav(context, "PUT", "/dav/addressbooks/default/new-999999.vcf", vcard)

      assert conn1.status == 201

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      [[_, id_str]] = Regex.scan(~r{new-(\d+)\.vcf}, conn2.resp_body)

      conn3 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", "/dav/addressbooks/default/new-#{id_str}.vcf")

      assert conn3.status == 200
      assert conn3.resp_body =~ "Created"
      assert conn3.resp_body =~ "ViaDAV"
    end

    test "server MUST reject vCard missing required properties (first_name)", context do
      invalid = "BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE:no name\r\nEND:VCARD\r\n"

      conn =
        authed_dav(context, "PUT", "/dav/addressbooks/default/new-999999.vcf", invalid)

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

    test "response MUST include updated ETag header (RFC 6352 §5.1)",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      vcard = build_vcard("Updated", "Contact")

      conn = authed_dav(context, "PUT", contact_path(contact), vcard)

      assert get_resp_header(conn, "etag") != []
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
      [etag_after] = get_resp_header(conn2, "etag")

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
        |> dav_request("PUT", "/dav/addressbooks/default/new-999999.vcf", vcard)

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

      # R2: the resource is served at the href the client chose
      conn_get =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("GET", path)

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

    test "PUT with invalid vCard body returns 422 with precondition error", context do
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

      assert conn.status == 422
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
          "/dav/addressbooks/default/new-999999.vcf",
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
          ~r{<d:href>(/dav/addressbooks/default/new-\d+\.vcf)</d:href>},
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
          "/dav/addressbooks/default/new-999999.vcf",
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
          ~r{<d:href>(/dav/addressbooks/default/new-\d+\.vcf)</d:href>},
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
          "/dav/addressbooks/default/new-999999.vcf",
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
          ~r{<d:href>(/dav/addressbooks/default/new-\d+\.vcf)</d:href>},
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
          "/dav/addressbooks/default/new-999999.vcf",
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
          ~r{<d:href>(/dav/addressbooks/default/new-\d+\.vcf)</d:href>},
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
          "/dav/addressbooks/default/new-999999.vcf",
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
          ~r{<d:href>(/dav/addressbooks/default/new-\d+\.vcf)</d:href>},
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
  # CardDAV e2e regressions — address-object CRUD (Task 4)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "CDV-12: client-chosen resource names (R2)" do
    test "CDV-12: a PUT to <uuid>.vcf is served at that href and keeps its UID",
         %{account_id: account_id} = context do
      uuid = "6F1C2B0A-3D4E-4F50-8A9B-0C1D2E3F4A5B"
      href = "/dav/addressbooks/default/#{uuid}.vcf"

      put1 = authed_dav(context, "PUT", href, build_vcard("Ada", "Uuid", uid: uuid))
      assert put1.status == 201
      [etag] = get_resp_header(put1, "etag")

      get = authed_dav(context, "GET", href)
      assert get.status == 200
      assert get.resp_body =~ "UID:#{uuid}\r\n"
      assert get_resp_header(get, "etag") == [etag]

      listing =
        context
        |> Map.put(:conn, put_req_header(build_conn(), "depth", "1"))
        |> authed_dav("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert listing.resp_body =~ "<d:href>#{href}</d:href>"

      count = Contacts.count_contacts(account_id)
      put2 = authed_dav(context, "PUT", href, build_vcard("Ada", "Edited", uid: uuid))
      assert put2.status == 204
      assert Contacts.count_contacts(account_id) == count
      assert authed_dav(context, "GET", href).resp_body =~ "Edited"

      multiget =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", multiget_body([href]))

      assert multiget.resp_body =~ "<d:href>#{href}</d:href>"
      assert multiget.resp_body =~ "Edited"

      sync = authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())
      assert sync.resp_body =~ "<d:href>#{href}</d:href>"

      assert authed_dav(context, "DELETE", href).status == 204
      assert authed_dav(context, "GET", href).status == 404

      old_token = "https://kith.app/ns/sync/#{DateTime.to_unix(DateTime.utc_now()) - 60}"

      sync_body =
        String.replace(
          sync_collection_body(),
          "<d:sync-token/>",
          "<d:sync-token>#{old_token}</d:sync-token>"
        )

      deleted = authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_body)
      assert deleted.resp_body =~ "<d:href>#{href}</d:href>"
    end

    test "CDV-12: a client name with a space is percent-encoded in hrefs", context do
      href = "/dav/addressbooks/default/a%20b.vcf"
      assert authed_dav(context, "PUT", href, build_vcard("Space", "Name")).status == 201
      assert authed_dav(context, "GET", href).status == 200

      listing =
        context
        |> Map.put(:conn, put_req_header(build_conn(), "depth", "1"))
        |> authed_dav("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      assert listing.resp_body =~ "<d:href>#{href}</d:href>"
    end

    test "CDV-12: a UI contact keeps its kith-contact-N href and UID",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      get = authed_dav(context, "GET", contact_path(contact))
      assert get.status == 200
      assert get.resp_body =~ "UID:kith-contact-#{contact.id}\r\n"
    end
  end

  describe "CDV-13: unsafe resource names" do
    test "CDV-13: dot segments, encoded slashes, control characters and bad escapes are refused",
         %{account_id: account_id} = context do
      long = String.duplicate("a", 252) <> ".vcf"

      for segment <-
            ["..", "%2E%2E", ".", "a%2Fb.vcf", "a%5Cb.vcf", "a%00b.vcf", "a%0Ab.vcf"] ++
              ["%ZZ.vcf", "%FF.vcf", long] do
        path = "/dav/addressbooks/default/" <> segment
        put = authed_dav(context, "PUT", path, build_vcard("Evil", "Name"))
        assert put.status in 400..499, "PUT #{segment} -> #{put.status}"

        get = build_conn() |> basic_auth(context.user.email, dav_password())
        assert dav_request(get, "GET", path).status in 400..499
      end

      assert Contacts.count_contacts(account_id) == 0
    end
  end

  describe "CDV-14: If-Match lists and weak tags" do
    test "CDV-14: an If-Match list matches any strong tag; W/ tags and non-members fail",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Kay"})
      [etag] = authed_dav(context, "GET", contact_path(contact)) |> get_resp_header("etag")

      put = fn if_match, first ->
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-match", if_match)
        |> dav_request("PUT", contact_path(contact), build_vcard(first, "List"))
      end

      assert put.("W/#{etag}", "Weak").status == 412
      assert put.(~s("a", "b"), "None").status == 412
      assert put.(~s("a", #{etag}), "Listed").status == 204
      assert Contacts.get_contact(account_id, contact.id).first_name == "Listed"
    end
  end

  describe "CDV-15: If-Match on a missing resource" do
    test "CDV-15: PUT with If-Match to a missing href is 412 and creates nothing",
         %{account_id: account_id} = context do
      for if_match <- [~s("whatever"), "*"] do
        conn =
          build_conn()
          |> basic_auth(context.user.email, dav_password())
          |> put_req_header("if-match", if_match)
          |> dav_request(
            "PUT",
            "/dav/addressbooks/default/missing.vcf",
            build_vcard("No", "Body")
          )

        assert conn.status == 412
      end

      assert Contacts.count_contacts(account_id) == 0
    end
  end

  describe "CDV-16: GET with If-None-Match" do
    test "CDV-16: GET with a matching If-None-Match is 304 with the ETag and no body",
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

  describe "CDV-17: same-second ETags (R4)" do
    test "CDV-17: a create and two edits inside one second give three distinct ETags",
         context do
      href = "/dav/addressbooks/default/same-second.vcf"
      put = fn vcard -> authed_dav(context, "PUT", href, vcard) end

      c = put.(build_vcard("Same", "Second", phone: "+15550000001"))
      e1 = put.(build_vcard("Same", "Edited", phone: "+15550000001"))
      # Only a child (TEL) changes here, no scalar field.
      e2 = put.(build_vcard("Same", "Edited", phone: "+15550000002"))
      assert [c.status, e1.status, e2.status] == [201, 204, 204]

      etags = Enum.flat_map([c, e1, e2], &get_resp_header(&1, "etag"))
      assert length(Enum.uniq(etags)) == 3
      assert get_resp_header(authed_dav(context, "GET", href), "etag") == [List.last(etags)]
    end

    test "CDV-17: touch_contact!/1 always yields a new ETag revision",
         %{account_id: account_id} do
      contact = ContactsFixtures.contact_fixture(account_id)
      t1 = Contacts.touch_contact!(contact)
      t2 = Contacts.touch_contact!(t1)
      assert t1.dav_revision != contact.dav_revision
      assert t2.dav_revision != t1.dav_revision
    end
  end

  describe "CDV-18: PUT to a trashed contact's href (R18)" do
    defp all_rows(account_id) do
      import Ecto.Query
      Kith.Repo.all(from c in Kith.Contacts.Contact, where: c.account_id == ^account_id)
    end

    test "CDV-18: a client-named trashed contact is restored in place, not duplicated",
         %{account_id: account_id} = context do
      href = "/dav/addressbooks/default/trashed-uuid.vcf"

      assert authed_dav(context, "PUT", href, build_vcard("Tr", "Ashed", uid: "trashed-uuid")).status ==
               201

      [%{id: id}] = all_rows(account_id)
      assert authed_dav(context, "DELETE", href).status == 204

      conn =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("if-none-match", "*")
        |> dav_request("PUT", href, build_vcard("Tr", "Back", uid: "trashed-uuid"))

      assert conn.status == 201
      assert [%{id: ^id, deleted_at: nil, last_name: "Back"}] = all_rows(account_id)
      assert authed_dav(context, "GET", href).resp_body =~ "UID:trashed-uuid\r\n"
    end

    test "CDV-18: a trashed UI contact PUT at kith-contact-N.vcf is restored in place",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      {:ok, _} = Contacts.soft_delete_contact(contact)

      conn = authed_dav(context, "PUT", contact_path(contact), build_vcard("Ui", "Back"))
      assert conn.status == 201
      assert [%{id: id, deleted_at: nil, last_name: "Back"}] = all_rows(account_id)
      assert id == contact.id
      assert authed_dav(context, "GET", contact_path(contact)).status == 200
    end
  end

  describe "CDV-19: legacy text/x-vcard" do
    defp put_with_type(context, path, content_type, body) do
      build_conn()
      |> basic_auth(context.user.email, dav_password())
      |> put_req_header("content-type", content_type)
      |> dispatch(KithWeb.Endpoint, "PUT", path, body)
    end

    test "CDV-19: PUT with text/x-vcard is accepted; application/json is 415", context do
      vcard = build_vcard("Legacy", "Type")

      assert put_with_type(context, "/dav/addressbooks/default/x1.vcf", "text/x-vcard", vcard).status ==
               201

      assert put_with_type(
               context,
               "/dav/addressbooks/default/x2.vcf",
               "Text/X-VCard; charset=utf-8",
               vcard
             ).status == 201

      assert put_with_type(
               context,
               "/dav/addressbooks/default/x3.vcf",
               "application/json",
               ~s({"fn": "Json"})
             ).status ==
               415
    end
  end

  describe "CDV-20: PUT body size (R8)" do
    test "CDV-20: a PUT body over max-resource-size is 413 and creates nothing",
         %{account_id: account_id} = context do
      for size <- [1_048_577, 9 * 1024 * 1024] do
        big = build_vcard("Big", "Body", note: String.duplicate("x", size))
        conn = authed_dav(context, "PUT", "/dav/addressbooks/default/big-#{size}.vcf", big)
        assert conn.status == 413
      end

      assert Contacts.count_contacts(account_id) == 0
    end
  end

  describe "CDV-21: unstorable vCard data" do
    defp card(lines),
      do: Enum.join(["BEGIN:VCARD", "VERSION:3.0" | lines] ++ ["END:VCARD", ""], "\r\n")

    test "CDV-21: values too long to store are a 4xx valid-address-data and create nothing",
         %{account_id: account_id} = context do
      long = String.duplicate("9", 400)

      for {lines, i} <-
            Enum.with_index([
              ["N:Long;Tel;;;", "FN:Tel Long", "TEL:#{long}"],
              ["N:Long;Adr;;;", "FN:Adr Long", "ADR:;;#{long};City;;;"],
              ["N:Long;#{long};;;", "FN:Name Long"],
              ["N:Bad;Utf;;;", "FN:Bad Utf", "EMAIL:a\xFFb@example.com"]
            ]) do
        conn = authed_dav(context, "PUT", "/dav/addressbooks/default/long-#{i}.vcf", card(lines))
        assert conn.status in 400..499, "case #{i} -> #{conn.status}"
        assert conn.resp_body =~ "valid-address-data"
      end

      assert Contacts.count_contacts(account_id) == 0
    end

    test "CDV-21: a rejected update leaves the contact and its children unchanged",
         %{account_id: account_id} = context do
      href = "/dav/addressbooks/default/keep.vcf"
      ok = card(["N:Keep;Kim;;;", "FN:Kim Keep", "TEL:+15550001111"])
      assert authed_dav(context, "PUT", href, ok).status == 201

      bad = card(["N:Changed;Kim;;;", "FN:Kim Changed", "TEL:#{String.duplicate("9", 400)}"])
      assert authed_dav(context, "PUT", href, bad).status in 400..499

      body = authed_dav(context, "GET", href).resp_body
      assert body =~ "N:Keep;Kim"
      assert body =~ "+15550001111"
      assert Contacts.count_contacts(account_id) == 1
    end

    test "CDV-21: an empty EMAIL or TEL value is skipped, not a 500", context do
      href = "/dav/addressbooks/default/empty.vcf"
      vcard = card(["N:Empty;Em;;;", "FN:Em Empty", "EMAIL;TYPE=INTERNET:", "TEL:"])
      assert authed_dav(context, "PUT", href, vcard).status == 201
      assert authed_dav(context, "GET", href).resp_body =~ "FN:Em Empty"
    end
  end

  describe "CDV-22: DELETE or PUT on a collection" do
    test "CDV-22: DELETE and PUT on the collections are 405 with Allow and delete nothing",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      for path <- [
            "/dav/addressbooks/default/",
            "/dav/addressbooks/",
            "/dav/principals/",
            "/dav/"
          ],
          method <- ["DELETE", "PUT"] do
        conn =
          build_conn()
          |> basic_auth(context.user.email, dav_password())
          |> dav_request(method, path, build_vcard("Col", "Lection"))

        assert conn.status == 405, "#{method} #{path} -> #{conn.status}"
        [allow] = get_resp_header(conn, "allow")
        assert allow =~ "PROPFIND"
        refute allow =~ method
      end

      assert Contacts.count_contacts(account_id) == 1
    end
  end

  describe "CDV-23: chunked bodies and max-resource-size (R8)" do
    # Bandit reads a `Transfer-Encoding: chunked` body whole and ignores
    # read_body's `:length`; this adapter does the same.
    defmodule ChunkedAdapter do
      @moduledoc false
      @behaviour Plug.Conn.Adapter
      alias Plug.Adapters.Test.Conn, as: T

      @impl true
      def read_req_body(%{req_body: body} = state, _opts),
        do: {:ok, body, %{state | req_body: ""}}

      @impl true
      defdelegate send_resp(s, st, h, b), to: T
      @impl true
      defdelegate send_file(s, st, h, p, o, l), to: T
      @impl true
      defdelegate send_chunked(s, st, h), to: T
      @impl true
      defdelegate chunk(s, b), to: T
      @impl true
      defdelegate inform(s, st, h), to: T
      @impl true
      defdelegate upgrade(s, p, o), to: T
      @impl true
      defdelegate push(s, p, h), to: T
      @impl true
      defdelegate get_peer_data(s), to: T
      @impl true
      defdelegate get_sock_data(s), to: T
      @impl true
      defdelegate get_ssl_data(s), to: T
      @impl true
      defdelegate get_http_protocol(s), to: T
    end

    defp chunked(context, method, path, content_type, body) do
      conn = build_conn(method, path, body)
      {_, state} = conn.adapter

      %{conn | adapter: {ChunkedAdapter, state}}
      |> basic_auth(context.user.email, dav_password())
      |> put_req_header("content-type", content_type)
      |> put_req_header("depth", "0")
      |> KithWeb.Endpoint.call([])
    end

    test "CDV-23: a chunked PUT or PROPFIND body over max-resource-size is 413",
         %{account_id: account_id} = context do
      note = String.duplicate("x", 2 * 1024 * 1024)
      vcard = build_vcard("Chunked", "Big", note: note)
      put = chunked(context, :put, "/dav/addressbooks/default/chunked.vcf", "text/vcard", vcard)
      assert put.status == 413
      assert Contacts.count_contacts(account_id) == 0

      xml = ~s(<d:propfind xmlns:d="DAV:"><!--#{note}--><d:allprop/></d:propfind>)
      assert chunked(context, :propfind, "/dav/", "application/xml", xml).status == 413
    end
  end

  describe "CDV-26: client-held kith-contact-N names cannot shadow (R20)" do
    defp last_contact_id do
      [[v]] = Ecto.Adapters.SQL.query!(Kith.Repo, "SELECT last_value FROM contacts_id_seq").rows
      v
    end

    # R20 as revised by CDV-32: the client name is stored; contact N, inserted
    # later by any path (here a raw insert with an explicit id), gets
    # `kith-contact-N-k.vcf` from the insert trigger instead of shadowing.
    test "CDV-26: a PUT-create at a future kith-contact-N.vcf cannot shadow contact N",
         %{account_id: account_id} = context do
      n = last_contact_id() + 10_000_000
      href = "/dav/addressbooks/default/kith-contact-#{n}.vcf"

      put =
        authed_dav(context, "PUT", href, build_vcard("Client", "Named", uid: "kith-contact-#{n}"))

      assert put.status == 201

      Kith.Repo.insert!(%Kith.Contacts.Contact{id: n, account_id: account_id, first_name: "Ui"})
      assert authed_dav(context, "GET", href).resp_body =~ "FN:Client Named\r\n"

      alt = authed_dav(context, "GET", "/dav/addressbooks/default/kith-contact-#{n}-k.vcf")
      assert alt.status == 200
      assert alt.resp_body =~ "FN:Ui\r\n"
      assert Contacts.count_contacts(account_id) == 2
    end

    test "CDV-26: an already-issued kith-contact-N.vcf name (another account's id) is accepted",
         %{account_id: account_id} = context do
      other = ContactsFixtures.contact_fixture(Kith.AccountsFixtures.user_fixture().account.id)
      href = "/dav/addressbooks/default/kith-contact-#{other.id}.vcf"
      assert authed_dav(context, "PUT", href, build_vcard("Copied", "Card")).status == 201
      assert authed_dav(context, "GET", href).resp_body =~ "Copied"
      assert Contacts.count_contacts(account_id) == 1
    end
  end

  describe "CDV-27: archived contacts are hidden from DAV (R5, R21)" do
    test "CDV-27: GET, PROPFIND, multiget and DELETE treat an archived contact as missing",
         %{account_id: account_id} = context do
      ui = ContactsFixtures.contact_fixture(account_id)
      {:ok, _} = Contacts.archive_contact(ui)

      href = "/dav/addressbooks/default/archived.vcf"
      assert authed_dav(context, "PUT", href, build_vcard("Arch", "Ived")).status == 201

      {:ok, _} =
        Contacts.archive_contact(Contacts.get_contact_by_dav_name(account_id, "archived.vcf"))

      for path <- [contact_path(ui), href] do
        assert authed_dav(context, "GET", path).status == 404

        propfind = build_conn() |> basic_auth(context.user.email, dav_password())
        assert dav_request(propfind, "PROPFIND", path, propfind_body()).status == 404

        multiget = build_conn() |> basic_auth(context.user.email, dav_password())

        body =
          dav_request(multiget, "REPORT", "/dav/addressbooks/default/", multiget_body([path])).resp_body

        assert body =~ "404 Not Found"
        refute body =~ "BEGIN:VCARD"

        delete = build_conn() |> basic_auth(context.user.email, dav_password())
        assert dav_request(delete, "DELETE", path).status == 404
      end

      assert Contacts.list_archived_contacts(account_id) |> length() == 2
    end

    test "CDV-27: a PUT to an archived contact's href unarchives and overwrites it in place",
         %{account_id: account_id} = context do
      ui = ContactsFixtures.contact_fixture(account_id)
      {:ok, _} = Contacts.archive_contact(ui)

      conn = authed_dav(context, "PUT", contact_path(ui), build_vcard("Back", "Again"))
      assert conn.status == 201
      contact = Contacts.get_contact(account_id, ui.id)
      assert %{is_archived: false, first_name: "Back"} = contact
      assert Contacts.count_contacts(account_id) == 1
    end
  end

  describe "CDV-28: no-uid-conflict (RFC 6352 §6.3.2.1)" do
    test "CDV-28: a create whose UID is already used by another href is 409 no-uid-conflict",
         %{account_id: account_id} = context do
      a = "/dav/addressbooks/default/uid-a.vcf"

      assert authed_dav(context, "PUT", a, build_vcard("Uid", "One", uid: "shared-uid")).status ==
               201

      dup =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/uid-b.vcf",
          build_vcard("Uid", "Two", uid: "shared-uid")
        )

      assert dup.status == 409
      assert dup.resp_body =~ "<card:no-uid-conflict><d:href>#{a}</d:href></card:no-uid-conflict>"

      ui = ContactsFixtures.contact_fixture(account_id)

      for uid <- ["kith-contact-#{ui.id}", "urn:uuid:kith-contact-#{ui.id}"] do
        conn =
          authed_dav(
            context,
            "PUT",
            "/dav/addressbooks/default/uid-c.vcf",
            build_vcard("Uid", "Three", uid: uid)
          )

        assert conn.status == 409
        assert conn.resp_body =~ "<d:href>#{contact_path(ui)}</d:href>"
      end

      assert Contacts.count_contacts(account_id) == 2
    end

    test "CDV-28: re-PUTting the same href with its own UID is not a conflict", context do
      a = "/dav/addressbooks/default/uid-self.vcf"

      assert authed_dav(context, "PUT", a, build_vcard("Self", "One", uid: "self-uid")).status ==
               201

      assert authed_dav(context, "PUT", a, build_vcard("Self", "Two", uid: "self-uid")).status ==
               204
    end
  end

  describe "CDV-29: chunked request bodies on DAV paths" do
    test "CDV-29: a chunked request to /dav or /.well-known/carddav is 411 before any body read",
         %{account_id: account_id} = context do
      for {method, path} <- [
            {"PUT", "/dav/addressbooks/default/chunk.vcf"},
            {"PROPFIND", "/dav/"},
            {"PROPFIND", "/.well-known/carddav"}
          ] do
        conn =
          build_conn()
          |> basic_auth(context.user.email, dav_password())
          |> put_req_header("transfer-encoding", "chunked")
          |> dav_request(method, path, build_vcard("Chunk", "Ed"))

        assert conn.status == 411, "#{method} #{path} -> #{conn.status}"
        assert get_resp_header(conn, "connection") == ["close"]
      end

      assert Contacts.count_contacts(account_id) == 0
    end
  end

  describe "CDV-34: only the canonical kith-contact-N name resolves" do
    test "CDV-34: kith-contact-0N.vcf does not alias contact N; it is an ordinary client name",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Canon"})
      alias_href = "/dav/addressbooks/default/kith-contact-0#{contact.id}.vcf"

      assert authed_dav(context, "GET", alias_href).status == 404
      assert authed_dav(context, "DELETE", alias_href).status == 404

      put = authed_dav(context, "PUT", alias_href, build_vcard("Zero", "Padded"))
      assert put.status == 201
      assert Contacts.get_contact(account_id, contact.id).first_name == "Canon"
      assert Contacts.count_contacts(account_id) == 2

      dup =
        authed_dav(
          context,
          "PUT",
          "/dav/addressbooks/default/zero-uid.vcf",
          build_vcard("Zero", "Uid", uid: "kith-contact-0#{contact.id}")
        )

      assert dup.status == 201
    end
  end

  describe "CDV-35: no-uid-conflict on restore/unarchive" do
    test "CDV-35: a PUT that would restore a trashed or archived contact whose UID is now taken is 409",
         %{account_id: account_id} = context do
      a = "/dav/addressbooks/default/restore-a.vcf"
      b = "/dav/addressbooks/default/restore-b.vcf"
      assert authed_dav(context, "PUT", a, build_vcard("Re", "A", uid: "taken-uid")).status == 201
      assert authed_dav(context, "DELETE", a).status == 204
      assert authed_dav(context, "PUT", b, build_vcard("Re", "B", uid: "taken-uid")).status == 201

      restore = authed_dav(context, "PUT", a, build_vcard("Re", "A2", uid: "taken-uid"))
      assert restore.status == 409

      assert restore.resp_body =~
               "<card:no-uid-conflict><d:href>#{b}</d:href></card:no-uid-conflict>"

      assert authed_dav(context, "GET", a).status == 404

      c = "/dav/addressbooks/default/restore-c.vcf"
      assert authed_dav(context, "PUT", c, build_vcard("Re", "C", uid: "c-uid")).status == 201
      archived = Contacts.get_contact_by_dav_name(account_id, "restore-c.vcf")
      {:ok, _} = Contacts.archive_contact(archived)

      assert authed_dav(
               context,
               "PUT",
               "/dav/addressbooks/default/restore-d.vcf",
               build_vcard("Re", "D", uid: "c-uid")
             ).status == 201

      unarchive = authed_dav(context, "PUT", c, build_vcard("Re", "C2", uid: "c-uid"))
      assert unarchive.status == 409
      assert Contacts.get_contact(account_id, archived.id).is_archived
    end
  end

  describe "CDV-36: one visible contact per UID" do
    test "CDV-36: restoring from the UI a contact whose UID is now taken keeps one holder",
         %{account_id: account_id} = context do
      a = "/dav/addressbooks/default/ui-restore-a.vcf"
      assert authed_dav(context, "PUT", a, build_vcard("Ui", "A", uid: "ui-uid")).status == 201
      trashed = Contacts.get_contact_by_dav_name(account_id, "ui-restore-a.vcf")
      {:ok, _} = Contacts.soft_delete_contact(trashed)

      assert authed_dav(
               context,
               "PUT",
               "/dav/addressbooks/default/ui-restore-b.vcf",
               build_vcard("Ui", "B", uid: "ui-uid")
             ).status == 201

      assert {:ok, restored} = Contacts.restore_contact(Kith.Repo.reload!(trashed))
      assert restored.dav_uid == nil
      assert authed_dav(context, "GET", a).resp_body =~ "UID:kith-contact-#{trashed.id}\r\n"
    end
  end

  describe "CDV-37: an early 413 leaves the connection readable" do
    defp unread(conn) do
      {Plug.Adapters.Test.Conn, %{req_body: rest}} = conn.adapter
      byte_size(rest)
    end

    test "CDV-37: the rest of an oversized body is drained before the 413; past the bound the connection closes",
         context do
      drainable = build_vcard("Big", "Body", note: String.duplicate("x", 2_000_000))
      conn = authed_dav(context, "PUT", "/dav/addressbooks/default/drain.vcf", drainable)
      assert conn.status == 413
      assert unread(conn) == 0
      assert get_resp_header(conn, "connection") == []

      huge = build_vcard("Huge", "Body", note: String.duplicate("x", 20 * 1_048_576))
      conn = authed_dav(context, "PUT", "/dav/addressbooks/default/huge.vcf", huge)
      assert conn.status == 413
      assert get_resp_header(conn, "connection") == ["close"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════════════

  # Creates a contact via PUT and returns {href, conn} for the created resource.
  # R2: the server keeps the client-chosen href, so href is the PUT path.
  defp put_and_find(context, vcard) do
    path = "/dav/addressbooks/default/kith-contact-new-#{System.unique_integer([:positive])}.vcf"
    conn = authed_dav(context, "PUT", path, vcard)
    assert conn.status == 201

    conn_list =
      build_conn()
      |> basic_auth(context.user.email, dav_password())
      |> put_req_header("depth", "1")
      |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

    assert conn_list.resp_body =~ "<d:href>#{path}</d:href>"

    {path, conn}
  end
end
