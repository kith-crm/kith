defmodule KithWeb.UserLive.TotpSetup do
  use KithWeb, :live_view

  on_mount {KithWeb.UserAuth, :require_sudo_mode}

  alias Kith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="space-y-6">
        <%= if @recovery_codes do %>
          <div class="text-center">
            <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">
              Two-factor authentication enabled
            </h1>
            <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
              Store these recovery codes somewhere safe. You won't be able to see them again.
            </p>
          </div>

          <div class="rounded-[var(--radius-lg)] bg-[var(--color-surface-sunken)] border border-[var(--color-border)] p-4 font-mono text-sm grid grid-cols-2 gap-2">
            <div
              :for={code <- @recovery_codes}
              class="text-center py-1 text-[var(--color-text-primary)]"
            >
              {code}
            </div>
          </div>

          <div
            class="flex gap-2"
            x-data={"recoveryCodes(#{Jason.encode!(@recovery_codes)})"}
          >
            <button
              type="button"
              class="flex-1 inline-flex items-center justify-center gap-2 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-4 py-2 text-sm font-medium text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
              x-on:click="copyAll"
            >
              <span x-show="!copied">Copy all</span>
              <span x-show="copied" x-cloak>Copied!</span>
            </button>
            <button
              type="button"
              class="flex-1 inline-flex items-center justify-center gap-2 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-4 py-2 text-sm font-medium text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
              x-on:click="downloadTxt"
            >
              Download as .txt
            </button>
          </div>

          <UI.button navigate={~p"/settings/security"} class="w-full">
            I've saved my recovery codes
          </UI.button>
        <% else %>
          <div class="text-center">
            <h1 class="text-xl font-semibold text-[var(--color-text-primary)]">
              Set up two-factor authentication
            </h1>
            <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
              Scan the QR code with your authenticator app, then enter the 6-digit code to confirm.
            </p>
          </div>

          <div class="flex justify-center">
            <img src={@qr_data_url} alt="TOTP QR Code" class="rounded-[var(--radius-lg)]" />
          </div>

          <details class="text-sm text-[var(--color-text-secondary)]">
            <summary class="cursor-pointer font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors">
              Can't scan? Enter this code manually
            </summary>
            <code class="block mt-2 p-3 bg-[var(--color-surface-sunken)] rounded-[var(--radius-md)] text-center font-mono tracking-widest text-[var(--color-text-primary)] border border-[var(--color-border)]">
              {@secret}
            </code>
          </details>

          <.form for={@form} id="totp_confirm_form" phx-submit="confirm">
            <UI.input
              field={@form[:code]}
              type="text"
              label="6-digit code"
              inputmode="numeric"
              pattern="[0-9]{6}"
              autocomplete="one-time-code"
              maxlength="6"
              required
              phx-mounted={JS.focus()}
            />
            <UI.button class="w-full" phx-disable-with="Verifying...">
              Enable two-factor authentication
            </UI.button>
          </.form>

          <p class="text-center text-sm text-[var(--color-text-tertiary)]">
            <.link
              navigate={~p"/settings/security"}
              class="font-medium text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
            >
              Cancel
            </.link>
          </p>
        <% end %>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    if user.totp_enabled do
      {:ok,
       socket
       |> put_flash(:info, "Two-factor authentication is already enabled.")
       |> redirect(to: ~p"/settings/security")}
    else
      secret = Accounts.generate_totp_secret()
      uri = Accounts.totp_uri(secret, user.email)
      qr_data_url = Accounts.totp_qr_code_data_url(uri)

      {:ok,
       assign(socket,
         session_token: session["user_token"],
         secret: secret,
         qr_data_url: qr_data_url,
         recovery_codes: nil,
         form: to_form(%{"code" => ""}, as: "totp")
       )}
    end
  end

  @impl true
  def handle_event("confirm", %{"totp" => %{"code" => code}}, socket) do
    user = socket.assigns.current_scope.user
    secret = socket.assigns.secret

    case Accounts.enable_totp(user, secret, code) do
      {:ok, {_user, raw_codes}} ->
        import Ecto.Query

        Kith.Repo.update_all(
          from(t in Kith.Accounts.UserToken,
            where:
              t.token == ^socket.assigns.session_token and t.user_id == ^user.id and
                t.context == "session"
          ),
          set: [mfa_authenticated_at: DateTime.utc_now(:second)]
        )

        {:noreply,
         socket
         |> put_flash(:info, "Two-factor authentication has been enabled.")
         |> assign(recovery_codes: raw_codes)}

      {:error, :reauthentication_required} ->
        {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=totp")}

      {:error, :invalid_code} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid code. Please try again.")
         |> assign(form: to_form(%{"code" => ""}, as: "totp"))}
    end
  end
end
