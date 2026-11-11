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
    <KithWeb.AuthComponents.oidc_registration
      flash={@flash}
      email={@email}
      form={@form}
      trigger_submit={@trigger_submit}
      registration_token={@registration_token}
      require_tos_acceptance={Application.get_env(:kith, :require_tos_acceptance, false)}
      terms_error={@terms_error}
    />
    """
  end
end
