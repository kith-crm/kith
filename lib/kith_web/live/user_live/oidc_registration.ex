defmodule KithWeb.UserLive.OIDCRegistration do
  use KithWeb, :live_view
  alias Kith.Auth.{OIDC.Transactions, Policy}

  @impl true
  def mount(_params, session, socket) do
    with true <- Policy.oidc_enabled?() and Policy.registration_enabled?(),
         {:ok, pending} <-
           Transactions.pending_registration(
             session["oidc_registration"],
             session["auth_challenge_binding"]
           ),
         true <- pending.issuer == Application.fetch_env!(:kith, :auth).oidc[:issuer] do
      {:ok,
       assign(socket,
         email: pending.principal["email"],
         registration_token: pending.state,
         form: to_form(%{}, as: "user"),
         trigger_submit: false,
         terms_error: nil
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Your registration has expired. Please sign in again.")
         |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("complete", params, socket) do
    attrs = params["user"] || %{}

    accepted =
      attrs["tos_accepted"] in [true, "true"] or
        not Application.get_env(:kith, :require_tos_acceptance, false)

    if Policy.oidc_enabled?() and Policy.registration_enabled?() do
      {:noreply,
       assign(socket,
         form: to_form(Map.take(attrs, ["tos_accepted"]), as: "user"),
         trigger_submit: accepted,
         terms_error: if(accepted, do: nil, else: "Please accept the Terms of Service.")
       )}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Registration is currently unavailable.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <h1 class="text-xl font-semibold">Complete your account</h1>
      <p class="mt-3 text-sm">Create your personal account using {@email}.</p>
      <.form
        for={@form}
        id="oidc-registration-form"
        action={~p"/users/oidc/register"}
        method="post"
        phx-submit="complete"
        phx-trigger-action={@trigger_submit}
        class="mt-6"
      >
        <input type="hidden" name="registration_token" value={@registration_token} />
        <UI.input
          :if={Application.get_env(:kith, :require_tos_acceptance, false)}
          field={@form[:tos_accepted]}
          type="checkbox"
          label="I accept the Terms of Service"
        />
        <.link href="/terms" target="_blank" class="text-sm underline">Read the Terms of Service</.link>
        <p :if={@terms_error} role="alert" class="mt-2 text-sm text-[var(--color-error)]">
          {@terms_error}
        </p>
        <UI.button class="mt-4 w-full" phx-disable-with="Creating account...">Create account</UI.button>
      </.form>
      <.form for={%{}} action={~p"/users/oidc/register"} method="post" class="mt-4">
        <input type="hidden" name="registration_token" value={@registration_token} />
        <input type="hidden" name="cancel" value="true" />
        <UI.button>Cancel</UI.button>
      </.form>
    </Layouts.auth>
    """
  end
end
