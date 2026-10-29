defmodule Kith.DAV.AccessControl do
  @moduledoc """
  DAV principals and protected ACLs derived from Kith's existing account roles.

  Principal lookup is always relative to the authenticated account. These are
  views of users and roles, not a second permissions store. ACL modification,
  group membership changes and sharing are not introduced by this module.
  """

  import Ecto.Query

  alias Kith.Accounts.{Scope, User}
  alias Kith.DAV.XMLBuilder
  alias Kith.{Policy, Repo}

  @roles ~w(admin editor viewer)
  @read ~w(read read-acl read-current-user-privilege-set)

  def principal_href(%User{id: id}), do: "/dav/principals/users/#{id}/"
  def role_href(role) when role in @roles, do: "/dav/principals/roles/#{role}/"

  @doc "Lists only principals belonging to the authenticated account."
  def list_principals(scope) do
    if valid_scope?(scope) do
      users =
        Repo.all(from(u in User, where: u.account_id == ^scope.account.id, order_by: u.id))

      Enum.map(users, &user_principal/1) ++ Enum.map(@roles, &role_principal/1)
    else
      []
    end
  end

  def resolve_principal(scope, href) when is_binary(href) do
    if valid_scope?(scope) do
      resolve_path(scope, href)
    else
      :error
    end
  end

  def resolve_principal(_scope, _href), do: :error

  defp resolve_path(scope, "/dav/principals/"),
    do: resolve_path(scope, principal_href(scope.user))

  defp resolve_path(scope, "/dav/principals/users/" <> suffix) do
    with [raw_id, ""] <- String.split(suffix, "/"),
         {id, ""} when id > 0 <- Integer.parse(raw_id),
         true <- Integer.to_string(id) == raw_id,
         %User{} = user <- Repo.get_by(User, id: id, account_id: scope.account.id) do
      {:ok, user_principal(user)}
    else
      _ -> :error
    end
  end

  defp resolve_path(_scope, "/dav/principals/roles/" <> suffix) do
    case String.split(suffix, "/") do
      [role, ""] when role in @roles -> {:ok, role_principal(role)}
      _ -> :error
    end
  end

  defp resolve_path(_scope, _href), do: :error

  defp user_principal(user) do
    %{
      kind: :user,
      href: principal_href(user),
      displayname: user.display_name || user.email,
      user: user
    }
  end

  defp role_principal(role),
    do: %{kind: :role, href: role_href(role), displayname: String.capitalize(role), role: role}

  @doc "Privileges actually granted by the current account policy on this resource type."
  def privileges(scope, kind) do
    if valid_scope?(scope), do: user_privileges(scope.user, kind), else: []
  end

  defp user_privileges(user, kind) do
    read = if Policy.can?(user, :read, :contact), do: @read, else: []

    write =
      if Policy.can?(user, :update, :contact) do
        case kind do
          :book -> ~w(write-properties bind unbind)
          :contact -> ~w(write-properties write-content)
          _ -> ~w(write-properties)
        end
      else
        []
      end

    read ++ write
  end

  def current_user_privilege_set(scope, kind),
    do: element("current-user-privilege-set", privilege_elements(privileges(scope, kind)))

  def supported_privilege_set(_kind) do
    write_children =
      Enum.map_join(
        [
          {"write-properties", "Modify properties"},
          {"write-content", "Replace resource content"},
          {"bind", "Create collection members"},
          {"unbind", "Remove collection members"}
        ],
        fn {name, description} -> supported(name, description) end
      )

    children =
      supported("read", "Read resource") <>
        supported("read-acl", "Read protected access policy") <>
        supported("read-current-user-privilege-set", "Read current privileges") <>
        supported("write-acl", "Modify unprotected access rules") <>
        supported("write", "Modify resource", write_children)

    element("supported-privilege-set", supported("all", "All supported privileges", children))
  end

  defp supported(name, description, children \\ "") do
    element(
      "supported-privilege",
      privilege_elements([name]) <>
        "<d:description xml:lang=\"en\">#{XMLBuilder.escape(description)}</d:description>" <>
        children
    )
  end

  @doc "Protected role ACEs; account user-management remains the only role writer."
  def acl(kind) do
    aces =
      Enum.map_join(@roles, fn role ->
        element(
          "ace",
          element("principal", href(role_href(role))) <>
            element("grant", privilege_elements(user_privileges(%User{role: role}, kind))) <>
            "<d:protected/>"
        )
      end)

    element("acl", aces)
  end

  def acl_restrictions,
    do: "<d:acl-restrictions><d:grant-only/><d:no-invert/></d:acl-restrictions>"

  def inherited_acl_set, do: "<d:inherited-acl-set/>"

  def principal_collection_set,
    do:
      element(
        "principal-collection-set",
        href("/dav/principals/users/") <> href("/dav/principals/roles/")
      )

  def resource_properties(scope, kind) do
    %{
      owner: XMLBuilder.owner(role_href("admin")),
      group: "<d:group/>",
      supported_privilege_set: supported_privilege_set(kind),
      current_user_privilege_set: current_user_privilege_set(scope, kind),
      acl: acl(kind),
      acl_restrictions: acl_restrictions(),
      inherited_acl_set: inherited_acl_set(),
      principal_collection_set: principal_collection_set()
    }
  end

  @doc "Properties of a resolved principal, with account-scoped membership."
  def principal_properties(scope, principal) do
    case resolve_principal(scope, principal.href) do
      {:ok, resolved} ->
        Map.merge(resource_properties(scope, :principal), %{
          displayname: XMLBuilder.displayname(resolved.displayname),
          resourcetype: XMLBuilder.resourcetype("<d:principal/>"),
          principal_url: XMLBuilder.principal_url(resolved.href),
          alternate_uri_set: "<d:alternate-URI-set/>",
          group_member_set: group_member_set(scope, resolved),
          group_membership: group_membership(resolved)
        })

      :error ->
        %{}
    end
  end

  defp group_member_set(scope, %{kind: :role, role: role}) do
    members =
      Repo.all(
        from(u in User,
          where: u.account_id == ^scope.account.id and u.role == ^role,
          order_by: u.id
        )
      )

    element("group-member-set", Enum.map_join(members, &href(principal_href(&1))))
  end

  defp group_member_set(_scope, _principal), do: "<d:group-member-set/>"

  defp group_membership(%{kind: :user, user: %{role: role}}) when role in @roles,
    do: element("group-membership", href(role_href(role)))

  defp group_membership(_principal), do: "<d:group-membership/>"

  def acl_principals(scope) do
    if valid_scope?(scope), do: Enum.map(@roles, &role_principal/1), else: []
  end

  @doc "Principals matching DAV:self, including the user's role group."
  def matching_principals(scope) do
    if valid_scope?(scope) do
      [user_principal(scope.user), role_principal(scope.user.role)]
    else
      []
    end
  end

  @doc "Search criteria are ANDed; only the DAV:displayname search property is supported."
  def search_principals(scope, searches) do
    if Enum.all?(searches, &(&1.properties == [:displayname])) do
      {:ok,
       Enum.filter(list_principals(scope), fn principal ->
         Enum.all?(searches, fn search ->
           String.contains?(casemap(principal.displayname), casemap(search.match))
         end)
       end)}
    else
      {:error, :unsupported_search_property}
    end
  end

  def search_property_set do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<d:principal-search-property-set xmlns:d="DAV:">) <>
      "<d:principal-search-property><d:prop><d:displayname/></d:prop>" <>
      ~s(<d:description xml:lang="en">Display name</d:description>) <>
      "</d:principal-search-property></d:principal-search-property-set>"
  end

  defp valid_scope?(%Scope{user: %User{account_id: id, role: role}, account: %{id: id}}),
    do: role in @roles

  defp valid_scope?(_), do: false
  defp casemap(value), do: value |> String.normalize(:nfc) |> String.downcase()
  defp href(value), do: element("href", XMLBuilder.escape(value))
  defp element(name, contents), do: "<d:#{name}>#{contents}</d:#{name}>"

  defp privilege_elements(names),
    do: Enum.map_join(names, &"<d:privilege><d:#{&1}/></d:privilege>")
end
