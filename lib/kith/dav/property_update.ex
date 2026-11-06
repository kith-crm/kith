defmodule Kith.DAV.PropertyUpdate do
  @moduledoc """
  Evaluates ordered property updates against Kith's read-only DAV property policy.

  Live properties, including the fixed book's display name, are protected.
  Arbitrary dead-property storage is not implemented. Removing an absent dead
  property succeeds as a no-op (RFC 4918 §14.23). A failure rolls back the entire
  instruction list; all other instructions report failed dependency.
  """

  @protected ~w(displayname resourcetype getcontenttype getetag getlastmodified
    sync_token current_user_principal supported_report_set principal_url owner
    current_user_privilege_set address_data addressbook_home_set supported_address_data
    max_resource_size supported_collation_set getctag alternate_uri_set group
    group_member_set group_membership supported_privilege_set acl acl_restrictions
    inherited_acl_set principal_collection_set)a

  @dav_protected ~w(displayname resourcetype getcontenttype getetag getlastmodified
    getcontentlength creationdate sync-token current-user-principal supported-report-set
    principal-URL owner current-user-privilege-set alternate-URI-set group group-member-set
    group-membership supported-privilege-set acl acl-restrictions inherited-acl-set
    principal-collection-set)

  @doc "Returns ordered property/status/error results without changing resource state."
  def evaluate(instructions) do
    failure = Enum.find_index(instructions, &(outcome(&1) != {200, nil}))

    instructions
    |> Enum.with_index()
    |> Enum.map(fn {instruction, index} ->
      {status, error} =
        cond do
          is_nil(failure) -> {200, nil}
          index == failure -> outcome(instruction)
          true -> {424, nil}
        end

      %{property: instruction.property, status: status, error: error}
    end)
  end

  defp outcome(%{property: property, action: action}) do
    cond do
      protected?(property) -> {403, :cannot_modify_protected_property}
      action == :remove -> {200, nil}
      true -> {403, nil}
    end
  end

  defp protected?(property) when property in @protected, do: true
  defp protected?({"DAV:", property}) when property in @dav_protected, do: true
  defp protected?(_property), do: false
end
