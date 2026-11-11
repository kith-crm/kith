defmodule KithWeb.AuthComponents do
  @moduledoc "Presentation components for authentication completion screens."
  use KithWeb, :html

  attr :flash, :map, required: true
  attr :email, :string, required: true
  attr :form, :any, required: true
  attr :trigger_submit, :boolean, required: true
  attr :registration_token, :string, required: true
  attr :require_tos_acceptance, :boolean, required: true
  attr :terms_error, :string, required: true

  def oidc_registration(assigns) do
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
          :if={@require_tos_acceptance}
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
