defmodule Kith.DAV.PrincipalReportsTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures

  alias Kith.Accounts.Scope
  alias Kith.DAV.{AccessControl, PrincipalReports, XMLBuilder, XMLParser}

  setup do
    user = user_fixture()
    user = Repo.update!(Ecto.Changeset.change(user, display_name: "Alice Example"))
    other = user_fixture()
    member = user_fixture()

    member =
      Repo.update!(
        Ecto.Changeset.change(member,
          account_id: user.account_id,
          display_name: "Bob Example",
          role: "viewer"
        )
      )

    %{scope: Scope.for_user(user), user: user, other: other, member: member}
  end

  test "ACL principal property set returns each role once with names and missing propstats", c do
    request =
      report(
        "acl-principal-prop-set",
        "<d:prop><d:displayname/><x:missing xmlns:x=\"urn:client\"/></d:prop>"
      )

    assert {:ok, 207, xml} = render(c.scope, request, "/dav/addressbooks/default/")
    assert length(Regex.scan(~r/<d:response>/, xml)) == 3
    assert xml =~ "Admin"
    assert xml =~ "Viewer"
    assert xml =~ "404 Not Found"
    refute xml =~ c.other.email
  end

  test "principal self matches the user and containing role only in the selected collection", c do
    request = report("principal-match", "<d:self/><d:prop><d:displayname/></d:prop>")
    assert {:ok, 207, xml} = render(c.scope, request, "/dav/principals/users/")
    assert xml =~ AccessControl.principal_href(c.user)
    refute xml =~ AccessControl.principal_href(c.member)
    refute xml =~ AccessControl.principal_href(c.other)

    assert {:ok, 207, xml} = render(c.scope, request, AccessControl.role_href("admin"))
    assert xml =~ "Admin"
    assert {:ok, 207, xml} = render(c.scope, request, AccessControl.role_href("viewer"))
    refute xml =~ "<d:response>"
  end

  test "search ANDs criteria and apply-to-principal-collection-set uses only this account", c do
    criteria = """
    <d:property-search><d:prop><d:displayname/></d:prop><d:match>EXAMPLE</d:match></d:property-search>
    <d:property-search><d:prop><d:displayname/></d:prop><d:match>bob</d:match></d:property-search>
    <d:prop><d:displayname/><d:principal-URL/></d:prop>
    """

    request = report("principal-property-search", criteria)
    assert {:ok, 207, xml} = render(c.scope, request, "/dav/principals/users/")
    assert xml =~ "Bob Example"
    refute xml =~ "Alice Example"
    refute xml =~ c.other.email

    assert {:ok, 207, xml} = render(c.scope, request, "/dav/addressbooks/default/")
    refute xml =~ "<d:response>"

    request =
      report("principal-property-search", criteria <> "<d:apply-to-principal-collection-set/>")

    assert {:ok, 207, xml} = render(c.scope, request, "/dav/addressbooks/default/")
    assert xml =~ "Bob Example"
  end

  test "unsupported search fields return an explicit condition", c do
    request =
      report(
        "principal-property-search",
        "<d:property-search><d:prop><d:getetag/></d:prop><d:match>x</d:match></d:property-search>"
      )

    assert {:error, 403, "<k:supported-principal-search-property/>"} =
             render(c.scope, request, "/dav/principals/users/")
  end

  test "search property discovery is resource specific", c do
    request = report("principal-search-property-set", "")
    assert {:ok, 200, xml} = render(c.scope, request, "/dav/principals/users/")
    assert xml =~ "<d:displayname/>"

    assert {:error, 403, "<d:supported-report/>"} =
             render(c.scope, request, "/dav/addressbooks/default/")
  end

  test "property matching scans only supplied account-scoped collection descendants", c do
    request =
      report(
        "principal-match",
        "<d:principal-property><d:owner/></d:principal-property><d:prop><d:displayname/></d:prop>"
      )

    target = %{
      href: "/dav/addressbooks/",
      kind: :discovery,
      members: [%{href: "/dav/addressbooks/default/"}, %{href: "/dav/elsewhere/"}]
    }

    resolver = fn _ ->
      {:ok,
       %{
         owner: XMLBuilder.owner(AccessControl.role_href("admin")),
         displayname: XMLBuilder.displayname("Owned book")
       }}
    end

    assert {:ok, 207, xml} = PrincipalReports.render(c.scope, request, target, resolver)
    assert xml =~ "Owned book"
    refute xml =~ "/dav/elsewhere/"
  end

  test "expand-property resolves nested principal and group hrefs without external requests", c do
    request =
      report("expand-property", """
      <d:property name="owner"><d:property name="group-member-set"><d:property name="displayname"/></d:property></d:property>
      <d:property name="missing" namespace="urn:client"/>
      """)

    resolver = fn
      "/dav/addressbooks/default/" ->
        {:ok, %{owner: XMLBuilder.owner(AccessControl.role_href("admin"))}}

      href ->
        assert String.starts_with?(href, "/dav/principals/")
        :error
    end

    assert {:ok, 207, xml} =
             PrincipalReports.render(
               c.scope,
               request,
               %{href: "/dav/addressbooks/default/", kind: :book},
               resolver
             )

    assert xml =~ "Alice Example"
    refute xml =~ "Bob Example"
    refute xml =~ c.other.email
    assert xml =~ "404 Not Found"
  end

  test "expansion refuses foreign principals and external hrefs without calling resolver", c do
    request =
      report(
        "expand-property",
        "<d:property name=\"owner\"><d:property name=\"displayname\"/></d:property>"
      )

    for href <- [
          AccessControl.principal_href(c.other),
          "https://example.com/private",
          "/dav/../private"
        ] do
      resolver = fn
        "/dav/addressbooks/default/" -> {:ok, %{owner: XMLBuilder.owner(href)}}
        unexpected -> flunk("resolver called with inaccessible path #{unexpected}")
      end

      assert {:ok, 207, xml} =
               PrincipalReports.render(
                 c.scope,
                 request,
                 %{href: "/dav/addressbooks/default/", kind: :book},
                 resolver
               )

      assert xml =~ "404 Not Found"
      refute xml =~ c.other.email
    end
  end

  defp report(name, children) do
    {:ok, {:principal_report, request}} =
      XMLParser.parse_report(~s(<d:#{name} xmlns:d="DAV:">#{children}</d:#{name}>))

    request
  end

  defp render(scope, request, href),
    do:
      PrincipalReports.render(scope, request, %{href: href, kind: :discovery}, fn _ -> :error end)
end
