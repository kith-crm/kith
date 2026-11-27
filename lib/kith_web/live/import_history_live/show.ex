defmodule KithWeb.ImportHistoryLive.Show do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Imports

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Imports.get_import(scope, id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Not found") |> redirect(to: ~p"/settings/imports")}

      import_record ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{scope.account.id}")
        end

        contact_names = load_contact_names(import_record)

        {:ok,
         socket
         |> assign(:page_title, "Import Details")
         |> assign(:import, import_record)
         |> assign(:contact_names, contact_names)}
    end
  end

  @impl true
  def handle_info({:import_misc_complete, _counts}, socket) do
    scope = socket.assigns.current_scope
    import = Imports.get_import(scope, socket.assigns.import.id)
    {:noreply, if(import, do: assign(socket, :import, import), else: socket)}
  end

  def handle_info({:sync_complete, summary}, socket) do
    scope = socket.assigns.current_scope
    import_record = Imports.get_import(scope, socket.assigns.import.id)

    if import_record do
      contact_names = load_contact_names(%{import_record | sync_summary: summary})

      {:noreply,
       socket
       |> assign(:import, %{import_record | sync_summary: summary})
       |> assign(:contact_names, contact_names)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp load_contact_names(%{sync_summary: %{"photos" => photos}}) when is_list(photos) do
    photos
    |> Enum.map(& &1["contact_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Contacts.get_contact_names()
  end

  defp load_contact_names(_), do: %{}

  defp contact_name(photo, contact_names) do
    case Map.get(contact_names, photo["contact_id"]) do
      nil -> "Deleted contact"
      name -> name
    end
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
      <.settings_shell current_path={~p"/settings/imports"} current_scope={@current_scope}>
        <div class="space-y-6">
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/settings/imports"}
              class="text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
            >
              <.icon name="hero-arrow-left" class="size-5" />
            </.link>
            <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">Import Details</h1>
          </div>

          <%!-- Import metadata --%>
          <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] p-5 space-y-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-[var(--color-text-secondary)]">
              Import Info
            </h2>
            <dl class="grid grid-cols-2 gap-x-8 gap-y-3 sm:grid-cols-4">
              <.detail_item label="Source" value={source_label(@import.source)} />
              <.detail_item label="File" value={@import.file_name || "—"} />
              <.detail_item label="Status" value={@import.status} />
              <.detail_item label="Date" value={format_date(@import.inserted_at)} />
            </dl>

            <%= if @import.summary do %>
              <div class="border-t border-[var(--color-border)] pt-3 mt-3">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-[var(--color-text-secondary)] mb-2">
                  Import Summary
                </h3>
                <dl class="grid grid-cols-2 gap-x-8 gap-y-2 sm:grid-cols-4">
                  <.detail_item
                    :for={{key, val} <- summary_items(@import.summary)}
                    label={key}
                    value={to_string(val)}
                  />
                </dl>
                <p
                  :for={{label, count} <- skipped_features(@import.summary)}
                  class="mt-2 text-sm"
                >
                  {label} skipped for {count} {if count == 1, do: "contact", else: "contacts"} because the feature was disabled.
                </p>
              </div>
            <% end %>
          </div>

          <%!-- Photo sync section --%>
          <%= if @import.sync_summary do %>
            <.photo_sync_section sync={@import.sync_summary} contact_names={@contact_names} />
          <% else %>
            <%= if @import.api_options && (@import.api_options["photos"] || @import.api_options[:photos]) do %>
              <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] p-5">
                <h2 class="text-sm font-semibold uppercase tracking-wider text-[var(--color-text-secondary)] mb-3">
                  Photo Sync
                </h2>
                <div class="flex items-center gap-2 text-sm text-[var(--color-text-secondary)]">
                  <.icon name="hero-arrow-path" class="size-4 animate-spin" />
                  Photo sync in progress...
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :sync, :map, required: true
  attr :contact_names, :map, required: true

  defp photo_sync_section(assigns) do
    ~H"""
    <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] p-5 space-y-4">
      <h2 class="text-sm font-semibold uppercase tracking-wider text-[var(--color-text-secondary)]">
        Photo Sync
      </h2>

      <%!-- Summary counts --%>
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.sync_stat_card label="Total" value={@sync["total"] || 0} />
        <.sync_stat_card label="Synced" value={@sync["synced"] || 0} color="text-green-600" />
        <.sync_stat_card label="Failed" value={@sync["failed"] || 0} color="text-red-600" />
        <.sync_stat_card label="Not Found" value={@sync["not_found"] || 0} color="text-yellow-600" />
      </div>

      <%!-- Progress bar --%>
      <% total = @sync["total"] || 0 %>
      <% synced = @sync["synced"] || 0 %>
      <% pct = if total > 0, do: round(synced / total * 100), else: 0 %>
      <div class="w-full bg-[var(--color-surface-elevated)] rounded-full h-2">
        <div
          class="bg-green-500 h-2 rounded-full transition-all duration-300"
          style={"width: #{pct}%"}
        >
        </div>
      </div>

      <%!-- Per-photo table --%>
      <%= if photos = @sync["photos"] do %>
        <div class="overflow-hidden rounded-[var(--radius-md)] border border-[var(--color-border)]">
          <table class="min-w-full divide-y divide-[var(--color-border)]">
            <thead class="bg-[var(--color-surface-elevated)]">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-[var(--color-text-secondary)]">
                  File
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-[var(--color-text-secondary)]">
                  Contact
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-[var(--color-text-secondary)]">
                  Status
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-[var(--color-text-secondary)]">
                  Details
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-[var(--color-border)]">
              <tr :for={photo <- photos} class="text-sm">
                <td class="px-4 py-2 text-[var(--color-text-primary)]">
                  {photo["file_name"] || "—"}
                </td>
                <td class="px-4 py-2 text-[var(--color-text-secondary)]">
                  {contact_name(photo, @contact_names)}
                </td>
                <td class="px-4 py-2">
                  <.photo_status_badge status={photo["status"]} />
                </td>
                <td class="px-4 py-2 text-xs text-[var(--color-text-tertiary)]">
                  {photo["reason"] || ""}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, default: "text-[var(--color-text-primary)]"

  defp sync_stat_card(assigns) do
    ~H"""
    <div class="rounded-[var(--radius-md)] bg-[var(--color-surface-elevated)] p-3 text-center">
      <p class={["text-2xl font-bold", @color]}>{@value}</p>
      <p class="text-xs text-[var(--color-text-secondary)] mt-1">{@label}</p>
    </div>
    """
  end

  attr :status, :string, required: true

  defp photo_status_badge(assigns) do
    {color, label} =
      case assigns.status do
        "synced" -> {"text-green-700 bg-green-100", "Synced"}
        "failed" -> {"text-red-700 bg-red-100", "Failed"}
        "not_found" -> {"text-yellow-700 bg-yellow-100", "Not Found"}
        _ -> {"text-gray-700 bg-gray-100", assigns.status || "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium", @color]}>
      {@label}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail_item(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-[var(--color-text-tertiary)]">{@label}</dt>
      <dd class="text-sm font-medium text-[var(--color-text-primary)]">{@value}</dd>
    </div>
    """
  end

  defp source_label("monica"), do: "Monica"
  defp source_label("vcard"), do: "vCard"
  defp source_label(other), do: other

  defp format_date(nil), do: "—"
  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M")

  defp skipped_features(summary) do
    alias Kith.Accounts.OptionalFeatures

    progress = Map.values(summary["misc_progress"] || %{})

    for key <- OptionalFeatures.monica_keys(),
        skip_key = OptionalFeatures.monica_skip_key(key),
        count = Enum.count(progress, &match?(%{^skip_key => 1}, &1[key])),
        count > 0,
        do: {OptionalFeatures.label(key), count}
  end

  defp summary_items(summary) when is_map(summary) do
    summary
    |> Enum.filter(fn {_k, v} -> is_integer(v) end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> {humanize_key(k), v} end)
  end

  defp summary_items(_), do: []

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_key(key) when is_atom(key), do: humanize_key(Atom.to_string(key))
end
