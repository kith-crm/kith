defmodule KithWeb.ReminderLive.Upcoming do
  @moduledoc """
  Upcoming Reminders page — shows reminders due within a selectable
  30/60/90-day window. All roles can view and interact.
  """

  use KithWeb, :live_view

  alias Kith.Reminders

  @windows [30, 60, 90]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Upcoming Reminders")
     |> assign(:account_id, socket.assigns.current_scope.account.id)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    window =
      case params do
        %{"window" => w} ->
          parsed = String.to_integer(w)
          if parsed in @windows, do: parsed, else: 30

        _ ->
          30
      end

    {:noreply,
     socket
     |> assign(:window, window)
     |> load_reminders()
     |> load_pending_instances()}
  end

  @impl true
  def handle_event("change-window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: ~p"/reminders/upcoming?window=#{window}")}
  end

  def handle_event("resolve", %{"id" => id}, socket) do
    instance = Kith.Repo.get!(Kith.Reminders.ReminderInstance, id)
    {:ok, _} = Reminders.resolve_instance(instance)

    {:noreply,
     socket
     |> put_flash(:info, "Reminder resolved")
     |> load_reminders()
     |> load_pending_instances()}
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    instance = Kith.Repo.get!(Kith.Reminders.ReminderInstance, id)
    {:ok, _} = Reminders.dismiss_instance(instance)

    {:noreply,
     socket
     |> put_flash(:info, "Reminder dismissed")
     |> load_reminders()
     |> load_pending_instances()}
  end

  def handle_event("snooze-instance", %{"id" => id, "duration" => duration}, socket) do
    instance = Kith.Repo.get!(Kith.Reminders.ReminderInstance, id)

    case Reminders.snooze_instance(instance, duration) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reminder snoozed for #{snooze_label(duration)}")
         |> load_reminders()
         |> load_pending_instances()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not snooze reminder")}
    end
  end

  defp load_reminders(socket) do
    reminders = Reminders.upcoming(socket.assigns.account_id, socket.assigns.window)

    grouped =
      reminders
      |> Enum.group_by(& &1.next_reminder_date)
      |> Enum.sort_by(fn {date, _} -> date end, Date)

    assign(socket, reminders: reminders, grouped_reminders: grouped)
  end

  defp load_pending_instances(socket) do
    instances = Reminders.list_pending_instances(socket.assigns.account_id)

    instance_map = Enum.group_by(instances, & &1.reminder_id)

    assign(socket, :pending_instances, instance_map)
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
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
            Upcoming Reminders
          </h1>

          <%!-- Pill-shaped button group --%>
          <div class="inline-flex rounded-[var(--radius-full)] border border-[var(--color-border)] p-0.5 bg-[var(--color-surface-sunken)]">
            <button
              :for={w <- [30, 60, 90]}
              phx-click="change-window"
              phx-value-window={w}
              class={[
                "px-3.5 py-1 rounded-[var(--radius-full)] text-sm font-medium transition-all duration-200 cursor-pointer",
                if(@window == w,
                  do: "bg-[var(--color-accent)] text-[var(--color-accent-foreground)] shadow-sm",
                  else: "text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
                )
              ]}
            >
              {w} days
            </button>
          </div>
        </div>

        <div :if={@reminders == []}>
          <KithUI.empty_state
            icon="hero-bell-slash"
            title="No upcoming reminders"
            message={"No reminders in the next #{@window} days. Enjoy the quiet!"}
          />
        </div>

        <div :if={@reminders != []} class="space-y-6">
          <div :for={{date, reminders_on_date} <- @grouped_reminders}>
            <h2 class="text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)] mb-3">
              <.date_display date={date} format={:full} />
            </h2>
            <div class="space-y-2">
              <div
                :for={reminder <- reminders_on_date}
                class="flex items-center justify-between p-4 rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] hover:border-[var(--color-border-focus)]/30 transition-colors duration-150"
              >
                <div class="flex items-center gap-4">
                  <div class="flex items-center justify-center size-9 rounded-[var(--radius-lg)] bg-[var(--color-accent-subtle)]">
                    <.icon name={type_icon(reminder.type)} class="size-4 text-[var(--color-accent)]" />
                  </div>
                  <div>
                    <.link
                      navigate={~p"/contacts/#{reminder.contact_id}"}
                      class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                    >
                      {reminder.contact.display_name || reminder.contact.first_name}
                    </.link>
                    <p class="text-sm text-[var(--color-text-tertiary)]">
                      {type_label(reminder.type)}
                      <span :if={reminder.title}>&mdash; {reminder.title}</span>
                    </p>
                  </div>
                </div>

                <div class="flex items-center gap-4">
                  <span class="text-sm text-[var(--color-text-secondary)]">
                    <.date_display date={reminder.next_reminder_date} />
                  </span>
                  <%= if authorized?(@current_scope.user, :update, :reminder) do %>
                    <div
                      :for={instance <- Map.get(@pending_instances, reminder.id, [])}
                      class="flex gap-2"
                    >
                      <button
                        phx-click="resolve"
                        phx-value-id={instance.id}
                        class="inline-flex items-center gap-1 rounded-[var(--radius-md)] px-2.5 py-1 text-xs font-medium bg-[var(--color-success-subtle)] text-[var(--color-success)] hover:bg-[var(--color-success)]/20 transition-colors cursor-pointer"
                      >
                        Resolve
                      </button>
                      <button
                        phx-click="dismiss"
                        phx-value-id={instance.id}
                        class="inline-flex items-center gap-1 rounded-[var(--radius-md)] px-2.5 py-1 text-xs font-medium bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)] hover:bg-[var(--color-border)] transition-colors cursor-pointer"
                      >
                        Dismiss
                      </button>
                      <details class="relative">
                        <summary class="inline-flex items-center gap-1 rounded-[var(--radius-md)] px-2.5 py-1 text-xs font-medium bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)] hover:bg-[var(--color-border)] transition-colors cursor-pointer list-none">
                          <.icon name="hero-clock" class="size-3.5" /> Snooze
                        </summary>
                        <div class="absolute end-0 top-full mt-1 z-10 w-36 rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-lg py-1">
                          <button
                            :for={
                              {duration, label} <- [
                                {"fifteen_minutes", "15 minutes"},
                                {"one_hour", "1 hour"},
                                {"one_day", "1 day"},
                                {"three_days", "3 days"}
                              ]
                            }
                            phx-click="snooze-instance"
                            phx-value-id={instance.id}
                            phx-value-duration={duration}
                            class="block w-full text-left px-3 py-1.5 text-xs text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                          >
                            {label}
                          </button>
                        </div>
                      </details>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp type_icon("birthday"), do: "hero-cake"
  defp type_icon("stay_in_touch"), do: "hero-hand-raised"
  defp type_icon("one_time"), do: "hero-map-pin"
  defp type_icon("recurring"), do: "hero-arrow-path"
  defp type_icon("first_met"), do: "hero-sparkles"
  defp type_icon(_), do: "hero-bell"

  defp type_label("birthday"), do: "Birthday"
  defp type_label("stay_in_touch"), do: "Stay in touch"
  defp type_label("one_time"), do: "One-time"
  defp type_label("recurring"), do: "Recurring"
  defp type_label("first_met"), do: "First met"
  defp type_label(_), do: "Reminder"

  defp snooze_label("fifteen_minutes"), do: "15 minutes"
  defp snooze_label("one_hour"), do: "1 hour"
  defp snooze_label("one_day"), do: "1 day"
  defp snooze_label("three_days"), do: "3 days"
  defp snooze_label(_), do: "a while"
end
