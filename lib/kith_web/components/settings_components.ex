defmodule KithWeb.SettingsComponents do
  @moduledoc "Presentation components for personal settings screens."
  use KithWeb, :html
  import KithWeb.SettingsLive.SettingsLayout

  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :current_path, :string, required: true
  attr :pending_duplicates_count, :integer, required: true
  attr :live_action, :atom, required: true
  attr :credentials, :list, required: true
  attr :form, :any, required: true
  attr :revealed_secret, :string, required: true
  attr :created_credential, :any, required: true
  attr :selected, :any, required: true
  attr :carddav_url, :string, required: true
  attr :password_login_enabled, :boolean, required: true

  def contact_sync(assigns) do
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
          <p :if={@password_login_enabled} class="text-sm mt-2">
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

  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :current_path, :string, required: true
  attr :pending_duplicates_count, :integer, required: true
  attr :password_login_enabled, :boolean, required: true
  attr :password_form, :any, required: true
  attr :trigger_submit, :boolean, required: true
  attr :current_email, :string, required: true
  attr :oidc_enabled, :boolean, required: true
  attr :oidc_display_name, :string, required: true
  attr :oidc_identities, :list, required: true
  attr :oidc_trigger_submit, :boolean, required: true
  attr :unlink_id, :any, required: true
  attr :oidc_status, :string, required: true

  def security(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <.settings_shell current_path={@current_path} current_scope={@current_scope}>
        <UI.header>
          Security
          <:subtitle>Manage your sign-in methods and two-factor authentication</:subtitle>
        </UI.header>
        <UI.card :if={!@password_login_enabled} class="mt-6">
          <:header>Account password</:header>
          <p class="text-sm text-[var(--color-text-secondary)]">
            Password login is disabled by your administrator.
          </p>
        </UI.card>
        <UI.card :if={@password_login_enabled} class="mt-6">
          <:header>Password</:header>
          <details>
            <summary class="cursor-pointer text-sm font-medium text-[var(--color-accent)]">
              Change password
            </summary>
            <.form
              for={@password_form}
              id="password_form"
              action={~p"/users/update-password"}
              method="post"
              phx-change="validate_password"
              phx-submit="update_password"
              phx-trigger-action={@trigger_submit}
            >
              <input
                name={@password_form[:email].name}
                type="hidden"
                id="hidden_user_email"
                spellcheck="false"
                value={@current_email}
              />
              <UI.input
                field={@password_form[:password]}
                type="password"
                label="New password"
                autocomplete="new-password"
                spellcheck="false"
                required
              />
              <UI.input
                field={@password_form[:password_confirmation]}
                type="password"
                label="Confirm new password"
                autocomplete="new-password"
                spellcheck="false"
              />
              <UI.button phx-disable-with="Saving...">
                Save Password
              </UI.button>
            </.form>
          </details>
        </UI.card>

        <UI.card :if={@oidc_enabled} class="mt-6">
          <:header>Connected sign-in</:header>
          <p class="text-sm font-medium">
            {@oidc_display_name}
          </p>
          <p id="oidc-status" class="mt-1 text-sm">
            {if @oidc_identities == [], do: "Not connected", else: "Connected"}
          </p>
          <p :if={@oidc_identities != []} class="text-sm">{@current_email}</p>
          <.form
            :if={@oidc_identities == []}
            for={%{}}
            action={~p"/users/oidc/link"}
            id="oidc-link-form"
            phx-submit="link_oidc"
            phx-trigger-action={@oidc_trigger_submit}
            method="post"
            class="mt-4"
          >
            <UI.button phx-disable-with="Connecting...">Connect account</UI.button>
          </.form>
          <UI.button
            :for={identity <- @oidc_identities}
            id={"oidc-unlink-#{identity.id}"}
            phx-click="confirm_unlink"
            phx-value-id={identity.id}
            class="mt-4"
          >Unlink</UI.button>
          <div :if={@unlink_id} class="mt-4 space-y-3">
            <p>Unlink this identity? You must keep another available sign-in method.</p>
            <UI.button
              id="oidc-unlink-confirm"
              phx-click="unlink_oidc"
              phx-disable-with="Unlinking..."
            >Unlink account</UI.button>
            <UI.button phx-click="cancel_unlink">Cancel</UI.button>
          </div>
          <p role="status" class="mt-3 text-sm">{@oidc_status}</p>
        </UI.card>

        <UI.card class="mt-6">
          <:header>Two-factor authentication</:header>
          <p class="text-sm font-medium">Authenticator app</p>
          <p id="totp-status" class="mt-1 text-sm text-[var(--color-text-secondary)]">
            {if @current_scope.user.totp_enabled, do: "Enabled", else: "Not enabled"}
          </p>
          <UI.button
            :if={!@current_scope.user.totp_enabled}
            navigate={~p"/users/totp-setup"}
            class="mt-4"
          >Set up authenticator app</UI.button>
        </UI.card>
        <p class="mt-6 text-sm text-[var(--color-text-secondary)]">
          To protect your account, sensitive changes may ask you to sign in again.
        </p>
      </.settings_shell>
    </Layouts.app>
    """
  end
end
