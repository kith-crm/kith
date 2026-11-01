defmodule KithWeb.UserLive.Login do
  use KithWeb, :live_view

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
            <% else %>
              <%= unless Application.get_env(:kith, :disable_signup, false) do %>
                Don't have an account?
                <.link
                  navigate={~p"/users/register"}
                  class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                >
                  Sign up
                </.link>
              <% end %>
            <% end %>
          </p>
        </div>

        <.form
          :let={f}
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

        <%= unless @current_scope do %>
          <%= if :github in Application.get_env(:kith, :oauth_providers, []) or
                 :google in Application.get_env(:kith, :oauth_providers, []) do %>
            <UI.separator label="or continue with" class="my-6" />

            <div class="flex flex-col gap-3">
              <%= if :github in Application.get_env(:kith, :oauth_providers, []) do %>
                <a
                  href="/auth/github"
                  class="inline-flex items-center justify-center gap-2 w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-4 py-2.5 text-sm font-medium text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors duration-150"
                >
                  <svg class="size-5" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
                  </svg>
                  GitHub
                </a>
              <% end %>

              <%= if :google in Application.get_env(:kith, :oauth_providers, []) do %>
                <a
                  href="/auth/google"
                  class="inline-flex items-center justify-center gap-2 w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-4 py-2.5 text-sm font-medium text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors duration-150"
                >
                  <svg class="size-5" viewBox="0 0 24 24">
                    <path
                      fill="#4285F4"
                      d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z"
                    />
                    <path
                      fill="#34A853"
                      d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                    />
                    <path
                      fill="#FBBC05"
                      d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                    />
                    <path
                      fill="#EA4335"
                      d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                    />
                  </svg>
                  Google
                </a>
              <% end %>
            </div>
          <% end %>
        <% end %>
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

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
