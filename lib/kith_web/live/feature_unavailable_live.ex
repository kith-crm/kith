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
    assigns =
      assign(
        assigns,
        :available,
        OptionalFeatures.enabled?(assigns.current_scope.account, assigns.feature)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <h1 class="text-2xl font-semibold">
        {@label} is {if @available, do: "available", else: "unavailable"}
      </h1>
      <p :if={!@available} class="mt-2">
        This feature is turned off for your workspace. Any saved records are kept.
      </p>
      <div class="mt-4 flex flex-wrap gap-4">
        <.link :if={@available} navigate={@path} class="underline">Open {@label}</.link>
        <.link navigate={~p"/dashboard"} class="underline">Back to dashboard</.link>
        <.link
          :if={!@available && Kith.Policy.can?(@current_scope.user, :manage, :account)}
          href={~p"/settings/account" <> "#optional-features"}
          class="underline"
        >
          Optional features
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
