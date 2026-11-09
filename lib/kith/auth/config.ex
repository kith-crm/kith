defmodule Kith.Auth.Config do
  @moduledoc "Normalizes operator authentication policy without network or database access."

  def from_env!(env) do
    oidc_enabled = boolean!(env, "OIDC_ENABLED", false)
    password_enabled = boolean!(env, "PASSWORD_LOGIN_ENABLED", true)
    legacy_disabled = boolean!(env, "DISABLE_SIGNUP", false)
    registration_enabled = boolean!(env, "REGISTRATION_ENABLED", not legacy_disabled)

    if Map.has_key?(env, "REGISTRATION_ENABLED") and Map.has_key?(env, "DISABLE_SIGNUP") and
         registration_enabled == legacy_disabled do
      raise ArgumentError, "REGISTRATION_ENABLED and DISABLE_SIGNUP disagree"
    end

    %{
      oidc_enabled: oidc_enabled,
      password_login_enabled: password_enabled,
      registration_enabled: registration_enabled,
      oidc: if(oidc_enabled, do: oidc!(env), else: nil)
    }
  end

  def validate_runtime!(config, capabilities) do
    providers = Map.get(capabilities, :oauth_providers, %{})

    external? =
      Enum.any?(providers, fn {_provider, opts} ->
        present?(opts[:client_id]) and present?(opts[:client_secret])
      end)

    unless config.password_login_enabled or config.oidc_enabled or external? or
             Map.get(capabilities, :passkeys_enabled, false) == true do
      raise ArgumentError,
            "No configured interactive login mechanism; restore authentication configuration"
    end

    :ok
  end

  defp boolean!(env, key, default) do
    case Map.get(env, key) do
      nil -> default
      "true" -> true
      "false" -> false
      _ -> raise ArgumentError, "#{key} must be true or false"
    end
  end

  defp oidc!(env) do
    issuer = required!(env, "OIDC_ISSUER")

    validate_issuer!(issuer)

    secret =
      try do
        Kith.ConfigHelpers.read_secret("OIDC_CLIENT_SECRET", env)
      rescue
        _ -> reraise ArgumentError, [message: "OIDC_CLIENT_SECRET could not be read"], []
      end

    unless present?(secret), do: raise(ArgumentError, "OIDC_CLIENT_SECRET is required")

    [
      issuer: issuer,
      client_id: required!(env, "OIDC_CLIENT_ID"),
      client_secret: secret,
      display_name: Map.get(env, "OIDC_DISPLAY_NAME", "OpenID Connect")
    ]
  end

  defp validate_issuer!(issuer) do
    uri =
      case URI.new(issuer) do
        {:ok, uri} -> uri
        {:error, _} -> raise ArgumentError, "OIDC_ISSUER must be a valid HTTPS issuer"
      end

    unless uri.scheme == "https" and present?(uri.host) and is_nil(uri.userinfo) and
             is_nil(uri.query) and is_nil(uri.fragment) and not Regex.match?(~r/\s/, issuer) do
      raise ArgumentError,
            "OIDC_ISSUER must be an HTTPS issuer without userinfo, query or fragment"
    end

    :ok
  end

  defp required!(env, key) do
    value = Map.get(env, key)
    unless present?(value), do: raise(ArgumentError, "#{key} is required")
    value
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
