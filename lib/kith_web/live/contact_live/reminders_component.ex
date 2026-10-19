defmodule KithWeb.ContactLive.RemindersComponent do
  use KithWeb, :live_component

  alias Kith.Reminders

  # Owned by the contact's dates; never edited or deleted directly (the API
  # refuses them the same way).
  @derived_types ["birthday", "first_met"]

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
    {"Annually", "annually"},
    {"Custom…", "custom"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:reminders, [])
     |> assign(:show_form, false)
     |> assign(:form_error, nil)
     |> assign(:form_type, "one_time")
     |> assign(:form_frequency, "weekly")}
  end

  @impl true
  def update(assigns, socket) do
    reminders = Reminders.list_contact_reminders(assigns.account_id, assigns.contact_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:reminders, reminders)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_error, nil)
     |> assign(:form_type, "one_time")
     |> assign(:form_frequency, "weekly")}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("type-changed", %{"reminder" => params}, socket) do
    {:noreply,
     socket
     |> assign(:form_type, params["type"] || socket.assigns.form_type)
     |> assign(:form_frequency, params["frequency"] || socket.assigns.form_frequency)}
  end

  def handle_event("save", %{"reminder" => params}, socket) do
    attrs =
      params
      |> normalize_schedule()
      |> Map.put("contact_id", socket.assigns.contact_id)
      |> Map.put("account_id", socket.assigns.account_id)
      |> Map.put("creator_id", socket.assigns.creator_id)

    case Reminders.create_reminder(socket.assigns.account_id, socket.assigns.creator_id, attrs) do
      {:ok, _} ->
        reminders =
          Reminders.list_contact_reminders(socket.assigns.account_id, socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:reminders, reminders)
         |> assign(:show_form, false)
         |> assign(:form_error, nil)
         |> put_flash(:info, "Reminder added.")}

      {:error, changeset} ->
        # A component's put_flash is not rendered by the parent LiveView, so
        # the error is shown inline and the form stays open.
        {:noreply, assign(socket, :form_error, format_errors(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    reminder = Reminders.get_reminder!(socket.assigns.account_id, String.to_integer(id))

    if derived?(reminder) do
      {:noreply,
       put_flash(socket, :error, "Birthday and first-met reminders are managed from the contact.")}
    else
      delete_reminder(reminder, socket)
    end
  end

  defp derived?(reminder), do: reminder.type in @derived_types

  defp delete_reminder(reminder, socket) do
    {:ok, _} = Reminders.delete_reminder(reminder)

    reminders =
      Reminders.list_contact_reminders(socket.assigns.account_id, socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:reminders, reminders)
     |> put_flash(:info, "Reminder deleted.")}
  end

  # "Custom…" sends unit + count; a preset sends only its name.
  defp normalize_schedule(%{"frequency" => "custom"} = params),
    do: Map.delete(params, "frequency")

  defp normalize_schedule(params), do: Map.drop(params, ["interval_unit", "interval_count"])

  defp type_label("birthday"), do: "Birthday"
  defp type_label("first_met"), do: "First met"
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
    <div id={@id}>
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
              <p
                :if={@form_error}
                id={"reminder-form-error-#{@contact_id}"}
                role="alert"
                class="text-xs text-[var(--color-error)]"
              >
                {@form_error}
              </p>
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
                    <option value={value} selected={value == @form_frequency}>{label}</option>
                  <% end %>
                </select>
              </div>
              <div
                :if={needs_frequency?(@form_type) and @form_frequency == "custom"}
                class="flex items-center gap-2"
              >
                <span class="text-xs text-[var(--color-text-secondary)]">Every</span>
                <input
                  type="number"
                  name="reminder[interval_count]"
                  min="1"
                  required
                  class="w-16 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                />
                <select
                  name="reminder[interval_unit]"
                  class="rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                >
                  <option value="day" selected>days</option>
                  <option value="week">weeks</option>
                  <option value="month">months</option>
                  <option value="year">years</option>
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
              <div>
                <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
                  Description (optional)
                </label>
                <textarea
                  name="reminder[description]"
                  rows="2"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs"
                ></textarea>
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
                <div
                  :if={reminder.description}
                  class="text-xs text-[var(--color-text-secondary)] whitespace-pre-line"
                >
                  {reminder.description}
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
                :if={@can_edit && not derived?(reminder)}
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
