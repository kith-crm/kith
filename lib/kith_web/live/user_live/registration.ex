defmodule KithWeb.UserLive.Registration do
  use KithWeb, :live_view

  alias Kith.Auth.Policy

  alias Kith.Accounts
  alias Kith.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <div class="text-center">
          <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">Create an account</h1>
          <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
            Already registered?
            <.link
              navigate={~p"/users/log-in"}
              class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
            >
              Log in
            </.link>
          </p>
        </div>

        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          action={~p"/users/log-in?_action=registered"}
          method="post"
        >
          <div class="space-y-1">
            <UI.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <div x-data="passwordStrength" class="space-y-1">
              <div class="mb-3">
                <label
                  for={@form[:password].id}
                  class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
                >
                  Password
                </label>
                <input
                  type="password"
                  name={@form[:password].name}
                  id={@form[:password].id}
                  value={Phoenix.HTML.Form.normalize_value("password", @form[:password].value)}
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  autocomplete="new-password"
                  required
                  x-model="pw"
                />
                <%= for error <- Enum.map((@form[:password].errors || []), &UI.translate_error/1) do %>
                  <p class="mt-1.5 flex items-center gap-1.5 text-xs text-[var(--color-error)]">
                    <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
                    {error}
                  </p>
                <% end %>
              </div>
              <div
                class="h-1.5 w-full rounded-[var(--radius-full)] bg-[var(--color-surface-sunken)] overflow-hidden"
                x-show="visible"
                x-cloak
              >
                <div
                  class="h-full rounded-[var(--radius-full)] transition-all duration-300"
                  x-bind:class="barClass"
                >
                </div>
              </div>
              <p
                class="text-xs"
                x-show="visible"
                x-cloak
                x-bind:class="textClass"
                x-text="label"
              >
              </p>
            </div>
          </div>

          <%= if Application.get_env(:kith, :require_tos_acceptance, false) do %>
            <div class="flex items-start gap-2 mt-3">
              <UI.input
                field={@form[:tos_accepted]}
                type="checkbox"
                label={
                  ~H'I accept the <.link navigate="/terms" class="text-[var(--color-accent)] hover:underline" target="_blank">Terms of Service</.link>'
                }
              />
            </div>
          <% end %>

          <UI.button phx-disable-with="Creating account..." class="w-full mt-4">
            Create an account
          </UI.button>
        </.form>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: KithWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    if Policy.registration_enabled?() and Policy.oidc_enabled?() and
         not Policy.password_login_enabled?() do
      {:ok, redirect(socket, to: ~p"/auth/oidc")}
    else
      mount_password(socket)
    end
  end

  defp mount_password(socket) do
    if Policy.password_registration_enabled?() do
      changeset = Accounts.change_user_registration(%User{})

      {:ok,
       assign(socket,
         form: to_form(changeset, as: "user"),
         trigger_submit: false,
         signup_peer: signup_peer(socket)
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Registration is currently disabled.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    if Policy.password_registration_enabled?() do
      save(socket, user_params)
    else
      {:noreply,
       socket
       |> assign(trigger_submit: false)
       |> put_flash(:error, "Registration is currently disabled.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp save(socket, user_params) do
    case check_signup(socket.assigns.signup_peer) do
      :ok ->
        register_user(socket, user_params)

      {:error, :rate_limited, retry_after_ms} ->
        seconds = Kith.RateLimiter.retry_after_seconds(retry_after_ms)

        {:noreply,
         socket
         |> assign(trigger_submit: false)
         |> assign_form(Accounts.change_user_registration(%User{}, user_params))
         |> put_flash(:error, "Too many signup attempts. Please try again in #{seconds} seconds.")}

      {:error, :missing_peer} ->
        {:noreply,
         socket
         |> assign(trigger_submit: false)
         |> assign_form(Accounts.change_user_registration(%User{}, user_params))
         |> put_flash(:error, "Unable to verify your connection. Please reload and try again.")}
    end
  end

  defp register_user(socket, user_params) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        Accounts.deliver_user_confirmation_instructions(
          user,
          &url(~p"/users/confirm/#{&1}")
        )

        changeset = Accounts.change_user_registration(%User{}, user_params)

        {:noreply,
         socket
         |> assign(trigger_submit: true)
         |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # Only transport-provided connect info may identify a signup client. The
  # canonical header is accepted by the same ingress allowlist used for HTTP.
  # Connect params and the mutable HTTP remote_ip are never identity sources.
  defp signup_peer(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: peer} when is_tuple(peer) and tuple_size(peer) in [4, 8] ->
        Kith.TrustedProxies.resolve(peer, get_connect_info(socket, :x_headers) || [])

      _ ->
        nil
    end
  end

  defp check_signup(nil), do: {:error, :missing_peer}
  defp check_signup(peer), do: Kith.RateLimiter.check_signup(peer)

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
