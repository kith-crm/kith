defmodule KithWeb.ContactLive.RemindersComponent do
  use KithWeb, :live_component

  alias Kith.Reminders

  @type_options [
    {"One-time", "one_time"},
    {"Recurring", "recurring"},
    {"Stay in touch", "stay_in_touch"}
  ]

  @frequency_options [
    {"Weekly", "weekly"},
    {"Every 2 weeks", "biweekly"},
    {"Monthly", "monthly"},
    {"Every 3 months", "3months"},
    {"Every 6 months", "6months"},
    {"Annually", "annually"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:reminders, [])
     |> assign(:show_form, false)
     |> assign(:form_type, "one_time")}
  end

  @impl true
  def update(assigns, socket) do
    reminders = Reminders.list_reminders(assigns.account_id, assigns.contact_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:reminders, reminders)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply, socket |> assign(:show_form, true) |> assign(:form_type, "one_time")}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("type-changed", %{"reminder" => %{"type" => type}}, socket) do
    {:noreply, assign(socket, :form_type, type)}
  end

  def handle_event("save", %{"reminder" => params}, socket) do
    attrs =
      params
      |> Map.put("contact_id", socket.assigns.contact_id)
      |> Map.put("account_id", socket.assigns.account_id)
      |> Map.put("creator_id", socket.assigns.creator_id)

    case Reminders.create_reminder(socket.assigns.account_id, socket.assigns.creator_id, attrs) do
      {:ok, _} ->
        reminders = Reminders.list_reminders(socket.assigns.account_id, socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:reminders, reminders)
         |> assign(:show_form, false)
         |> put_flash(:info, "Reminder added.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    reminder = Reminders.get_reminder!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Reminders.delete_reminder(reminder)
    reminders = Reminders.list_reminders(socket.assigns.account_id, socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:reminders, reminders)
     |> put_flash(:info, "Reminder deleted.")}
  end

  defp type_label("birthday"), do: "Birthday"
  defp type_label("stay_in_touch"), do: "Stay in touch"
  defp type_label("one_time"), do: "One-time"
  defp type_label("recurring"), do: "Recurring"
  defp type_label(_), do: "Reminder"

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp needs_frequency?(type) when type in ["recurring", "stay_in_touch"], do: true
  defp needs_frequency?(_), do: false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:type_options, @type_options)
      |> assign(:frequency_options, @frequency_options)

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-sm font-medium">Reminders</h3>
        <button
          :if={@can_edit && !@show_form}
          phx-click="show-form"
          phx-target={@myself}
          class="text-[var(--color-accent)] text-xs font-medium cursor-pointer hover:underline"
        >
          Add
        </button>
      </div>

      <%= if @show_form do %>
        <div class="rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface)] p-2.5 mb-2">
          <.form for={%{}} phx-submit="save" phx-change="type-changed" phx-target={@myself}>
            <div class="space-y-2">
              <div>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  Type
                </label>
                <select
                  name="reminder[type]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                  required
                >
                  <%= for {label, value} <- @type_options do %>
                    <option value={value} selected={value == @form_type}>{label}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  Title (optional)
                </label>
                <input
                  type="text"
                  name="reminder[title]"
                  placeholder="e.g. Call back"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                />
              </div>
              <div :if={needs_frequency?(@form_type)}>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  Frequency
                </label>
                <select
                  name="reminder[frequency]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                  required
                >
                  <%= for {label, value} <- @frequency_options do %>
                    <option value={value}>{label}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  First date
                </label>
                <input
                  type="date"
                  name="reminder[anchor_date]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                  required
                  min={Date.utc_today()}
                />
              </div>
            </div>
            <div class="flex gap-2 mt-2.5">
              <button
                type="submit"
                class="inline-flex items-center gap-1 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-2.5 py-1 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel-form"
                phx-target={@myself}
                class="rounded-[var(--radius-md)] px-2.5 py-1 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>
      <% end %>

      <%= if @reminders == [] and not @show_form do %>
        <p class="text-xs text-[var(--color-text-tertiary)] flex items-center gap-1.5">
          <.icon name="hero-bell" class="size-3.5 text-[var(--color-text-disabled)]" />
          No reminders set.
        </p>
      <% else %>
        <div class="space-y-2">
          <%= for reminder <- @reminders do %>
            <div class="flex items-start gap-2 text-sm group">
              <.icon
                name={if reminder.active, do: "hero-bell", else: "hero-bell-slash"}
                class={[
                  "size-4 mt-0.5",
                  reminder.active && "text-[var(--color-accent)]",
                  !reminder.active && "text-[var(--color-text-disabled)]"
                ]}
              />
              <div class="flex-1 min-w-0">
                <div class={[!reminder.active && "text-[var(--color-text-tertiary)]"]}>
                  {reminder.title || type_label(reminder.type)}
                </div>
                <div class="text-xs text-[var(--color-text-tertiary)]">
                  {type_label(reminder.type)}
                  <span :if={Kith.Reminders.Reminder.interval_label(reminder)}>
                    &middot; {Kith.Reminders.Reminder.interval_label(reminder)}
                  </span>
                </div>
                <div class="text-xs text-[var(--color-text-tertiary)]">
                  Next: <.date_display date={reminder.next_reminder_date} />
                </div>
              </div>
              <button
                :if={@can_edit && reminder.type != "birthday"}
                phx-click="delete"
                phx-value-id={reminder.id}
                phx-target={@myself}
                data-confirm="Delete this reminder?"
                class="opacity-0 group-hover:opacity-100 text-[var(--color-text-tertiary)] hover:text-[var(--color-error)] transition-all cursor-pointer"
                title="Delete reminder"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
