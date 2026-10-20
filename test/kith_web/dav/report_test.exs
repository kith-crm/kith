defmodule KithWeb.DAV.ReportTest do
  @moduledoc """
  RFC 6352 §8.7 — addressbook-multiget REPORT
  RFC 6578 §3  — sync-collection REPORT
  """
  use KithWeb.ConnCase, async: true

  import KithWeb.DAV.TestHelpers

  alias Kith.Contacts
  alias Kith.ContactsFixtures

  setup :setup_dav_user

  # ── RFC 6352 §8.7 — addressbook-multiget ────────────────────────────────

  describe "RFC 6352 §8.7 — addressbook-multiget REPORT" do
    test "MUST return 207 Multi-Status with response for each requested href",
         %{account_id: account_id} = context do
      c1 = ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})
      c2 = ContactsFixtures.contact_fixture(account_id, %{first_name: "Bob"})
      _c3 = ContactsFixtures.contact_fixture(account_id, %{first_name: "Charlie"})

      body = multiget_body([contact_path(c1), contact_path(c2)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert count_responses(conn.resp_body) == 2
    end

    test "MUST return address-data containing the vCard for each found resource",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{first_name: "Zara", last_name: "Quinn"})

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.resp_body =~ "address-data"
      assert conn.resp_body =~ "BEGIN:VCARD"
      assert conn.resp_body =~ "Zara"
      assert conn.resp_body =~ "Quinn"
    end

    test "MUST include BDAY property when contact has birthdate (RFC 2426 §3.1.5)",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Alice",
          birthdate: ~D[1990-06-15]
        })

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "BDAY:1990-06-15"
    end

    test "MUST include getetag in each response", %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.resp_body =~ "getetag"
    end

    test "MUST return 404 status for inaccessible/missing resources in multiget",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)
      missing = "/dav/addressbooks/default/kith-contact-999999.vcf"

      body = multiget_body([contact_path(contact), missing])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "404 Not Found"
    end
  end

  # ── RFC 6578 §3 — sync-collection ──────────────────────────────────────

  describe "RFC 6578 §3 — sync-collection REPORT" do
    test "MUST return 207 Multi-Status with all current members",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice"})
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Bob"})

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.status == 207
      assert conn.resp_body =~ "Alice"
      assert conn.resp_body =~ "Bob"
    end

    test "response MUST include sync-token that is a valid URI (RFC 6578 §4)",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.resp_body =~ "sync-token"

      [token] =
        Regex.run(~r/<d:sync-token>([^<]+)<\/d:sync-token>/, conn.resp_body,
          capture: :all_but_first
        )

      assert token =~ ~r{^https?://}
    end

    test "each member response MUST include getetag and address-data",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.resp_body =~ "getetag"
      assert conn.resp_body =~ "address-data"
      assert conn.resp_body =~ "BEGIN:VCARD"
    end

    test "MUST include BDAY property in sync-collection when contact has birthdate",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "BirthdaySync",
        birthdate: ~D[1985-12-25]
      })

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.status == 207
      assert conn.resp_body =~ "BirthdaySync"
      assert conn.resp_body =~ "BDAY:1985-12-25"
    end

    test "MUST NOT include deleted or archived members",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Active"})
      archived = ContactsFixtures.contact_fixture(account_id, %{first_name: "Archived"})
      deleted = ContactsFixtures.contact_fixture(account_id, %{first_name: "Deleted"})
      {:ok, _} = Contacts.archive_contact(archived)
      {:ok, _} = Contacts.soft_delete_contact(deleted)

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.resp_body =~ "Active"
      refute conn.resp_body =~ "kith-contact-#{archived.id}.vcf"
      refute conn.resp_body =~ "kith-contact-#{deleted.id}.vcf"
    end
  end

  # ── RFC 6578 §3 — incremental sync-collection ──────────────────────────

  describe "RFC 6578 §3 — incremental sync-collection" do
    test "sync with valid token returns only modified contacts",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Existing"})

      # Get initial sync token
      conn1 =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      [token] =
        Regex.run(~r/<d:sync-token>([^<]+)<\/d:sync-token>/, conn1.resp_body,
          capture: :all_but_first
        )

      # Wait and create a new contact
      Process.sleep(1100)
      ContactsFixtures.contact_fixture(account_id, %{first_name: "NewAfterSync"})

      # Incremental sync with the token
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:sync-token>#{token}</d:sync-token>
        <d:prop><d:getetag/><card:address-data/></d:prop>
      </d:sync-collection>
      """

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("REPORT", "/dav/addressbooks/default/", body)

      assert conn2.status == 207
      assert conn2.resp_body =~ "NewAfterSync"
      refute conn2.resp_body =~ "Existing"
    end

    test "sync reports deleted contacts with 404 status",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "ToDelete"})

      # Get initial sync token
      conn1 =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      [token] =
        Regex.run(~r/<d:sync-token>([^<]+)<\/d:sync-token>/, conn1.resp_body,
          capture: :all_but_first
        )

      # Wait and delete the contact
      Process.sleep(1100)
      {:ok, _} = Contacts.soft_delete_contact(contact)

      # Incremental sync
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:sync-token>#{token}</d:sync-token>
        <d:prop><d:getetag/><card:address-data/></d:prop>
      </d:sync-collection>
      """

      conn2 =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> dav_request("REPORT", "/dav/addressbooks/default/", body)

      assert conn2.status == 207
      assert conn2.resp_body =~ "kith-contact-#{contact.id}.vcf"
      assert conn2.resp_body =~ "404 Not Found"
    end
  end

  # ── RFC 6352 §8.6 — addressbook-query ──────────────────────────────────

  describe "RFC 6352 §8.6 — addressbook-query REPORT" do
    test "returns contacts matching FN filter",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Alice", last_name: "Smith"})
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Bob", last_name: "Jones"})

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:getetag/><card:address-data/></d:prop>
        <card:filter>
          <card:prop-filter name="FN">
            <card:text-match match-type="contains">Alice</card:text-match>
          </card:prop-filter>
        </card:filter>
      </card:addressbook-query>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "Alice"
      refute conn.resp_body =~ "Bob"
    end
  end

  # ── Invalid sync tokens ──────────────────────────────────────────────────

  describe "RFC 6578 §3 — invalid sync tokens" do
    test "garbage sync token falls back to full sync",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "FullSync"})

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:sync-token>not-a-valid-token-at-all</d:sync-token>
        <d:prop><d:getetag/><card:address-data/></d:prop>
      </d:sync-collection>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "FullSync"
    end

    test "out-of-range timestamp in sync token falls back to full sync",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "RangeTest"})

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:sync-token>https://kith.app/ns/sync/99999999999999999</d:sync-token>
        <d:prop><d:getetag/><card:address-data/></d:prop>
      </d:sync-collection>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "RangeTest"
    end
  end

  # ── RFC 6352 §8.3 — version negotiation in REPORT ──────────────────────

  describe "RFC 6352 §8.3 — version negotiation in REPORT" do
    test "multiget REPORT with version=4.0 returns vCard 4.0 bodies",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{first_name: "VersionTest"})

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:getetag/><card:address-data content-type="text/vcard" version="4.0"/></d:prop>
        <d:href>#{contact_path(contact)}</d:href>
      </card:addressbook-multiget>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
      assert conn.status == 207
      assert conn.resp_body =~ "VERSION:4.0"
      refute conn.resp_body =~ "VERSION:3.0"
    end

    test "multiget REPORT without version defaults to vCard 3.0",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207
      assert conn.resp_body =~ "VERSION:3.0"
    end

    test "sync-collection with version=4.0 returns vCard 4.0 bodies",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{first_name: "SyncV4"})

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
        <d:sync-token/>
        <d:prop>
          <d:getetag/>
          <card:address-data content-type="text/vcard" version="4.0"/>
        </d:prop>
      </d:sync-collection>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
      assert conn.status == 207
      assert conn.resp_body =~ "VERSION:4.0"
      assert conn.resp_body =~ "SyncV4"
    end
  end

  # ── Unsupported REPORT types ────────────────────────────────────────────

  describe "RFC 6352 — unsupported REPORT types" do
    # R24: RFC 3253 §3.6 DAV:supported-report precondition (was a plain 400)
    test "server MUST return 403 supported-report for unrecognized REPORT type", context do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:unknown-report xmlns:d="DAV:"/>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
      assert conn.status == 403
      assert conn.resp_body =~ "<d:supported-report/>"
    end
  end

  # ── CDATA wrapping — vCard byte preservation in XML responses ──────────

  describe "CDATA wrapping — vCard byte preservation" do
    test "multiget response wraps vCard in CDATA to preserve CRLF line endings",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id)

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.resp_body =~ "<![CDATA["
      assert conn.resp_body =~ "]]>"
      assert conn.resp_body =~ "BEGIN:VCARD\r\n"
    end

    test "sync-collection response wraps vCard in CDATA to preserve CRLF line endings",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id)

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.resp_body =~ "<![CDATA["
      assert conn.resp_body =~ "BEGIN:VCARD\r\n"
    end
  end

  # ── Thunderbird CardDAV sync flow — full property coverage ─────────────

  describe "Thunderbird CardDAV sync flow — full property coverage" do
    test "initial sync-collection returns all scalar properties",
         %{account_id: account_id} = context do
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Thunder",
        last_name: "Bird",
        nickname: "TB",
        birthdate: ~D[1990-06-15],
        company: "Mozilla",
        occupation: "Email Client"
      })

      conn =
        authed_dav(context, "REPORT", "/dav/addressbooks/default/", sync_collection_body())

      assert conn.status == 207
      assert conn.resp_body =~ "N:Bird;Thunder"
      assert conn.resp_body =~ "NICKNAME:TB"
      assert conn.resp_body =~ "BDAY:1990-06-15"
      assert conn.resp_body =~ "ORG:Mozilla"
      assert conn.resp_body =~ "TITLE:Email Client"
    end

    test "multiget returns complete vCard with BDAY inside CDATA",
         %{account_id: account_id} = context do
      contact =
        ContactsFixtures.contact_fixture(account_id, %{
          first_name: "Thunder",
          last_name: "Test",
          birthdate: ~D[2000-01-01]
        })

      body = multiget_body([contact_path(contact)])
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)

      assert conn.status == 207

      # Extract CDATA content and verify vCard integrity
      [cdata_content] =
        Regex.run(~r/<!\[CDATA\[(.*?)\]\]>/s, conn.resp_body, capture: :all_but_first)

      assert cdata_content =~ "BEGIN:VCARD"
      assert cdata_content =~ "BDAY:2000-01-01"
      assert cdata_content =~ "END:VCARD"
      # CRLF must be preserved for RFC 2426 compliance
      assert cdata_content =~ "\r\n"
    end
  end

  # ── CardDAV e2e regressions (Task 5) ────────────────────────────────────

  describe "CardDAV e2e regressions — REPORT" do
    test "CDV-41: multiget answers equivalent hrefs with the resource's own href; foreign paths are 404",
         %{account_id: account_id} = context do
      contact = ContactsFixtures.contact_fixture(account_id, %{first_name: "Hrefs"})
      path = contact_path(contact)
      encoded = String.replace(path, "kith-contact-", "kith%2Dcontact%2D")
      outside = String.replace(path, "/default/", "/other/")

      for href <- ["http://www.example.com" <> path, encoded] do
        conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", multiget_body([href]))
        assert conn.status == 207

        assert [^path] =
                 Regex.scan(~r{<d:href>([^<]+)</d:href>}, conn.resp_body, capture: :all_but_first)
                 |> List.flatten()

        assert conn.resp_body =~ "200 OK"
      end

      for href <- [outside, "/dav/" <> contact_uid(contact)] do
        conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", multiget_body([href]))
        assert conn.status == 207
        refute conn.resp_body =~ "200 OK", href
        assert conn.resp_body =~ "404 Not Found"
      end
    end

    test "CDV-39: a REPORT body over max-resource-size returns 413", context do
      padding = String.duplicate(" ", 1_048_577)

      body =
        ~s(<card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">) <>
          padding <> "</card:addressbook-multiget>"

      assert authed_dav(context, "REPORT", "/dav/addressbooks/default/", body).status == 413
    end

    test "CDV-40: REPORT is dispatched on its namespaced root element, any prefix",
         %{account_id: account_id} = context do
      named = ContactsFixtures.contact_fixture(account_id, %{first_name: "sync-collection"})
      other = ContactsFixtures.contact_fixture(account_id, %{first_name: "Other"})

      # A query whose text-match mentions another report is still a query
      query = """
      <C:addressbook-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <A:prop><A:getetag/></A:prop>
        <C:filter><C:prop-filter name="FN">
          <C:text-match>sync-collection</C:text-match>
        </C:prop-filter></C:filter>
      </C:addressbook-query>
      """

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", query)
      assert conn.status == 207
      refute conn.resp_body =~ "sync-token"
      assert conn.resp_body =~ contact_path(named)
      refute conn.resp_body =~ contact_path(other)

      # multiget with Apple's A: prefix for DAV: and with default namespaces
      for body <- [
            ~s(<B:addressbook-multiget xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:carddav">) <>
              ~s(<A:prop><A:getetag/><B:address-data/></A:prop>) <>
              ~s(<A:href>#{contact_path(named)}</A:href></B:addressbook-multiget>),
            ~s(<addressbook-multiget xmlns="urn:ietf:params:xml:ns:carddav">) <>
              ~s(<prop xmlns="DAV:"><getetag/></prop>) <>
              ~s(<href xmlns="DAV:">#{contact_path(named)}</href></addressbook-multiget>)
          ] do
        conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
        assert conn.status == 207
        assert count_responses(conn.resp_body) == 1
        assert conn.resp_body =~ contact_path(named)
        assert conn.resp_body =~ "200 OK"
      end

      # a multiget href that only looks like DAV:href is not one
      fake =
        ~s(<card:addressbook-multiget xmlns:d="urn:not-dav" xmlns:card="urn:ietf:params:xml:ns:carddav">) <>
          ~s(<d:href>#{contact_path(named)}</d:href></card:addressbook-multiget>)

      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", fake)
      assert conn.status == 207
      assert count_responses(conn.resp_body) == 0
    end

    test "CDV-40: an unknown REPORT is 403 supported-report; malformed XML is 400", context do
      unknown = ~s(<?xml version="1.0"?><d:unknown-report xmlns:d="DAV:"/>)
      conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", unknown)
      assert conn.status == 403
      assert conn.resp_body =~ "supported-report"

      # right local name, wrong namespace
      wrong_ns = ~s(<x:sync-collection xmlns:x="urn:x"><x:sync-token/></x:sync-collection>)
      assert authed_dav(context, "REPORT", "/dav/addressbooks/default/", wrong_ns).status == 403

      for body <- [
            ~s(<card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:href>x</d:prop>),
            "",
            "hello"
          ] do
        conn = authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
        assert conn.status == 400, inspect(body)
      end
    end
  end
end
