defmodule KithWeb.API.StatisticsController do
  use KithWeb, :controller

  alias Kith.Accounts.OptionalFeatures
  alias Kith.Repo
  alias Kith.Scope, as: TenantScope

  action_fallback KithWeb.API.FallbackController

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    account_id = scope.account.id
    account = scope.account

    stats = %{
      total_contacts: count(Kith.Contacts.Contact, account_id),
      total_notes: count(Kith.Contacts.Note, account_id),
      storage_used_bytes: storage_used(account_id),
      account_created_at: account.inserted_at
    }

    stats =
      stats
      |> maybe_count(account, "activities", :total_activities, Kith.Activities.Activity)
      |> maybe_count(account, "calls", :total_calls, Kith.Activities.Call)

    json(conn, %{data: stats})
  end

  defp maybe_count(stats, account, feature, key, schema) do
    if OptionalFeatures.enabled?(account, feature) do
      Map.put(stats, key, count(schema, account.id))
    else
      stats
    end
  end

  defp count(schema, account_id) do
    schema
    |> TenantScope.scope_to_account(account_id)
    |> Repo.aggregate(:count)
  end

  defp storage_used(account_id) do
    {:ok, bytes} = Kith.Storage.usage(account_id)
    bytes
  rescue
    _ -> 0
  end
end
