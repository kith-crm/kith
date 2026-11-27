defmodule KithWeb.UserLive.Login do
  use KithWeb, :live_view

  alias Kith.Auth.Policy

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <div class="text-center">
          <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">Log in</h1>
          <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
              After authentication, return to your settings and retry the action.
            <% else %>
              <%= if Policy.registration_enabled?() and (Policy.password_login_enabled?() or Policy.oidc_enabled?()) do %>
                Don't have an account?
                <.link
                  href={
                    if Policy.password_login_enabled?(), do: ~p"/users/register", else: ~p"/auth/oidc"
                  }
                  class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                >
                  Sign up
                </.link>
              <% end %>
            <% end %>
          </p>
        </div>

        <div>
          <div :if={!Policy.password_login_enabled?()}>
            <label for="passkey-email">Email (optional)</label>
            <input id="passkey-email" type="email" autocomplete="username" />
          </div>
          <button id="passkey-login" type="button" phx-hook="PasskeyLogin">Sign in with passkey</button>
          <p id="passkey-error" role="alert"></p>
        </div>

        <div :if={Policy.oidc_enabled?()}>
          <UI.button :if={!@current_scope} href={~p"/auth/oidc"} class="w-full">
            Continue with {Application.fetch_env!(:kith, :auth).oidc[:display_name] ||
              "OpenID Connect"}
          </UI.button>
          <.form
            :if={@current_scope}
            for={%{}}
            action={~p"/users/oidc/reauth"}
            method="post"
            id="oidc-reauth-form"
            phx-submit="oidc_reauth"
            phx-trigger-action={@oidc_trigger_submit}
          >
            <UI.button class="w-full" phx-disable-with="Connecting...">
              Verify with {Application.fetch_env!(:kith, :auth).oidc[:display_name] ||
                "OpenID Connect"}
            </UI.button>
          </.form>
        </div>

        <.form
          :let={f}
          :if={Policy.password_login_enabled?()}
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <div class="space-y-1">
            <UI.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              autofocus
            />
            <UI.input
              field={f[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
              required
            />
          </div>

          <div class="flex items-center justify-between mt-4">
            <label class="flex items-center gap-2 text-sm text-[var(--color-text-secondary)] cursor-pointer select-none">
              <input
                type="checkbox"
                name={f[:remember_me].name}
                value="true"
                class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
              /> Remember me
            </label>
            <.link
              navigate={~p"/users/reset-password"}
              class="text-sm font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
            >
              Forgot password?
            </.link>
          </div>

          <UI.button class="w-full mt-6">
            Log in <span aria-hidden="true">&rarr;</span>
          </UI.button>
        </.form>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false, oidc_trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, Policy.password_login_enabled?())}
  end

  def handle_event("oidc_reauth", _, socket) do
    {:noreply,
     assign(socket,
       oidc_trigger_submit: Policy.oidc_enabled?() and not is_nil(socket.assigns.current_scope)
     )}
  end
end
