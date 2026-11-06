defmodule KithWeb.DashboardLive.Index do
  @moduledoc """
  Dashboard page with overview widgets: recent contacts, upcoming reminders,
  activity feed, Immich review badge, and stats summary.
  """

  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Reminders

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount — mount is called twice (HTTP + WS).
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:recent_contacts, [])
     |> assign(:upcoming_count, 0)
     |> assign(:activity_feed, [])
     |> assign(:contact_count, 0)
     |> assign(:note_count, 0)
     |> assign(:immich_review_count, 0)
     |> assign(:immich_dismissed, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    account_id = socket.assigns.current_scope.account.id

    {:noreply,
     socket
     |> assign(:recent_contacts, Contacts.recent_contacts(account_id, 5))
     |> assign(:upcoming_count, Reminders.upcoming_count(account_id))
     |> assign(:activity_feed, load_activity_feed(account_id))
     |> assign(:contact_count, Contacts.contact_count(account_id))
     |> assign(:note_count, Contacts.note_count(account_id))
     |> assign(:immich_review_count, immich_review_count(account_id))}
  end

  @impl true
  def handle_event("dismiss-immich", _params, socket) do
    {:noreply, assign(socket, :immich_dismissed, true)}
  end

  defp load_activity_feed(account_id) do
    Contacts.recent_activity(account_id, 10)
  rescue
    _ -> []
  end

  defp immich_review_count(account_id) do
    Contacts.count_needs_review(account_id)
  rescue
    _ -> 0
  end

  defp activity_icon("note"), do: "hero-document-text"
  defp activity_icon("activity"), do: "hero-calendar"
  defp activity_icon("call"), do: "hero-phone"
  defp activity_icon(_), do: "hero-clock"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="space-y-6">
        <h1 class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
          Dashboard
        </h1>

        <%!-- Immich needs_review banner --%>
        <%= if @immich_review_count > 0 and not @immich_dismissed do %>
          <div
            class="flex items-center justify-between p-4 rounded-[var(--radius-lg)] bg-[var(--color-warning-subtle)] border-s-4 border-[var(--color-warning)]"
            x-data="dismissible"
            x-show="visible"
          >
            <div class="flex items-center gap-3">
              <.icon name="hero-photo" class="size-5 text-[var(--color-warning)]" />
              <span class="text-sm font-medium text-[var(--color-text-primary)]">
                {@immich_review_count} contact(s) need Immich review
              </span>
            </div>
            <div class="flex items-center gap-2">
              <UI.button size="sm" navigate={~p"/contacts/immich-review"}>
                Review
              </UI.button>
              <button
                phx-click="dismiss-immich"
                class="rounded-[var(--radius-md)] p-1.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-elevated)] transition-colors cursor-pointer"
                aria-label="Dismiss"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Stats summary --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <KithUI.stat_card title="Total contacts" value={@contact_count} icon="hero-user-group" />
          <KithUI.stat_card title="Total notes" value={@note_count} icon="hero-document-text" />
          <KithUI.stat_card
            title="Upcoming reminders"
            value={@upcoming_count}
            icon="hero-bell"
            href={~p"/reminders/upcoming"}
          />
          <KithUI.stat_card title="Recent activity" value={length(@activity_feed)} icon="hero-clock" />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Recent contacts --%>
          <UI.card>
            <:header>
              <div class="flex items-center justify-between">
                <span>Recent Contacts</span>
                <.link
                  navigate={~p"/contacts"}
                  class="text-xs font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                >
                  View all
                </.link>
              </div>
            </:header>
            <%= if @recent_contacts == [] do %>
              <KithUI.empty_state
                icon="hero-user-group"
                title="No contacts yet"
                message="Your relationships start here. Add your first contact to get going."
              >
                <:actions>
                  <UI.button size="sm" navigate={~p"/contacts/new"}>
                    Add contact
                  </UI.button>
                </:actions>
              </KithUI.empty_state>
            <% else %>
              <div class="divide-y divide-[var(--color-border-subtle)] -mx-5">
                <.link
                  :for={contact <- @recent_contacts}
                  navigate={~p"/contacts/#{contact.id}"}
                  class="flex items-center gap-3 px-5 py-3 hover:bg-[var(--color-surface-sunken)] transition-colors duration-150"
                >
                  <KithUI.avatar
                    id={"recent-contact-avatar-#{contact.id}"}
                    src={KithUI.avatar_url(contact)}
                    name={contact.display_name}
                    size={:sm}
                  />
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-[var(--color-text-primary)] truncate">
                      {contact.display_name}
                    </p>
                    <div class="flex gap-1 mt-0.5">
                      <KithUI.tag_badge :for={tag <- Enum.take(contact.tags, 3)} tag={tag} />
                    </div>
                  </div>
                  <KithUI.relative_time datetime={contact.updated_at} />
                </.link>
              </div>
            <% end %>
          </UI.card>

          <%!-- Activity feed --%>
          <UI.card>
            <:header>Activity Feed</:header>
            <%= if @activity_feed == [] do %>
              <KithUI.empty_state
                icon="hero-clock"
                title="No recent activity"
                message="Activity will appear here as you add notes, calls, and activities."
              />
            <% else %>
              <div class="divide-y divide-[var(--color-border-subtle)] -mx-5">
                <div :for={item <- @activity_feed} class="flex items-start gap-3 px-5 py-3">
                  <div class="flex items-center justify-center size-7 rounded-[var(--radius-md)] bg-[var(--color-surface-sunken)] shrink-0 mt-0.5">
                    <.icon
                      name={activity_icon(item.type)}
                      class="size-3.5 text-[var(--color-text-tertiary)]"
                    />
                  </div>
                  <div class="flex-1 min-w-0">
                    <p class="text-sm text-[var(--color-text-primary)] truncate">{item.title}</p>
                    <p class="text-xs text-[var(--color-text-tertiary)] mt-0.5">
                      <span class="capitalize">{item.type}</span>
                      · <KithUI.relative_time datetime={item.inserted_at} />
                    </p>
                  </div>
                </div>
              </div>
            <% end %>
          </UI.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
