defmodule KithWeb.UserLive.ResetPassword do
  use KithWeb, :live_view

  alias Kith.Auth.Policy

  alias Kith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <div class="text-center">
          <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">Reset password</h1>
        </div>

        <.form for={@form} id="reset_password_form" phx-submit="reset" phx-change="validate">
          <div class="space-y-1">
            <UI.input
              field={@form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <UI.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
            />
          </div>
          <UI.button class="w-full mt-2" phx-disable-with="Resetting...">
            Reset password
          </UI.button>
        </.form>

        <p class="text-center text-sm text-[var(--color-text-secondary)]">
          <.link
            navigate={~p"/users/log-in"}
            class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
          >
            Back to log in
          </.link>
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(params, session, socket) do
    if Policy.password_login_enabled?() do
      mount_enabled(params, session, socket)
    else
      {:ok, disabled(socket)}
    end
  end

  defp mount_enabled(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      changeset = Accounts.change_user_password(user, %{}, hash_password: false)

      {:ok,
       assign(socket,
         user: user,
         token: token,
         form: to_form(changeset, as: "user")
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Reset password link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/reset-password")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  def handle_event("reset", %{"user" => user_params}, socket) do
    if Policy.password_login_enabled?() do
      perform_event(socket, user_params)
    else
      {:noreply, disabled(socket)}
    end
  end

  defp perform_event(socket, user_params) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully. You may now log in.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  defp disabled(socket) do
    socket
    |> put_flash(:error, "Password recovery is disabled.")
    |> redirect(to: ~p"/users/log-in")
  end
end
