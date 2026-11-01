defmodule KithWeb.SettingsLive.AuditLog do
  @moduledoc """
  Settings > Audit Log page. Admin-only.

  Displays a paginated, filterable table of audit events for the account.
  Uses cursor-based pagination.
  """

  use KithWeb, :live_view

  alias Kith.AuditLogs
  alias Kith.AuditLogs.AuditLog

  import KithWeb.SettingsLive.SettingsLayout

  @event_labels %{
    "contact_created" => "Contact created",
    "contact_updated" => "Contact updated",
    "contact_archived" => "Contact archived",
    "contact_restored" => "Contact restored",
    "contact_deleted" => "Contact deleted",
    "contact_purged" => "Contact purged",
    "contact_merged" => "Contacts merged",
    "reminder_fired" => "Reminder fired",
    "user_joined" => "User joined",
    "user_role_changed" => "User role changed",
    "user_removed" => "User removed",
    "invitation_sent" => "Invitation sent",
    "invitation_accepted" => "Invitation accepted",
    "account_data_reset" => "Account data reset",
    "account_deleted" => "Account deleted",
    "immich_linked" => "Immich linked",
    "immich_unlinked" => "Immich unlinked",
    "data_exported" => "Data exported",
    "data_imported" => "Data imported"
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if Kith.Policy.can?(user, :manage, :account) do
      {:ok,
       socket
       |> assign(:page_title, "Audit Log")
       |> assign(:filters, %{})
       |> assign(:entries, [])
       |> assign(:has_more, false)
       |> assign(:next_cursor, nil)
       |> assign(:event_options, event_options())
       |> load_entries()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to view the audit log.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = %{
      "event_type" => blank_to_nil(params["event_type"]),
      "contact_name" => blank_to_nil(params["contact_name"]),
      "user_name" => blank_to_nil(params["user_name"]),
      "date_from" => blank_to_nil(params["date_from"]),
      "date_to" => blank_to_nil(params["date_to"])
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:next_cursor, nil)
     |> load_entries()}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{})
     |> assign(:next_cursor, nil)
     |> load_entries()}
  end

  def handle_event("next-page", _params, socket) do
    {:noreply, load_entries(socket)}
  end

  defp load_entries(socket) do
    account_id = socket.assigns.current_scope.account.id

    filters =
      socket.assigns.filters
      |> Map.put("cursor", socket.assigns.next_cursor)

    {entries, meta} = AuditLogs.list_audit_logs(account_id, filters)

    socket
    |> assign(:entries, entries)
    |> assign(:has_more, meta.has_more)
    |> assign(:next_cursor, meta.next_cursor)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(val), do: val

  defp event_options do
    AuditLog.valid_events()
    |> Enum.map(fn event -> {Map.get(@event_labels, event, event), event} end)
  end

  defp event_label(event) do
    Map.get(@event_labels, event, event)
  end

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(%DateTime{} = dt) do
    case Kith.Cldr.DateTime.to_string(dt, format: :medium) do
      {:ok, str} -> str
      _ -> to_string(dt)
    end
  end

  defp metadata_summary(nil), do: ""
  defp metadata_summary(meta) when meta == %{}, do: ""

  defp metadata_summary(meta) when is_map(meta) do
    meta
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> String.slice(0, 120)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <.settings_shell current_path={@current_path} current_scope={@current_scope}>
        <UI.header>
          Audit Log
          <:subtitle>View a history of actions performed on this account</:subtitle>
        </UI.header>

        <%!-- Filters --%>
        <form
          id="audit-log-filter-form"
          phx-change="filter"
          phx-submit="filter"
          class="mt-6 grid grid-cols-1 md:grid-cols-5 gap-3"
        >
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-tertiary)] mb-1">
              Event Type
            </label>
            <select
              name="event_type"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            >
              <option value="">All events</option>
              <option
                :for={{label, value} <- @event_options}
                value={value}
                selected={@filters["event_type"] == value}
              >
                {label}
              </option>
            </select>
          </div>
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-tertiary)] mb-1">
              Contact Name
            </label>
            <input
              type="text"
              name="contact_name"
              value={@filters["contact_name"]}
              placeholder="Search..."
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              phx-debounce="300"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-tertiary)] mb-1">
              User Name
            </label>
            <input
              type="text"
              name="user_name"
              value={@filters["user_name"]}
              placeholder="Search..."
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              phx-debounce="300"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-tertiary)] mb-1">
              From
            </label>
            <input
              type="date"
              name="date_from"
              value={@filters["date_from"]}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-tertiary)] mb-1">To</label>
            <input
              type="date"
              name="date_to"
              value={@filters["date_to"]}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
        </form>

        <div class="mt-2">
          <button
            phx-click="clear-filters"
            class="text-xs font-medium text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
          >
            Clear filters
          </button>
        </div>

        <%!-- Table --%>
        <div class="mt-4 rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] overflow-hidden">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-[var(--color-border)]">
                <th class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
                  Timestamp
                </th>
                <th class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
                  User
                </th>
                <th class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
                  Event
                </th>
                <th class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
                  Contact
                </th>
                <th class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
                  Details
                </th>
              </tr>
            </thead>
            <tbody>
              <%= if @entries == [] do %>
                <tr>
                  <td colspan="5" class="text-center text-[var(--color-text-tertiary)] py-12">
                    No audit log entries found.
                  </td>
                </tr>
              <% else %>
                <tr
                  :for={entry <- @entries}
                  class="border-b border-[var(--color-border-subtle)] hover:bg-[var(--color-surface-sunken)] transition-colors duration-150"
                >
                  <td class="px-4 py-3 text-xs whitespace-nowrap text-[var(--color-text-secondary)]">
                    {format_timestamp(entry.inserted_at)}
                  </td>
                  <td class="px-4 py-3 text-[var(--color-text-primary)]">{entry.user_name}</td>
                  <td class="px-4 py-3">
                    <UI.badge>{event_label(entry.event)}</UI.badge>
                  </td>
                  <td class="px-4 py-3">
                    <%= if entry.contact_id && entry.contact_name do %>
                      <.link
                        navigate={~p"/contacts/#{entry.contact_id}"}
                        class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                      >
                        {entry.contact_name}
                      </.link>
                    <% else %>
                      <span class="text-[var(--color-text-tertiary)]">
                        {entry.contact_name || "-"}
                      </span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-xs text-[var(--color-text-tertiary)] max-w-xs truncate">
                    {metadata_summary(entry.metadata)}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <%!-- Pagination --%>
        <div :if={@has_more} class="mt-4 flex justify-center">
          <UI.button variant="ghost" size="sm" phx-click="next-page">Load more</UI.button>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end
end
