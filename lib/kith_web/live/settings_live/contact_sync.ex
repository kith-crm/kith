defmodule KithWeb.SettingsLive.ContactSync do
  use KithWeb, :live_view
  alias Kith.Accounts.{DavAppPassword, DavAppPasswords}
  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Contact sync",
       revealed_secret: nil,
       created_credential: nil,
       selected: nil
     )
     |> assign(:carddav_url, KithWeb.Endpoint.url() <> "/dav/principals/")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(revealed_secret: nil, created_credential: nil, selected: nil)
      |> assign(:credentials, DavAppPasswords.list(socket.assigns.current_scope.user))
      |> assign(:form, to_form(DavAppPassword.changeset(%DavAppPassword{}, %{}), as: :credential))

    case socket.assigns.live_action do
      :created ->
        {:noreply, push_patch(socket, to: ~p"/settings/contact-sync", replace: true)}

      :revoke ->
        selected =
          Enum.find(
            socket.assigns.credentials,
            &(to_string(&1.id) == params["id"] and is_nil(&1.revoked_at))
          )

        if selected,
          do: {:noreply, assign(socket, :selected, selected)},
          else: {:noreply, unavailable(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", %{"credential" => params}, socket) do
    if socket.assigns.live_action == :new and is_nil(socket.assigns.revealed_secret) do
      case DavAppPasswords.create(socket.assigns.current_scope.user, %{name: params["name"]}) do
        {:ok, row, plaintext} ->
          {:noreply,
           assign(socket,
             live_action: :created,
             created_credential: row,
             revealed_secret: plaintext
           )}

        {:error, :reauthentication_required} ->
          {:noreply, reauthenticate(socket, "new")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :credential))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke", params, socket) do
    selected = socket.assigns.selected

    if selected && to_string(selected.id) == to_string(params["id"]) do
      case DavAppPasswords.revoke(socket.assigns.current_scope.user, selected.id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "App password revoked")
           |> push_patch(to: ~p"/settings/contact-sync")}

        {:error, :reauthentication_required} ->
          {:noreply, reauthenticate(socket, "index")}

        {:error, :not_found} ->
          {:noreply, unavailable(socket)}
      end
    else
      {:noreply, unavailable(socket)}
    end
  end

  defp reauthenticate(socket, destination) do
    socket
    |> assign(:revealed_secret, nil)
    |> redirect(to: ~p"/settings/contact-sync/reauth?return_to=#{destination}")
  end

  defp unavailable(socket) do
    socket
    |> assign(:revealed_secret, nil)
    |> put_flash(:error, "App password is unavailable.")
    |> push_patch(to: ~p"/settings/contact-sync")
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
          Contact sync<:subtitle>Connect your contacts to your devices with CardDAV</:subtitle>
        </UI.header>
        <UI.card :if={@live_action == :index} class="mt-6" id="dav-app-passwords">
          <:header>App passwords</:header>
          <p class="text-sm mb-4">
            Use a separate app password for each device. Each password is shown only once.
          </p>
          <p :if={@credentials == []}>
            No app passwords yet. Create one to connect your first device.
          </p>
          <ul class="divide-y divide-[var(--color-border)]">
            <li :for={credential <- @credentials} class="py-4 flex flex-wrap justify-between gap-3">
              <div>
                <p class="break-all">{credential.name}</p><p class="text-sm">
                  Created <.datetime_display datetime={credential.inserted_at} />
                </p>
              </div>
              <span :if={credential.revoked_at}>Revoked</span>
              <.link
                :if={!credential.revoked_at}
                patch={~p"/settings/contact-sync/#{credential.id}/revoke"}
                class="text-[var(--color-accent)] inline-flex min-h-11 items-center px-2"
              >Revoke</.link>
            </li>
          </ul>
          <UI.button patch={~p"/settings/contact-sync/new"} class="mt-4 min-h-11">Create app password</UI.button>
        </UI.card>
        <UI.card :if={@live_action == :new} id="dav-create" class="mt-6">
          <:header>Create app password</:header>
          <p class="mb-4">
            Give this device a name you will recognize. Recent authentication is required.
          </p>
          <.form for={@form} id="dav-password-form" phx-submit="create" class="space-y-4">
            <UI.input
              field={@form[:name]}
              label="Device name"
              placeholder="Android phone"
              required
              maxlength="80"
            />
            <UI.button type="submit" class="min-h-11" phx-disable-with="Creating…">Create app password</UI.button>
            <UI.button patch={~p"/settings/contact-sync"} variant="ghost" class="min-h-11">Cancel</UI.button>
          </.form>
        </UI.card>
        <UI.card :if={@revealed_secret} id="dav-reveal" class="mt-6">
          <:header>Save your app password</:header>
          <p role="status" class="mb-4 break-all">
            App password created for {@created_credential.name}. Copy it now. You cannot see it again.
          </p>
          <.copy_field id="dav-secret" value={@revealed_secret} label="App password" sensitive />
          <UI.button patch={~p"/settings/contact-sync"} class="mt-4 min-h-11">Done</UI.button>
        </UI.card>
        <UI.card :if={@live_action == :revoke && @selected} id="dav-revoke" class="mt-6">
          <:header>Revoke app password?</:header>
          <p class="mb-4 break-all">
            {@selected.name} will stop syncing immediately. To reconnect, create a new app password.
          </p>
          <UI.button
            variant="danger"
            class="min-h-11"
            phx-click="revoke"
            phx-value-id={@selected.id}
            phx-disable-with="Revoking…"
          >Revoke app password</UI.button>
          <UI.button patch={~p"/settings/contact-sync"} variant="ghost" class="min-h-11">Cancel</UI.button>
        </UI.card>
        <UI.card :if={@live_action == :index} id="dav-connection" class="mt-6">
          <:header>Connection details</:header>
          <.copy_field id="carddav-url" value={@carddav_url} label="Server URL" />
          <p class="mt-4">Username: <span class="break-all">{@current_scope.user.email}</span></p>
          <p>Password: use an app password created above.</p>
          <p :if={Kith.Auth.Policy.password_login_enabled?()} class="text-sm mt-2">
            Your Kith account password also works while account-password login is enabled.
          </p>
          <details class="mt-4">
            <summary>Apple Contacts (macOS / iOS)</summary><p>
              macOS: System Settings → Internet Accounts → Add Other Account → CardDAV account.
            </p><p>
              iOS: Settings → Contacts → Accounts → Add Account → Other → Add CardDAV Account.
            </p><p>Enter the server URL, email username and app password above.</p>
          </details>
          <details class="mt-4">
            <summary>DAVx5 (Android)</summary><p>
              Install DAVx5 from the Play Store or F-Droid. Add account → Login with URL. Enter the server URL above, your email and app password.
            </p>
          </details>
          <details class="mt-4">
            <summary>Thunderbird</summary><p>
              Add a CardDAV address book using the server URL, email username and app password above.
            </p>
          </details>
        </UI.card>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :sensitive, :boolean, default: false

  defp copy_field(assigns) do
    ~H"""
    <div
      id={@id <> "-copy"}
      phx-update="ignore"
      x-data="copyText"
      data-copy-sensitive={to_string(@sensitive)}
      data-copy-value={if !@sensitive, do: @value}
      class="flex flex-wrap items-center gap-2"
    >
      <label for={@id} class="w-full">{@label}</label>
      <input
        id={@id}
        value={@value}
        readonly
        autocomplete="off"
        spellcheck="false"
        class="min-w-0 flex-1 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-sunken)] p-3 font-mono text-sm text-[var(--color-text-primary)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]"
      />
      <button
        type="button"
        x-on:click="copy"
        class="min-h-11 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-4 py-2 text-sm font-medium text-[var(--color-text-primary)] focus-visible:outline-2 focus-visible:outline-[var(--color-border-focus)]"
      >
        <span x-show="!copied">Copy</span>
        <span x-show="copied" x-cloak role="status" aria-live="polite">Copied!</span>
      </button>
      <p x-show="copyFailed" x-cloak role="status" aria-live="polite" class="w-full">
        Could not copy automatically. Select the value and copy it manually.
      </p>
    </div>
    """
  end
end
