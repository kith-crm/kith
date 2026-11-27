defmodule Kith.Auth.Policy do
  @moduledoc "The normalized deployment authentication policy."

  def password_login_enabled?, do: config().password_login_enabled
  def registration_enabled?, do: config().registration_enabled
  def oidc_enabled?, do: config().oidc_enabled

  # Password registration never provisions an account with a disabled login method.
  def password_registration_enabled?, do: registration_enabled?() and password_login_enabled?()

  defp config, do: Application.fetch_env!(:kith, :auth)
end
