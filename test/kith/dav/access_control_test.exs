defmodule Kith.DAV.AccessControlTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures

  alias Kith.Accounts.Scope
  alias Kith.DAV.AccessControl

  setup do
    admin = user_fixture() |> Repo.preload(:account)
    editor = member_fixture(admin.account_id, "editor", "Élodie & Editor")
    viewer = member_fixture(admin.account_id, "viewer", "Viewer")
    outsider = user_fixture() |> Repo.preload(:account)

    %{admin: admin, editor: editor, viewer: viewer, outsider: outsider}
  end

  test "principal resolution and enumeration keep distinct users inside their account", ctx do
    scope = Scope.for_user(ctx.admin)
    principals = AccessControl.list_principals(scope)
    hrefs = Enum.map(principals, & &1.href)
    assert length(hrefs) == 6
    assert AccessControl.principal_href(ctx.admin) in hrefs
    assert AccessControl.principal_href(ctx.editor) in hrefs
    assert AccessControl.principal_href(ctx.viewer) in hrefs
    refute AccessControl.principal_href(ctx.outsider) in hrefs

    assert {:ok, %{user: %{id: id}}} = AccessControl.resolve_principal(scope, "/dav/principals/")
    assert id == ctx.admin.id

    assert :error =
             AccessControl.resolve_principal(scope, AccessControl.principal_href(ctx.outsider))

    assert :error =
             AccessControl.resolve_principal(
               Scope.for_user(ctx.outsider),
               AccessControl.principal_href(ctx.admin)
             )

    for href <- [
          "/dav/principals/users/0/",
          "/dav/principals/users/#{ctx.editor.id}/extra/",
          "/dav/principals/users/#{ctx.editor.id}/?account=#{ctx.outsider.account_id}",
          "/dav/principals/roles/owner/",
          "https://untrusted.example/dav/principals/users/#{ctx.editor.id}/"
        ] do
      assert :error = AccessControl.resolve_principal(scope, href)
    end
  end

  test "current privileges follow admin/editor/viewer policy and resource operations", ctx do
    for user <- [ctx.admin, ctx.editor] do
      scope = Scope.for_user(user)
      assert "write-content" in AccessControl.privileges(scope, :contact)
      assert "bind" in AccessControl.privileges(scope, :book)
      assert "unbind" in AccessControl.privileges(scope, :book)
      refute "bind" in AccessControl.privileges(scope, :contact)
      refute "write-content" in AccessControl.privileges(scope, :principal)
      refute "write-acl" in AccessControl.privileges(scope, :book)
      refute "unlock" in AccessControl.privileges(scope, :contact)
      refute "all" in AccessControl.privileges(scope, :contact)
    end

    for kind <- [:book, :contact, :discovery, :principal] do
      assert AccessControl.privileges(Scope.for_user(ctx.viewer), kind) ==
               ~w(read read-acl read-current-user-privilege-set)

      xml = AccessControl.current_user_privilege_set(Scope.for_user(ctx.viewer), kind)
      refute xml =~ "<d:write"
      refute xml =~ "<d:all/>"
    end

    assert AccessControl.privileges(nil, :contact) == []
    assert AccessControl.list_principals(nil) == []
    assert AccessControl.resolve_principal(nil, "/dav/principals/") == :error
  end

  test "role ACLs are protected and do not grant mutation of the ACL", ctx do
    properties = AccessControl.resource_properties(Scope.for_user(ctx.editor), :book)
    assert properties.owner =~ AccessControl.role_href("admin")
    assert length(Regex.scan(~r/<d:ace>/, properties.acl)) == 3
    assert length(Regex.scan(~r/<d:protected\/>/, properties.acl)) == 3
    refute properties.acl =~ "<d:write-acl/>"
    refute properties.acl =~ "<d:unlock/>"
    refute properties.acl =~ "<d:all/>"
    assert properties.acl_restrictions =~ "<d:grant-only/>"
    assert properties.acl_restrictions =~ "<d:no-invert/>"
    assert properties.inherited_acl_set == "<d:inherited-acl-set/>"
    assert properties.principal_collection_set =~ "/dav/principals/users/"
    assert properties.principal_collection_set =~ "/dav/principals/roles/"

    assert Enum.map(AccessControl.acl_principals(Scope.for_user(ctx.viewer)), & &1.href) ==
             Enum.map(~w(admin editor viewer), &AccessControl.role_href/1)
  end

  test "role membership expands to real users without exposing another account", ctx do
    scope = Scope.for_user(ctx.admin)

    {:ok, editor_group} =
      AccessControl.resolve_principal(scope, AccessControl.role_href("editor"))

    properties = AccessControl.principal_properties(scope, editor_group)
    assert properties.group_member_set =~ AccessControl.principal_href(ctx.editor)
    refute properties.group_member_set =~ AccessControl.principal_href(ctx.admin)
    refute properties.group_member_set =~ AccessControl.principal_href(ctx.outsider)
    assert properties.group_membership == "<d:group-membership/>"

    {:ok, editor} =
      AccessControl.resolve_principal(scope, AccessControl.principal_href(ctx.editor))

    editor_properties = AccessControl.principal_properties(scope, editor)
    assert editor_properties.displayname =~ "Élodie &amp; Editor"
    assert editor_properties.group_membership =~ AccessControl.role_href("editor")
    assert editor_properties.group_member_set == "<d:group-member-set/>"

    assert AccessControl.principal_properties(Scope.for_user(ctx.outsider), editor) == %{}
  end

  test "principal matching includes the authenticated user and its real role group", ctx do
    principals = AccessControl.matching_principals(Scope.for_user(ctx.editor))

    assert Enum.map(principals, & &1.href) ==
             [AccessControl.principal_href(ctx.editor), AccessControl.role_href("editor")]
  end

  test "displayname search combines criteria and normalizes Unicode without cross-account matches",
       ctx do
    scope = Scope.for_user(ctx.admin)

    assert {:ok, [principal]} =
             AccessControl.search_principals(scope, [
               %{properties: [:displayname], match: "E\u0301LODIE"},
               %{properties: [:displayname], match: "editor"}
             ])

    assert principal.href == AccessControl.principal_href(ctx.editor)

    assert {:ok, []} =
             AccessControl.search_principals(scope, [
               %{properties: [:displayname], match: ctx.outsider.email}
             ])

    assert {:error, :unsupported_search_property} =
             AccessControl.search_principals(scope, [%{properties: [:email], match: "example"}])

    assert AccessControl.search_property_set() =~ "<d:displayname/>"
  end

  defp member_fixture(account_id, role, displayname) do
    user_fixture(%{role: role})
    |> Ecto.Changeset.change(account_id: account_id, display_name: displayname)
    |> Repo.update!()
    |> Repo.preload(:account, force: true)
  end
end
