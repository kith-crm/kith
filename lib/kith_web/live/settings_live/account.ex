defmodule KithWeb.SettingsLive.Account do
  @moduledoc """
  Account Settings page — account name, timezone, send_hour,
  feature module toggles, notification windows, and account deletion.
  Admin-only.
  """

  use KithWeb, :live_view

  alias Kith.Accounts
  alias Kith.Reminders

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> assign(:account, nil)
     |> assign(:rules, [])
     |> assign(:account_form, nil)
     |> assign(:delete_confirmation, "")
     |> assign(:reset_confirmation, "")
     |> assign(:feature_flags, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user = socket.assigns.current_scope.user

    if Kith.Policy.can?(user, :manage, :account) do
      account = socket.assigns.current_scope.account
      rules = Reminders.list_reminder_rules(account.id)

      {:noreply,
       socket
       |> assign(:account, account)
       |> assign(:rules, rules)
       |> assign(:feature_flags, account.feature_flags || %{})
       |> assign(:account_form, to_form(Accounts.Account.settings_changeset(account, %{})))}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You do not have permission to access account settings.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save-account", %{"account" => params}, socket) do
    case Accounts.update_account(socket.assigns.account, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:account, updated)
         |> assign(:account_form, to_form(Accounts.Account.settings_changeset(updated, %{})))
         |> put_flash(:info, "Account settings updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, :account_form, to_form(changeset))}
    end
  end

  def handle_event("toggle-feature", %{"feature" => feature}, socket) do
    account = socket.assigns.account
    user = socket.assigns.current_scope.user
    flags = socket.assigns.feature_flags
    new_flags = Map.update(flags, feature, true, &(!&1))

    case Accounts.update_account(account, %{feature_flags: new_flags}) do
      {:ok, updated} ->
        maybe_log_immich_toggle(account, user, feature, new_flags)

        {:noreply,
         socket
         |> assign(:account, updated)
         |> assign(:feature_flags, updated.feature_flags || %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update feature toggle")}
    end
  end

  def handle_event("toggle-rule", %{"id" => id}, socket) do
    rule = Reminders.get_reminder_rule!(socket.assigns.account.id, String.to_integer(id))

    case Reminders.update_reminder_rule(rule, %{active: !rule.active}) do
      {:ok, _rule} ->
        rules = Reminders.list_reminder_rules(socket.assigns.account.id)
        {:noreply, assign(socket, :rules, rules)}

      {:error, :cannot_deactivate_on_day_rule} ->
        {:noreply, put_flash(socket, :error, "The 'On the day' reminder cannot be turned off")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update rule")}
    end
  end

  def handle_event("validate-delete", %{"confirmation" => value}, socket) do
    {:noreply, assign(socket, :delete_confirmation, value)}
  end

  def handle_event("delete-account", _params, socket) do
    account = socket.assigns.account

    if socket.assigns.delete_confirmation == account.name do
      case Accounts.request_account_deletion(account.id, account.name) do
        {:ok, :queued} ->
          {:noreply, push_navigate(socket, to: ~p"/")}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Failed to initiate account deletion. Please try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Account name does not match.")}
    end
  end

  def handle_event("validate-reset", %{"confirmation" => value}, socket) do
    {:noreply, assign(socket, :reset_confirmation, value)}
  end

  def handle_event("reset-account", _params, socket) do
    account = socket.assigns.account

    if socket.assigns.reset_confirmation == "RESET" do
      case Accounts.request_account_reset(account.id, "RESET") do
        {:ok, :queued} ->
          {:noreply,
           socket
           |> assign(:reset_confirmation, "")
           |> put_flash(
             :info,
             "Account data reset has been queued. All contacts and data will be deleted shortly."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to initiate reset. Please try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Type RESET exactly to confirm.")}
    end
  end

  defp maybe_log_immich_toggle(account, user, "immich", new_flags) do
    event = if Map.get(new_flags, "immich"), do: :immich_linked, else: :immich_unlinked
    Kith.AuditLogs.log_event(account.id, user, event)
  end

  defp maybe_log_immich_toggle(_account, _user, _feature, _flags), do: :ok

  @feature_modules [
    {"reminders", "Reminders", "Enable birthday and event reminders"},
    {"activities", "Activities", "Track activities with contacts"},
    {"calls", "Phone Calls", "Log phone calls with contacts"},
    {"documents", "Documents", "Attach documents to contacts"},
    {"photos", "Photos", "Manage contact photos"},
    {"life_events", "Life Events", "Track important life events"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :feature_modules, @feature_modules)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <.settings_shell current_path={@current_path} current_scope={@current_scope}>
        <UI.header>
          Account Settings
          <:subtitle>Manage your account configuration</:subtitle>
        </UI.header>

        <%= if @account_form do %>
          <%!-- General settings --%>
          <div class="mt-8 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-4">General</h2>

            <UI.simple_form for={@account_form} phx-submit="save-account">
              <UI.input field={@account_form[:name]} type="text" label="Account Name" required />
              <UI.input
                field={@account_form[:timezone]}
                type="text"
                label="Timezone"
                placeholder="America/New_York"
              />
              <UI.input
                field={@account_form[:send_hour]}
                type="select"
                label="Reminder Send Hour"
                options={Enum.map(0..23, fn h -> {"#{String.pad_leading("#{h}", 2, "0")}:00", h} end)}
              />
              <p class="text-xs text-[var(--color-text-tertiary)] -mt-2">
                Changing timezone affects when reminders are sent. Changes take effect starting the following day.
              </p>
              <UI.input
                field={@account_form[:phone_format]}
                type="select"
                label="Phone Number Format"
                options={[
                  {"E.164 (+12345678901)", "e164"},
                  {"National ((234) 567-8901)", "national"},
                  {"International (+1 234-567-8901)", "international"},
                  {"Raw (no formatting)", "raw"}
                ]}
              />
              <p class="text-xs text-[var(--color-text-tertiary)] -mt-2">
                Controls how phone numbers are displayed. Numbers are stored in normalized form.
              </p>
              <:actions>
                <UI.button>Save</UI.button>
              </:actions>
            </UI.simple_form>
          </div>

          <%!-- Feature module toggles --%>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-1">Feature Modules</h2>
            <p class="text-sm text-[var(--color-text-tertiary)] mb-4">
              Enable or disable feature modules for your account.
            </p>

            <div class="divide-y divide-[var(--color-border-subtle)]">
              <div
                :for={{key, label, description} <- @feature_modules}
                class="flex items-center justify-between py-3"
              >
                <div>
                  <span class="text-sm font-medium text-[var(--color-text-primary)]">{label}</span>
                  <p class="text-xs text-[var(--color-text-tertiary)]">{description}</p>
                </div>
                <button
                  phx-click="toggle-feature"
                  phx-value-feature={key}
                  class={[
                    "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                    if(Map.get(@feature_flags, key, true),
                      do: "bg-[var(--color-accent)]",
                      else: "bg-[var(--color-border)]"
                    )
                  ]}
                >
                  <span class={[
                    "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                    if(Map.get(@feature_flags, key, true), do: "translate-x-5", else: "translate-x-0")
                  ]} />
                </button>
              </div>
            </div>
          </div>

          <%!-- Notification Windows --%>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-1">Notification Windows</h2>
            <p class="text-sm text-[var(--color-text-tertiary)] mb-4">
              Control how far in advance reminders send pre-notifications.
              Changes affect newly scheduled reminders only.
            </p>

            <div class="divide-y divide-[var(--color-border-subtle)]">
              <div :for={rule <- @rules} class="flex items-center justify-between py-3">
                <span class="text-sm text-[var(--color-text-primary)]">
                  {format_rule_label(rule.days_before)}
                </span>

                <button
                  phx-click="toggle-rule"
                  phx-value-id={rule.id}
                  disabled={rule.days_before == 0}
                  title={
                    if rule.days_before == 0,
                      do: "The 'On the day' reminder cannot be turned off",
                      else: ""
                  }
                  class={[
                    "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                    if(rule.active, do: "bg-[var(--color-accent)]", else: "bg-[var(--color-border)]"),
                    if(rule.days_before == 0, do: "opacity-50 cursor-not-allowed", else: "")
                  ]}
                >
                  <span class={[
                    "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                    if(rule.active, do: "translate-x-5", else: "translate-x-0")
                  ]} />
                </button>
              </div>
            </div>
          </div>

          <%!-- Account Reset --%>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-warning)]/30 rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold text-[var(--color-warning)] mb-1">
              Reset Account Data
            </h2>
            <p class="text-sm text-[var(--color-text-tertiary)] mb-4">
              Delete all contacts and data while keeping your account and users.
              This cannot be undone.
            </p>

            <form id="account-reset-form" phx-submit="reset-account" phx-change="validate-reset">
              <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-2">
                Type <span class="font-semibold">RESET</span> to confirm
              </label>
              <input
                type="text"
                name="confirmation"
                value={@reset_confirmation}
                placeholder="RESET"
                autocomplete="off"
                class="w-full max-w-xs rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
              <div class="mt-4">
                <UI.button
                  type="submit"
                  variant="danger"
                  size="sm"
                  disabled={@reset_confirmation != "RESET"}
                >
                  Reset Account Data
                </UI.button>
              </div>
            </form>
          </div>

          <%!-- Account Deletion --%>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-error)]/30 rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold text-[var(--color-error)] mb-1">Delete Account</h2>
            <p class="text-sm text-[var(--color-text-tertiary)] mb-4">
              Permanently delete this account and all associated data. This action cannot be undone.
            </p>

            <form id="account-delete-form" phx-submit="delete-account" phx-change="validate-delete">
              <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-2">
                Type <span class="font-semibold">{@account.name}</span> to confirm
              </label>
              <input
                type="text"
                name="confirmation"
                value={@delete_confirmation}
                placeholder={@account.name}
                autocomplete="off"
                class="w-full max-w-xs rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
              <div class="mt-4">
                <UI.button
                  type="submit"
                  variant="danger"
                  size="sm"
                  disabled={@delete_confirmation != @account.name}
                >
                  Delete Account Permanently
                </UI.button>
              </div>
            </form>
          </div>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp format_rule_label(0), do: "On the day"
  defp format_rule_label(1), do: "1 day before"
  defp format_rule_label(days), do: "#{days} days before"
end
