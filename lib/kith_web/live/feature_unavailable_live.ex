defmodule KithWeb.FeatureUnavailableLive do
  use KithWeb, :live_view

  alias Kith.Accounts.OptionalFeatures

  @impl true
  def mount(%{"feature" => feature}, _session, socket) do
    case KithWeb.OptionalFeatures.page_path(feature) do
      nil ->
        {:ok, redirect(socket, to: ~p"/dashboard")}

      path ->
        {:ok,
         assign(socket,
           page_title: "Feature unavailable",
           label: OptionalFeatures.label(feature),
           feature: feature,
           path: path
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <KithWeb.FeatureComponents.unavailable
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
      feature={@feature}
      label={@label}
      path={@path}
    />
    """
  end
end
