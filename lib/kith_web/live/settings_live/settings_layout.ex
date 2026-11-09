defmodule KithWeb.SettingsLive.SettingsLayout do
  @moduledoc """
  Shared settings sidebar navigation component used by all settings pages.
  """

  use KithWeb, :html

  @doc "Settings destinations shared by the sidebar and mobile selector."
  def destinations(scope) do
    admin? = authorized?(scope.user, :manage, :account)

    [
      %{
        label: "Personal",
        items: [
          %{path: "/users/settings", label: "Profile", icon: "hero-user"},
          %{path: "/settings/security", label: "Security", icon: "hero-shield-check"}
        ]
      },
      %{
        label: "Workspace",
        items: [
          %{
            path: "/settings/account",
            label: "Account",
            icon: "hero-building-office",
            admin: true
          },
          %{path: "/settings/tags", label: "Tags", icon: "hero-tag"},
          %{path: "/settings/emotions", label: "Emotions", icon: "hero-face-smile"},
          %{
            path: "/settings/activity-types",
            label: "Activity Types",
            icon: "hero-rectangle-group"
          },
          %{path: "/settings/life-event-types", label: "Life Event Types", icon: "hero-star"},
          %{
            path: "/settings/integrations",
            label: "Integrations",
            icon: "hero-puzzle-piece",
            admin: true
          }
        ]
      },
      %{
        label: "Data",
        items: [
          %{path: "/settings/import", label: "Import", icon: "hero-arrow-up-tray"},
          %{path: "/settings/imports", label: "Import History", icon: "hero-clock"},
          %{path: "/settings/export", label: "Export", icon: "hero-arrow-down-tray"},
          %{
            path: "/settings/audit-log",
            label: "Audit Log",
            icon: "hero-clipboard-document-list",
            admin: true
          }
        ]
      }
    ]
    |> Enum.map(fn group ->
      %{group | items: Enum.filter(group.items, &(admin? or !Map.get(&1, :admin, false)))}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  attr :current_path, :string, required: true
  attr :current_scope, :map, required: true
  slot :inner_block, required: true

  def settings_shell(assigns) do
    assigns = assign(assigns, :groups, destinations(assigns.current_scope))

    ~H"""
    <div class="flex flex-col md:flex-row gap-8">
      <div class="md:hidden">
        <label for="settings-destination" class="block mb-2 text-sm font-medium">Settings section</label>
        <select
          id="settings-destination"
          phx-hook="SettingsNavigation"
          class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-text-primary)] px-3 py-2"
        >
          <optgroup :for={group <- @groups} label={group.label}>
            <option
              :for={item <- group.items}
              value={item.path}
              data-allowed="true"
              selected={current?(@current_path, item.path)}
            >
              {item.label}
            </option>
          </optgroup>
        </select>
      </div>
      <nav aria-label="Settings sections" class="hidden md:block w-56 shrink-0 space-y-6">
        <div :for={group <- @groups}>
          <h2 class="px-3 mb-2 text-xs font-semibold uppercase tracking-wide text-[var(--color-text-tertiary)]">
            {group.label}
          </h2>
          <ul class="space-y-0.5">
            <.settings_nav_item
              :for={item <- group.items}
              path={item.path}
              current_path={@current_path}
              icon={item.icon}
              label={item.label}
            />
          </ul>
        </div>
      </nav>
      <div class="flex-1 min-w-0">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp current?(current_path, path),
    do: current_path == path or String.starts_with?(current_path, path <> "/")

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp settings_nav_item(assigns) do
    active = current?(assigns.current_path, assigns.path)
    assigns = assign(assigns, :active, active)

    ~H"""
    <li>
      <.link
        navigate={@path}
        aria-current={@active && "page"}
        class={[
          "flex items-center gap-3 rounded-[var(--radius-md)] px-3 py-2 text-sm font-medium transition-colors duration-150",
          @active &&
            "bg-[var(--color-surface-elevated)] text-[var(--color-accent)] border-s-2 border-[var(--color-accent)]",
          !@active &&
            "text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-elevated)] hover:text-[var(--color-text-primary)]"
        ]}
      >
        <.icon name={@icon} class="size-5 shrink-0" />
        {@label}
      </.link>
    </li>
    """
  end
end
