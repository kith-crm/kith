defmodule KithWeb.OptionalFeatures do
  @moduledoc "Refreshes workspace flags in connected views and protects feature pages."

  use KithWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Kith.Accounts
  alias Kith.Accounts.OptionalFeatures

  @pages %{
    KithWeb.JournalLive.Index => "journal",
    KithWeb.SettingsLive.ActivityTypes => "activities",
    KithWeb.SettingsLive.LifeEventTypes => "life_events"
  }

  def page_path("journal"), do: ~p"/journal"
  def page_path("activities"), do: ~p"/settings/activity-types"
  def page_path("life_events"), do: ~p"/settings/life-event-types"
  def page_path(_feature), do: nil

  def on_mount(:default, _params, _session, socket) do
    feature = @pages[socket.view]

    socket =
      if connected?(socket) do
        account_id = socket.assigns.current_scope.account.id
        Phoenix.PubSub.subscribe(Kith.PubSub, OptionalFeatures.topic(account_id))
        refresh_account(socket)
      else
        socket
      end

    if disabled?(socket, feature) do
      {:halt, redirect(socket, to: unavailable_path(feature))}
    else
      socket =
        socket
        |> attach_hook(:optional_features, :handle_info, &handle_feature_change/2)
        |> attach_access_hooks(feature)

      {:cont, socket}
    end
  end

  defp handle_feature_change({:optional_feature_changed, _, _}, socket) do
    socket = refresh_account(socket)
    feature = @pages[socket.view]

    cond do
      disabled?(socket, feature) ->
        {:halt, push_navigate(socket, to: unavailable_path(feature))}

      socket.view in [KithWeb.DashboardLive.Index, KithWeb.ContactLive.ClusterMerge] ->
        {:cont, socket}

      true ->
        {:halt, socket}
    end
  end

  defp handle_feature_change(_, socket), do: {:cont, socket}

  defp attach_access_hooks(socket, nil), do: socket

  defp attach_access_hooks(socket, feature) do
    socket
    |> attach_hook(:require_optional_feature, :handle_event, fn event, _, socket ->
      with {:cont, socket} <- require_enabled(socket, feature) do
        require_edit_permission(socket, feature, event)
      end
    end)
    |> attach_hook(:require_optional_feature, :handle_params, fn _, _, socket ->
      require_enabled(socket, feature)
    end)
  end

  defp require_enabled(socket, feature) do
    socket = refresh_account(socket)

    if disabled?(socket, feature),
      do: {:halt, push_navigate(socket, to: unavailable_path(feature))},
      else: {:cont, socket}
  end

  defp require_edit_permission(socket, "journal", "filter-mood"), do: {:cont, socket}

  defp require_edit_permission(socket, feature, _event) do
    resource = if feature == "journal", do: :journal, else: :reference_data

    if Kith.Policy.can?(socket.assigns.current_scope.user, :create, resource) do
      {:cont, socket}
    else
      {:halt, put_flash(socket, :error, "You do not have permission to edit this feature.")}
    end
  end

  defp disabled?(socket, feature) do
    feature && !OptionalFeatures.enabled?(socket.assigns.current_scope.account, feature)
  end

  defp refresh_account(socket) do
    scope = socket.assigns.current_scope
    assign(socket, :current_scope, %{scope | account: Accounts.get_account!(scope.account.id)})
  end

  defp unavailable_path(feature), do: ~p"/features/#{feature}/unavailable"
end
