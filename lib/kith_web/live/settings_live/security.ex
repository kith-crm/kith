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
