defmodule KithWeb.DAV.PrincipalReportsTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import KithWeb.DAV.TestHelpers

  alias Kith.DAV.{AccessControl, XMLParser}
  alias Kith.Repo

  setup do
    admin = named_user("Alice Example", "admin")
    editor = named_user("Bob Example", "editor", admin.account_id)
    viewer = named_user("Bobby Elsewhere", "viewer", admin.account_id)
    outsider = named_user("Bob Example Foreign", "admin")
    %{admin: admin, editor: editor, viewer: viewer, outsider: outsider}
  end

  test "ACL principal property set exposes only protected account role principals", c do
    body =
      report("acl-principal-prop-set", "<d:prop><d:displayname/><d:group-member-set/></d:prop>")

    for user <- [c.admin, c.editor, c.viewer] do
      conn = request(user, "/dav/addressbooks/default/", body)
      assert conn.status == 207

      assert top_hrefs(conn.resp_body) ==
               Enum.map(~w(admin editor viewer), &AccessControl.role_href/1)

      assert conn.resp_body =~ AccessControl.principal_href(c.editor)
      refute conn.resp_body =~ AccessControl.principal_href(c.outsider)
    end
  end

  test "principal-match self selects the authenticated real user and containing role", c do
    body = report("principal-match", "<d:self/><d:prop><d:displayname/></d:prop>")

    for user <- [c.admin, c.editor, c.viewer] do
      conn = request(user, "/dav/principals/users/", body)
      assert conn.status == 207
      assert top_hrefs(conn.resp_body) == [AccessControl.principal_href(user)]
      refute conn.resp_body =~ AccessControl.principal_href(c.outsider)

      groups = request(user, "/dav/principals/roles/", body)
      assert groups.status == 207
      assert top_hrefs(groups.resp_body) == [AccessControl.role_href(user.role)]
    end
  end

  test "principal-property matching uses owner membership for existing account resources", c do
    contact = contact_fixture(c.admin.account_id)
    foreign = contact_fixture(c.outsider.account_id)

    body =
      report("principal-match", """
      <d:principal-property><d:owner/></d:principal-property>
      <d:prop><d:getetag/></d:prop>
      """)

    conn = request(c.admin, "/dav/addressbooks/default/", body)
    assert conn.status == 207
    assert top_hrefs(conn.resp_body) == [contact_path(contact)]
    refute conn.resp_body =~ contact_path(foreign)

    for user <- [c.editor, c.viewer] do
      conn = request(user, "/dav/addressbooks/default/", body)
      assert conn.status == 207
      assert top_hrefs(conn.resp_body) == []
    end
  end

  test "principal searches AND criteria case-insensitively without leaking other accounts", c do
    body =
      report("principal-property-search", """
      <d:property-search><d:prop><d:displayname/></d:prop><d:match>EXAMPLE</d:match></d:property-search>
      <d:property-search><d:prop><d:displayname/></d:prop><d:match>bOb</d:match></d:property-search>
      <d:prop><d:displayname/><d:principal-URL/></d:prop>
      """)

    for user <- [c.admin, c.editor, c.viewer] do
      conn = request(user, "/dav/principals/users/", body)
      assert conn.status == 207
      assert top_hrefs(conn.resp_body) == [AccessControl.principal_href(c.editor)]
      assert conn.resp_body =~ "Bob Example"
      refute conn.resp_body =~ "Bobby Elsewhere"
      refute conn.resp_body =~ "Bob Example Foreign"
    end

    conn = request(c.viewer, "/dav/addressbooks/default/", body)
    assert conn.status == 207
    assert top_hrefs(conn.resp_body) == []

    all_collections =
      String.replace(
        body,
        "</d:principal-property-search>",
        "<d:apply-to-principal-collection-set/></d:principal-property-search>"
      )

    conn = request(c.viewer, "/dav/addressbooks/default/", all_collections)
    assert conn.status == 207
    assert top_hrefs(conn.resp_body) == [AccessControl.principal_href(c.editor)]
  end

  test "search property discovery is a DAV document only at principal collections", c do
    body = report("principal-search-property-set", "")

    for path <- ["/dav/principals/users/", "/dav/principals/roles/"] do
      conn = request(c.viewer, path, body)
      assert conn.status == 200
      assert %{ns: "DAV:", name: "principal-search-property-set"} = tree(conn.resp_body)
      assert conn.resp_body =~ "displayname"
    end

    contact = contact_fixture(c.admin.account_id)

    for path <- [
          "/dav/",
          "/dav/addressbooks/default/",
          AccessControl.principal_href(c.viewer),
          contact_path(contact)
        ] do
      conn = request(c.viewer, path, body)
      assert conn.status == 403
      assert %{ns: "DAV:", name: "error"} = tree(conn.resp_body)
      assert conn.resp_body =~ "supported-report"

      props = propfind(c.viewer, path, "<d:supported-report-set/>")
      assert props.status == 207
      refute props.resp_body =~ "<d:principal-search-property-set/>"
    end
  end

  test "the four ACL reports accept Depth zero and reject Depth one", c do
    reports = [
      report("acl-principal-prop-set", "<d:prop><d:displayname/></d:prop>"),
      report("principal-match", "<d:self/>"),
      report(
        "principal-property-search",
        "<d:property-search><d:prop><d:displayname/></d:prop><d:match>Alice</d:match></d:property-search>"
      ),
      report("principal-search-property-set", "")
    ]

    for body <- reports do
      conn = request(c.admin, "/dav/principals/users/", body, "0")
      assert conn.status in [200, 207]
      rejected = request(c.admin, "/dav/principals/users/", body, "1")
      assert rejected.status == 400
    end
  end

  test "expand-property follows current principal and home references in one account", c do
    body =
      report("expand-property", """
      <d:property name="current-user-principal">
        <d:property name="displayname"/>
        <d:property name="addressbook-home-set" namespace="urn:ietf:params:xml:ns:carddav">
          <d:property name="displayname"/>
        </d:property>
      </d:property>
      """)

    conn = request(c.editor, "/dav/", body)
    assert conn.status == 207
    root = tree(conn.resp_body)
    responses = descendants(root, "DAV:", "response")

    assert Enum.map(responses, &response_href/1) == [
             "/dav/",
             AccessControl.principal_href(c.editor),
             "/dav/addressbooks/"
           ]

    assert conn.resp_body =~ "Bob Example"
    assert conn.resp_body =~ "Address Books"
    refute conn.resp_body =~ AccessControl.principal_href(c.outsider)
    refute conn.resp_body =~ "404 Not Found"
  end

  test "expanding role membership includes only real same-account members", c do
    body =
      report("expand-property", """
      <d:property name="group-member-set">
        <d:property name="displayname"/>
      </d:property>
      <d:property name="unknown" namespace="urn:client">
        <d:property name="displayname"/>
      </d:property>
      """)

    conn = request(c.viewer, AccessControl.role_href("admin"), body)
    assert conn.status == 207
    responses = descendants(tree(conn.resp_body), "DAV:", "response")

    assert Enum.map(responses, &response_href/1) == [
             AccessControl.role_href("admin"),
             AccessControl.principal_href(c.admin)
           ]

    assert conn.resp_body =~ "404 Not Found"
    refute conn.resp_body =~ AccessControl.principal_href(c.outsider)
    refute conn.resp_body =~ "Bob Example Foreign"

    foreign = request(c.viewer, AccessControl.principal_href(c.outsider), body)
    assert foreign.status == 404
    refute foreign.resp_body =~ "Bob Example Foreign"

    missing = request(c.viewer, "/dav/principals/users/999999999999/", body)
    assert missing.status == 404
  end

  test "book card reports remain available and unauthenticated reports require credentials", c do
    contact = contact_fixture(c.admin.account_id)
    path = contact_path(contact)
    conn = request(c.viewer, "/dav/addressbooks/default/", multiget_body([path]))
    assert conn.status == 207
    assert top_hrefs(conn.resp_body) == [path]
    assert conn.resp_body =~ "BEGIN:VCARD"

    conn = request(c.viewer, "/dav/addressbooks/default/", sync_collection_body())
    assert conn.status == 207
    assert top_hrefs(conn.resp_body) == [path]

    conn =
      dav_request(
        build_conn(),
        "REPORT",
        "/dav/principals/users/",
        report("principal-match", "<d:self/>")
      )

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "expand-property applies Depth to the collection and selected descendants", c do
    contact = contact_fixture(c.admin.account_id)
    body = report("expand-property", ~s(<d:property name="resourcetype"/>))
    root = "/dav/addressbooks/"
    assert top_hrefs(request(c.viewer, root, body, "0").resp_body) == [root]

    assert top_hrefs(request(c.viewer, root, body, "1").resp_body) == [
             root,
             "/dav/addressbooks/default/"
           ]

    all = request(c.viewer, root, body, "infinity")
    assert all.status == 207
    assert top_hrefs(all.resp_body) == [root, "/dav/addressbooks/default/", contact_path(contact)]
    assert request(c.viewer, root, body, "invalid").status == 400
  end

  test "property principal matching includes nested collection descendants", c do
    contact = contact_fixture(c.admin.account_id)
    body = report("principal-match", "<d:principal-property><d:owner/></d:principal-property>")

    for path <- ["/dav/", "/dav/addressbooks/"] do
      result = request(c.admin, path, body)
      assert result.status == 207
      assert contact_path(contact) in top_hrefs(result.resp_body)
      assert "/dav/addressbooks/default/" in top_hrefs(result.resp_body)
    end
  end

  defp named_user(name, role, account_id \\ nil) do
    user = user_fixture(%{role: role})

    user
    |> Ecto.Changeset.change(display_name: name, account_id: account_id || user.account_id)
    |> Repo.update!()
  end

  defp request(user, path, body, depth \\ "0") do
    build_conn()
    |> basic_auth(user.email, dav_password())
    |> put_req_header("depth", depth)
    |> dav_request("REPORT", path, body)
  end

  defp propfind(user, path, properties) do
    build_conn()
    |> basic_auth(user.email, dav_password())
    |> put_req_header("depth", "0")
    |> dav_request("PROPFIND", path, report("propfind", "<d:prop>#{properties}</d:prop>"))
  end

  defp report(name, content), do: "<d:#{name} xmlns:d=\"DAV:\">#{content}</d:#{name}>"

  defp tree(body) do
    xml = Regex.replace(~r/^\s*<\?xml[^?]*\?>\s*/, body, "")
    {:ok, node} = XMLParser.parse_property_value(xml)
    node
  end

  defp top_hrefs(body) do
    body
    |> tree()
    |> Map.fetch!(:children)
    |> Enum.filter(&(&1.ns == "DAV:" and &1.name == "response"))
    |> Enum.map(&response_href/1)
  end

  defp response_href(node) do
    node.children |> Enum.find(&(&1.ns == "DAV:" and &1.name == "href")) |> Map.fetch!(:text)
  end

  defp descendants(node, ns, name) do
    matches = if node.ns == ns and node.name == name, do: [node], else: []
    matches ++ Enum.flat_map(node.children, &descendants(&1, ns, name))
  end
end
