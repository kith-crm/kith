defmodule KithWeb.Layouts do
  @moduledoc """
  Layout components for the Kith application.

  - `root.html.heex` — HTML skeleton (embedded via embed_templates)
  - `app/1` — Authenticated app shell with sidebar navigation
  - `auth/1` — Centered card layout for authentication pages
  """
  use KithWeb, :html

  embed_templates "layouts/*"

  # ==========================================================================
  # App Layout (authenticated shell)
  # ==========================================================================

  @doc """
  Renders the authenticated app shell with sidebar navigation.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :current_path, :string, default: "/"
  attr :pending_duplicates_count, :integer, default: 0
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div
      class="flex h-screen bg-[var(--color-surface)]"
      x-data="sidebar"
    >
      <%!-- Desktop sidebar --%>
      <aside
        class="hidden md:flex flex-col border-e border-[var(--color-border-subtle)] bg-[var(--color-surface-sunken)] transition-all duration-200 ease-[var(--ease-snappy)]"
        x-bind:class="sidebarOpen ? 'w-60' : 'w-[60px]'"
      >
        <%!-- Logo & collapse toggle --%>
        <div class="flex items-center justify-between p-4 h-14">
          <a
            href="/"
            class="text-lg font-semibold text-[var(--color-text-primary)] tracking-tight"
            x-show="sidebarOpen"
            x-transition
          >
            Kith
          </a>
          <button
            x-on:click="toggle()"
            class="rounded-[var(--radius-md)] p-1.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-elevated)] transition-colors duration-150 cursor-pointer"
            aria-label="Toggle sidebar"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
        </div>

        <%!-- Navigation links --%>
        <nav class="flex-1 py-3 px-2 space-y-0.5">
          <.sidebar_link
            path={~p"/dashboard"}
            current_path={@current_path}
            icon="hero-home"
            label="Dashboard"
          />
          <.sidebar_link
            path={~p"/contacts"}
            current_path={@current_path}
            icon="hero-user-group"
            label="Contacts"
            match_prefix="/contacts"
            badge_count={@pending_duplicates_count}
          />
          <.sidebar_link
            path={~p"/reminders/upcoming"}
            current_path={@current_path}
            icon="hero-bell"
            label="Reminders"
            match_prefix="/reminders"
          />
          <.sidebar_link
            path={~p"/journal"}
            current_path={@current_path}
            icon="hero-book-open"
            label="Journal"
            match_prefix="/journal"
          />
          <.sidebar_link
            path={~p"/users/settings"}
            current_path={@current_path}
            icon="hero-cog-6-tooth"
            label="Settings"
            match_prefix="/settings"
          />
          <.sidebar_link
            :if={Kith.Policy.can?(@current_scope.user, :manage, :oban)}
            path={~p"/admin/oban"}
            current_path={@current_path}
            icon="hero-queue-list"
            label="Jobs"
            match_prefix="/admin"
          />
        </nav>

        <%!-- Cmd+K hint --%>
        <div class="px-3 pb-2" x-show="sidebarOpen" x-transition>
          <button
            class="flex items-center gap-2 w-full rounded-[var(--radius-md)] px-3 py-2 text-sm text-[var(--color-text-tertiary)] bg-[var(--color-surface-elevated)] border border-[var(--color-border-subtle)] hover:border-[var(--color-border)] transition-colors duration-150 cursor-pointer"
            phx-click={JS.dispatch("kith:open-command-palette")}
          >
            <.icon name="hero-magnifying-glass" class="size-4" />
            <span class="flex-1 text-start">Search...</span>
            <kbd class="text-[10px] font-mono text-[var(--color-text-disabled)] border border-[var(--color-border)] rounded px-1 py-0.5">
              ⌘K
            </kbd>
          </button>
        </div>

        <%!-- User footer --%>
        <%= if @current_scope && @current_scope.user do %>
          <div class="border-t border-[var(--color-border-subtle)] p-2" x-data="userMenu">
            <button
              class="flex items-center gap-2 w-full rounded-[var(--radius-md)] p-2 hover:bg-[var(--color-surface-elevated)] transition-colors duration-150 cursor-pointer"
              x-on:click="toggle"
            >
              <div class="size-8 rounded-full bg-[var(--color-accent)] text-[var(--color-accent-foreground)] flex items-center justify-center text-xs font-semibold shrink-0">
                {user_initials(@current_scope.user)}
              </div>
              <span
                class="text-sm text-[var(--color-text-secondary)] truncate"
                x-show="sidebarOpen"
                x-transition
              >
                {@current_scope.user.email}
              </span>
            </button>
            <div
              x-show="userMenu"
              x-on:click.outside="close"
              x-transition:enter="transition ease-out duration-200"
              x-transition:enter-start="opacity-0 scale-95"
              x-transition:enter-end="opacity-100 scale-100"
              x-transition:leave="transition ease-in duration-150"
              x-transition:leave-start="opacity-100 scale-100"
              x-transition:leave-end="opacity-0 scale-95"
              class="mt-1 py-1 rounded-[var(--radius-lg)] bg-[var(--color-surface-overlay)] border border-[var(--color-border)] shadow-[var(--shadow-dropdown)]"
              style="display: none;"
            >
              <.link
                navigate={~p"/users/settings"}
                class="flex items-center gap-2 px-3 py-2 text-sm text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors"
              >
                <.icon name="hero-cog-6-tooth" class="size-4 text-[var(--color-text-tertiary)]" />
                Settings
              </.link>
              <div class="my-1 border-t border-[var(--color-border-subtle)]" />
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="flex items-center gap-2 px-3 py-2 text-sm text-[var(--color-error)] hover:bg-[var(--color-surface-sunken)] transition-colors"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
              </.link>
            </div>
          </div>
        <% end %>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Mobile top bar --%>
        <header class="md:hidden flex items-center justify-between px-4 h-14 border-b border-[var(--color-border-subtle)] bg-[var(--color-surface-sunken)]">
          <a href="/" class="text-lg font-semibold text-[var(--color-text-primary)] tracking-tight">
            Kith
          </a>
          <%= if @current_scope && @current_scope.user do %>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="rounded-[var(--radius-md)] p-2 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-elevated)] transition-colors"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
            </.link>
          <% end %>
        </header>

        <%!-- Page content --%>
        <main class="flex-1 overflow-y-auto">
          <div class="max-w-6xl mx-auto px-4 py-6 sm:px-6 lg:px-8">
            <.flash_group flash={@flash} />
            <KithUI.command_palette />
            {render_slot(@inner_block)}
          </div>
        </main>

        <%!-- Mobile bottom nav --%>
        <nav class="md:hidden flex items-center justify-around border-t border-[var(--color-border-subtle)] bg-[var(--color-surface-sunken)] py-2">
          <.mobile_nav_link
            path={~p"/dashboard"}
            current_path={@current_path}
            icon="hero-home"
            label="Home"
          />
          <.mobile_nav_link
            path={~p"/contacts"}
            current_path={@current_path}
            icon="hero-user-group"
            label="Contacts"
            match_prefix="/contacts"
          />
          <.mobile_nav_link
            path={~p"/reminders/upcoming"}
            current_path={@current_path}
            icon="hero-bell"
            label="Reminders"
            match_prefix="/reminders"
          />
          <.mobile_nav_link
            path={~p"/journal"}
            current_path={@current_path}
            icon="hero-book-open"
            label="Journal"
            match_prefix="/journal"
          />
          <.mobile_nav_link
            path={~p"/users/settings"}
            current_path={@current_path}
            icon="hero-cog-6-tooth"
            label="Settings"
            match_prefix="/settings"
          />
          <.mobile_nav_link
            :if={Kith.Policy.can?(@current_scope.user, :manage, :oban)}
            path={~p"/admin/oban"}
            current_path={@current_path}
            icon="hero-queue-list"
            label="Jobs"
            match_prefix="/admin"
          />
        </nav>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Auth Layout (unauthenticated pages)
  # ==========================================================================

  @doc """
  Renders a centered card layout for authentication pages.

  ## Examples

      <Layouts.auth flash={@flash}>
        <.simple_form for={@form} phx-submit="login">
          ...
        </.simple_form>
      </Layouts.auth>
  """
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center px-4 py-12 bg-[var(--color-surface)]">
      <%!-- Logo --%>
      <a href="/" class="mb-8">
        <span class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
          Kith
        </span>
      </a>

      <%!-- Flash messages --%>
      <div class="w-full max-w-md mb-4">
        <.flash_group flash={@flash} />
      </div>

      <%!-- Auth card --%>
      <div class="w-full max-w-md rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-[var(--shadow-card)] p-8">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Sidebar link component
  # ==========================================================================

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :match_prefix, :string, default: nil
  attr :badge_count, :integer, default: 0

  defp sidebar_link(assigns) do
    active = active?(assigns.current_path, assigns.path, assigns.match_prefix)
    assigns = assign(assigns, :active, active)

    ~H"""
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
      <span x-show="sidebarOpen" x-transition>{@label}</span>
      <%= if @badge_count > 0 do %>
        <span
          x-show="sidebarOpen"
          class="ms-auto bg-[var(--color-warning-subtle)] text-[var(--color-warning)] text-xs font-semibold px-2 py-0.5 rounded-[var(--radius-full)]"
        >
          {@badge_count}
        </span>
      <% end %>
    </.link>
    """
  end

  # ==========================================================================
  # Mobile nav link component
  # ==========================================================================

  attr :path, :string, required: true
  attr :current_path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :match_prefix, :string, default: nil

  defp mobile_nav_link(assigns) do
    active = active?(assigns.current_path, assigns.path, assigns.match_prefix)
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      aria-current={@active && "page"}
      class={[
        "flex flex-col items-center gap-1 px-3 py-1 text-xs transition-colors duration-150",
        @active && "text-[var(--color-accent)]",
        !@active && "text-[var(--color-text-tertiary)]"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span>{@label}</span>
    </.link>
    """
  end

  # ==========================================================================
  # Flash group
  # ==========================================================================

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # ==========================================================================
  # Theme toggle
  # ==========================================================================

  @doc """
  Provides dark vs light theme toggle — pill style.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center border border-[var(--color-border)] bg-[var(--color-surface-sunken)] rounded-[var(--radius-full)] p-0.5">
      <div class="absolute w-1/3 h-[calc(100%-4px)] rounded-[var(--radius-full)] bg-[var(--color-surface-elevated)] shadow-sm start-0.5 [[data-theme=light]_&]:start-[calc(33.33%)] [[data-theme=dark]_&]:start-[calc(66.66%-2px)] transition-[inset-inline-start] duration-200" />

      <button
        class="relative flex p-1.5 cursor-pointer w-1/3 justify-center z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon
          name="hero-computer-desktop-micro"
          class="size-3.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] transition-colors"
        />
      </button>

      <button
        class="relative flex p-1.5 cursor-pointer w-1/3 justify-center z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon
          name="hero-sun-micro"
          class="size-3.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] transition-colors"
        />
      </button>

      <button
        class="relative flex p-1.5 cursor-pointer w-1/3 justify-center z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon
          name="hero-moon-micro"
          class="size-3.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] transition-colors"
        />
      </button>
    </div>
    """
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp active?(current_path, exact_path, nil), do: current_path == exact_path

  defp active?(current_path, _exact_path, prefix),
    do: String.starts_with?(current_path, prefix)

  defp user_initials(%{email: email}) do
    email
    |> String.first()
    |> String.upcase()
  end
end
