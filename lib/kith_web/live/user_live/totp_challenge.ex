defmodule KithWeb.UserLive.TotpChallenge do
  use KithWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div
        class="space-y-6"
        x-data="totpChallenge"
      >
        <div class="text-center">
          <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">
            Two-factor authentication
          </h1>
          <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
            <span x-show="!recoveryMode">Enter the 6-digit code from your authenticator app.</span>
            <span x-show="recoveryMode" x-cloak>
              Enter one of your recovery codes (format: XXXX-XXXX).
            </span>
          </p>
        </div>

        <form
          id="totp_challenge_form"
          action={~p"/users/totp-verify"}
          method="post"
          x-ref="totpForm"
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="totp_token" value={@totp_token} />

          <div x-show="!recoveryMode">
            <div class="mb-3">
              <label
                for="totp_code"
                class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
              >
                Authentication code
              </label>
              <input
                type="text"
                name="totp[code]"
                id="totp_code"
                x-bind:disabled="recoveryMode"
                inputmode="numeric"
                pattern="[0-9]{6}"
                autocomplete="one-time-code"
                maxlength="6"
                required
                phx-mounted={JS.focus()}
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] text-center font-mono text-lg tracking-[0.5em] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                x-on:input="autoSubmit"
              />
            </div>
          </div>

          <div x-show="recoveryMode" x-cloak>
            <UI.input
              field={@form[:code]}
              id="totp_recovery_code"
              {%{"x-bind:disabled" => "!recoveryMode"}}
              name="totp[code]"
              type="text"
              label="Recovery code"
              pattern="[0-9a-zA-Z\-]{9}"
              autocomplete="off"
              maxlength="9"
              placeholder="XXXX-XXXX"
              required
            />
          </div>

          <UI.button class="w-full" phx-disable-with="Verifying...">Verify</UI.button>
        </form>

        <p class="text-center text-sm text-[var(--color-text-tertiary)]">
          <button
            type="button"
            class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors cursor-pointer"
            x-on:click="toggleMode"
            x-text="modeLabel"
          ></button>
        </p>

        <p class="text-center text-sm text-[var(--color-text-tertiary)]">
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
  def mount(_params, session, socket) do
    totp_token = session["totp_token"]

    if totp_token do
      {:ok,
       assign(socket,
         totp_token: totp_token,
         form: to_form(%{"code" => ""}, as: "totp")
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please log in first.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end
end
