defmodule KithWeb.SettingsLive.Integrations do
  use KithWeb, :live_view

  alias Kith.Accounts.Account
  alias Kith.Contacts
  alias Kith.Immich
  alias Kith.Immich.Settings, as: ImmichSettings
  alias Kith.Policy
  alias Kith.Repo

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:account, nil)
     |> assign(:immich_url, "")
     |> assign(:immich_api_key_set, false)
     |> assign(:immich_enabled, false)
     |> assign(:immich_status, "disabled")
     |> assign(:immich_failures, 0)
     |> assign(:immich_last_synced, nil)
     |> assign(:immich_pending_count, 0)
     |> assign(:immich_contacts_scanned, 0)
     |> assign(:immich_matches_found, 0)
     |> assign(:test_result, nil)
     |> assign(:saving, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user = socket.assigns.current_scope.user

    if Policy.can?(user, :manage, :account) do
      account = socket.assigns.current_scope.account
      settings = ImmichSettings.get_settings(account)
      pending_count = Contacts.count_needs_review(account.id)

      {:noreply,
       socket
       |> assign(:account, account)
       |> assign(:immich_url, settings.base_url || "")
       |> assign(:immich_api_key_set, settings.api_key != nil && settings.api_key != "")
       |> assign(:immich_enabled, settings.enabled)
       |> assign(:immich_status, settings.status)
       |> assign(:immich_failures, settings.consecutive_failures)
       |> assign(:immich_last_synced, settings.last_synced_at)
       |> assign(:immich_pending_count, pending_count)
       |> assign(:immich_contacts_scanned, Contacts.count_immich_scanned(account.id))
       |> assign(:immich_matches_found, Contacts.count_immich_matched(account.id))}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You do not have permission to manage integrations.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save-immich", params, socket) do
    account = socket.assigns.account

    attrs = %{
      immich_base_url: params["immich_url"],
      immich_enabled: params["immich_enabled"] == "true"
    }

    # Only update API key if a new one was provided
    attrs =
      case params["immich_api_key"] do
        "" -> attrs
        nil -> attrs
        key -> Map.put(attrs, :immich_api_key, key)
      end

    case ImmichSettings.update_settings(account, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:account, updated)
         |> assign(:immich_url, updated.immich_base_url || "")
         |> assign(
           :immich_api_key_set,
           updated.immich_api_key != nil && updated.immich_api_key != ""
         )
         |> assign(:immich_enabled, updated.immich_enabled)
         |> put_flash(:info, "Immich settings saved")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save settings")}
    end
  end

  def handle_event("test-connection", _params, socket) do
    account = socket.assigns.account

    case ImmichSettings.test_connection(account) do
      {:ok, _count} ->
        {:noreply, assign(socket, :test_result, :ok)}

      {:error, reason} ->
        {:noreply, assign(socket, :test_result, {:error, reason})}
    end
  end

  def handle_event("sync-now", _params, socket) do
    account = socket.assigns.account

    case Immich.trigger_sync(account) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Sync triggered — results will appear shortly")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "A sync is already in progress")}
    end
  end

  def handle_event("reset-retry", _params, socket) do
    account = socket.assigns.account

    {:ok, updated} =
      account
      |> Account.immich_sync_changeset(%{
        immich_status: "ok",
        immich_consecutive_failures: 0
      })
      |> Repo.update()

    Immich.trigger_sync(updated)

    {:noreply,
     socket
     |> assign(:account, updated)
     |> assign(:immich_status, "ok")
     |> assign(:immich_failures, 0)
     |> put_flash(:info, "Circuit breaker reset — sync triggered")}
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
          Integrations
          <:subtitle>Manage external service connections</:subtitle>
        </UI.header>

        <%!-- Immich Section --%>
        <div class="mt-8 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
          <h2 class="text-lg font-semibold mb-4">Immich Photo Integration</h2>

          <%!-- Circuit breaker error banner --%>
          <div
            :if={@immich_status == "error"}
            class="mb-4 bg-[var(--color-error-subtle)] border border-[var(--color-error)]/30 rounded-[var(--radius-lg)] p-4"
          >
            <p class="text-[var(--color-error)] font-medium">Connection Error</p>
            <p class="text-[var(--color-error)]/80 text-sm mt-1">
              Immich sync has failed {@immich_failures} consecutive times and has been paused.
            </p>
            <div class="mt-2">
              <UI.button variant="danger" size="sm" phx-click="reset-retry">
                Reset &amp; Retry
              </UI.button>
            </div>
          </div>

          <form phx-submit="save-immich" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                Server URL
              </label>
              <input
                type="url"
                name="immich_url"
                value={@immich_url}
                placeholder="https://immich.example.com"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                API Key
              </label>
              <input
                type="password"
                name="immich_api_key"
                placeholder={if @immich_api_key_set, do: "••••••••••••••••", else: "Enter API key"}
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
              <p :if={@immich_api_key_set} class="text-xs text-[var(--color-text-tertiary)] mt-1">
                Leave blank to keep existing key
              </p>
            </div>

            <div class="flex items-center gap-2">
              <input type="hidden" name="immich_enabled" value="false" />
              <input
                type="checkbox"
                name="immich_enabled"
                value="true"
                checked={@immich_enabled}
                class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
              />
              <label class="text-sm text-[var(--color-text-primary)]">Enable Immich sync</label>
            </div>

            <div class="flex gap-3 pt-2">
              <UI.button type="submit" size="sm">
                Save
              </UI.button>
              <UI.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="test-connection"
                class="border border-[var(--color-border)]"
              >
                Test Connection
              </UI.button>
              <UI.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="sync-now"
                disabled={!@immich_api_key_set || !@immich_enabled}
                class="border border-[var(--color-border)]"
              >
                Sync Now
              </UI.button>
            </div>
          </form>

          <%!-- Test connection result --%>
          <div :if={@test_result == :ok} class="mt-3 text-[var(--color-success)] text-sm">
            Connected successfully
          </div>
          <div :if={match?({:error, _}, @test_result)} class="mt-3 text-[var(--color-error)] text-sm">
            Could not connect: {format_error(elem(@test_result, 1))}
          </div>

          <%!-- Sync status --%>
          <div
            :if={@immich_last_synced}
            class="mt-4 pt-4 border-t border-[var(--color-border)]"
          >
            <p class="text-sm text-[var(--color-text-tertiary)]">
              Last synced: <.datetime_display datetime={@immich_last_synced} />
            </p>

            <%!-- Stats grid --%>
            <div class="grid grid-cols-3 gap-4 mt-4">
              <div class="text-center p-3 rounded-[var(--radius-lg)] bg-[var(--color-surface-sunken)]">
                <div class="text-xl font-semibold text-[var(--color-text-primary)]">
                  {@immich_contacts_scanned}
                </div>
                <div class="text-xs text-[var(--color-text-tertiary)] mt-0.5">Contacts scanned</div>
              </div>
              <div class="text-center p-3 rounded-[var(--radius-lg)] bg-[var(--color-surface-sunken)]">
                <div class="text-xl font-semibold text-[var(--color-text-primary)]">
                  {@immich_matches_found}
                </div>
                <div class="text-xs text-[var(--color-text-tertiary)] mt-0.5">Matches found</div>
              </div>
              <div class="text-center p-3 rounded-[var(--radius-lg)] bg-[var(--color-surface-sunken)]">
                <div class="text-xl font-semibold text-[var(--color-text-primary)]">
                  {@immich_pending_count}
                </div>
                <div class="text-xs text-[var(--color-text-tertiary)] mt-0.5">Pending review</div>
              </div>
            </div>

            <p :if={@immich_pending_count > 0} class="mt-3">
              <.link
                navigate={~p"/contacts/immich-review"}
                class="text-sm text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] hover:underline inline-flex items-center gap-1"
              >
                Review pending contacts <.icon name="hero-arrow-right" class="size-3.5" />
              </.link>
            </p>
          </div>
        </div>

        <UI.card class="mt-8">
          <:header>CardDAV Contact Sync</:header>
          <.link navigate={~p"/settings/contact-sync"} class="text-[var(--color-accent)]">Contact sync</.link>
          <p>Manage your personal app passwords and client setup instructions.</p>
        </UI.card>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp format_error(:unauthorized), do: "invalid API key"
  defp format_error(:not_found), do: "server not found — check URL"
  defp format_error(:timeout), do: "connection timed out"
  defp format_error(:network_error), do: "network error"
  defp format_error(:missing_url), do: "server URL is required"
  defp format_error(:missing_api_key), do: "API key is required"
  defp format_error({:unexpected_status, code}), do: "unexpected HTTP #{code}"
  defp format_error(other), do: inspect(other)
end
