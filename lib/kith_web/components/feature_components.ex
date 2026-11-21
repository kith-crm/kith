defmodule KithWeb.FeatureComponents do
  @moduledoc "Presentation for unavailable optional workspace features."
  use KithWeb, :html

  alias Kith.Accounts.OptionalFeatures

  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :current_path, :string, required: true
  attr :pending_duplicates_count, :integer, required: true
  attr :feature, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, required: true

  def unavailable(assigns) do
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
