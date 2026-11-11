defmodule KithWeb.UserLive.ForgotPassword do
  use KithWeb, :live_view

  alias Kith.Auth.Policy

  alias Kith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <div class="text-center">
          <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">
            Forgot your password?
          </h1>
          <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
            We'll send a password reset link to your inbox.
          </p>
        </div>

        <.form for={@form} id="reset_password_form" phx-submit="send_email">
          <UI.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <UI.button class="w-full" phx-disable-with="Sending...">
            Send password reset instructions
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

  defp mount_enabled(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if Policy.password_login_enabled?() do
      perform_event(socket, email)
    else
      {:noreply, disabled(socket)}
    end
  end

  defp perform_event(socket, email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp disabled(socket) do
    socket
    |> put_flash(:error, "Password recovery is disabled.")
    |> redirect(to: ~p"/users/log-in")
  end
end
