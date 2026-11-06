defmodule KithWeb.DAV.RevisedAccessControlTest do
  use KithWeb.ConnCase, async: true

  import KithWeb.DAV.TestHelpers
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.DAV.{AccessControl, ContactDav, Store}
  alias Kith.Repo

  setup context do
    base = setup_dav_user(context)
    editor = member(base.user.account_id, "editor")
    viewer = member(base.user.account_id, "viewer")
    outsider = user_fixture()
    contact = contact_fixture(base.user.account_id)
    dav = Repo.get!(ContactDav, contact.id)

    Map.merge(base, %{
      editor: editor,
      viewer: viewer,
      outsider: outsider,
      contact: contact,
      path: Store.href(%{contact | dav: dav})
    })
  end

  test "discovery distinguishes real users, isolates accounts and reflects roles", c do
    body = propfind("<d:current-user-principal/><d:current-user-privilege-set/><d:acl/>")

    for user <- [c.user, c.editor, c.viewer] do
      ctx = %{c | user: user}
      result = authed_dav(ctx, "PROPFIND", "/dav/addressbooks/default/", body)
      assert result.status == 207
      assert result.resp_body =~ AccessControl.principal_href(user)
      assert result.resp_body =~ "<d:protected/>"

      [privileges] =
        Regex.run(
          ~r/<d:current-user-privilege-set>.*?<\/d:current-user-privilege-set>/s,
          result.resp_body
        )

      if user.role == "viewer",
        do: refute(privileges =~ "<d:write"),
        else: assert(privileges =~ "<d:bind/>")

      refute privileges =~ "<d:all/>"
      refute privileges =~ "<d:write-acl/>"
      assert authed_dav(ctx, "PROPFIND", AccessControl.principal_href(c.outsider)).status == 404
    end

    own = authed_dav(c, "PROPFIND", AccessControl.principal_href(c.editor))
    assert own.status == 207
    assert own.resp_body =~ AccessControl.principal_href(c.editor)
    unauthenticated = dav_request(c.conn, "PROPFIND", "/dav/principals/users/")
    assert unauthenticated.status == 401
  end

  test "OPTIONS methods and reports are resource-specific and never claim locking", c do
    for path <- ["/dav/", "/dav/principals/", "/dav/addressbooks/default/", c.path] do
      result = authed_dav(c, "OPTIONS", path)
      assert result.status == 200
      [dav] = get_resp_header(result, "dav")
      refute "2" in String.split(dav, ", ")
      refute dav =~ "access-control"
      [allow] = get_resp_header(result, "allow")
      assert allow =~ "PROPPATCH"
      refute allow =~ "LOCK"

      if path == c.path do
        assert allow =~ "GET"
        assert allow =~ "PUT"
        assert allow =~ "DELETE"
      else
        refute "GET" in String.split(allow, ", ")
        refute "PUT" in String.split(allow, ", ")
        refute "DELETE" in String.split(allow, ", ")
      end
    end

    assert authed_dav(c, "OPTIONS", "/dav/missing/").status == 404
  end

  test "protected ACL updates fail explicitly without changing roles or contact publication", c do
    before = Repo.get!(ContactDav, c.contact.id)

    acl =
      ~s(<d:acl xmlns:d="DAV:"><d:ace><d:principal><d:href>#{AccessControl.principal_href(c.viewer)}</d:href></d:principal><d:grant><d:privilege><d:write/></d:privilege></d:grant></d:ace></d:acl>)

    for user <- [c.user, c.editor, c.viewer] do
      result = authed_dav(%{c | user: user}, "ACL", "/dav/addressbooks/default/", acl)
      assert result.status == 403
      assert result.resp_body =~ "need-privileges"
      assert result.resp_body =~ "<d:write-acl/>"
    end

    role_acl =
      String.replace(
        acl,
        AccessControl.principal_href(c.viewer),
        AccessControl.role_href("viewer")
      )

    assert authed_dav(c, "ACL", "/dav/addressbooks/default/", role_acl).resp_body =~
             "no-protected-ace-conflict"

    assert authed_dav(c, "ACL", c.path, ~s(<d:acl xmlns:d="DAV:"/>)).resp_body =~
             "need-privileges"

    assert Repo.get!(ContactDav, c.contact.id) == before
    assert Repo.reload!(c.viewer).role == "viewer"
    declared = ~s(<?xml version="1.0" encoding="UTF-8"?>) <> acl
    assert authed_dav(c, "ACL", c.path, declared).status == 403
    assert authed_dav(c, "ACL", c.path, declared).resp_body =~ "need-privileges"
    assert authed_dav(c, "ACL", c.path, "<broken>").status == 400
    assert authed_dav(c, "ACL", "/dav/missing/", acl).status == 404
  end

  test "PROPPATCH processes ordered instructions atomically on each resource", c do
    before = Repo.get!(ContactDav, c.contact.id)
    bytes = authed_dav(c, "GET", c.path).resp_body

    body =
      ~s(<d:propertyupdate xmlns:d="DAV:" xmlns:x="urn:test"><d:remove><d:prop><x:absent/></d:prop></d:remove><d:set><d:prop><d:displayname>Blocked</d:displayname><x:color>red</x:color></d:prop></d:set></d:propertyupdate>)

    for path <- [
          "/dav/",
          "/dav/principals/",
          "/dav/addressbooks/",
          "/dav/addressbooks/default/",
          c.path
        ] do
      result = authed_dav(c, "PROPPATCH", path, body)
      assert result.status == 207
      assert result.resp_body =~ "cannot-modify-protected-property"
      assert length(Regex.scan(~r/424 Failed Dependency/, result.resp_body)) == 2
      assert length(Regex.scan(~r/403 Forbidden/, result.resp_body)) == 1
      assert result.resp_body =~ path
    end

    assert Repo.get!(ContactDav, c.contact.id) == before
    assert authed_dav(c, "GET", c.path).resp_body == bytes
    denied = authed_dav(%{c | user: c.viewer}, "PROPPATCH", c.path, body)
    assert denied.status == 403
    assert denied.resp_body =~ "need-privileges"
    assert authed_dav(c, "PROPPATCH", "/dav/missing/", body).status == 404
  end

  test "absent dead-property removal is a no-op and unsupported set is not protected", c do
    remove =
      ~s(<d:propertyupdate xmlns:d="DAV:" xmlns:x="urn:test"><d:remove><d:prop><x:absent/></d:prop></d:remove></d:propertyupdate>)

    assert authed_dav(c, "PROPPATCH", c.path, remove).resp_body =~ "200 OK"
    set = String.replace(remove, ["remove"], "set")
    result = authed_dav(c, "PROPPATCH", c.path, set)
    assert result.status == 207
    assert result.resp_body =~ "403 Forbidden"
    refute result.resp_body =~ "cannot-modify-protected-property"
  end

  defp propfind(props), do: ~s(<d:propfind xmlns:d="DAV:"><d:prop>#{props}</d:prop></d:propfind>)

  defp member(account_id, role) do
    user_fixture(%{role: role})
    |> Ecto.Changeset.change(account_id: account_id)
    |> Repo.update!()
  end
end
