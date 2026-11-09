defmodule KithWeb.SettingsLive.Security do
  use KithWeb, :live_view

  on_mount {KithWeb.UserAuth, :require_sudo_mode}

  alias Kith.Accounts
  alias Kith.Auth.Policy
  import KithWeb.SettingsLive.SettingsLayout

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

        <UI.card :if={Policy.oidc_enabled?()} class="mt-6">
          <:header>Connected sign-in</:header>
          <p class="text-sm font-medium">
            {Application.fetch_env!(:kith, :auth).oidc[:display_name] || "OpenID Connect"}
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

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:current_email, user.email)
     |> assign(
       oidc_identities: current_identities(user),
       unlink_id: nil,
       oidc_status: nil,
       oidc_trigger_submit: false
     )
     |> assign(:password_login_enabled, Policy.password_login_enabled?())
     |> assign(
       :password_form,
       to_form(Accounts.change_user_password(user, %{}, hash_password: false))
     )
     |> assign(:trigger_submit, false)}
  end

  @impl true
  def handle_event(event, params, socket)
      when event in ["validate_password", "update_password"] do
    if Policy.password_login_enabled?() do
      handle_password_event(event, params, socket)
    else
      {:noreply, assign(socket, password_login_enabled: false, trigger_submit: false)}
    end
  end

  def handle_event("link_oidc", _, socket) do
    if KithWeb.Authentication.require_recent(socket.assigns.current_scope.user) == :ok do
      {:noreply, assign(socket, oidc_trigger_submit: Policy.oidc_enabled?())}
    else
      {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}
    end
  end

  def handle_event("confirm_unlink", %{"id" => id}, socket) do
    owned =
      Enum.find(current_identities(socket.assigns.current_scope.user), &(to_string(&1.id) == id))

    {:noreply, assign(socket, unlink_id: owned && owned.id)}
  end

  def handle_event("cancel_unlink", _, socket), do: {:noreply, assign(socket, unlink_id: nil)}

  def handle_event("unlink_oidc", _, socket) do
    user = socket.assigns.current_scope.user

    cond do
      KithWeb.Authentication.require_recent(user) != :ok ->
        {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}

      not Policy.oidc_enabled?() or is_nil(socket.assigns.unlink_id) ->
        {:noreply, assign(socket, oidc_status: "Please select an identity to unlink.")}

      true ->
        case Accounts.OIDC.unlink(user, socket.assigns.unlink_id) do
          :ok ->
            {:noreply,
             assign(socket,
               oidc_identities: current_identities(user),
               unlink_id: nil,
               oidc_status: "Identity unlinked."
             )}

          {:error, :last_login_method} ->
            {:noreply,
             assign(socket, oidc_status: "Cannot unlink your last available sign-in method.")}

          _ ->
            {:noreply,
             assign(socket, oidc_status: "Unable to unlink this identity. Please try again.")}
        end
    end
  end

  defp current_identities(user) do
    issuer = if Policy.oidc_enabled?(), do: Application.fetch_env!(:kith, :auth).oidc[:issuer]
    Enum.filter(Accounts.OIDC.list(user), &(&1.issuer == issuer))
  end

  defp handle_password_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  defp handle_password_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if KithWeb.Authentication.require_recent(user) == :ok do
      update_sensitive(socket, user, user_params)
    else
      {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}
    end
  end

  defp update_sensitive(socket, user, user_params) do
    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
