defmodule KithWeb.WebauthnController do
  @moduledoc """
  JSON endpoints for WebAuthn registration and authentication.

  Registration (requires authenticated user):
    POST /auth/webauthn/register/challenge  — generate & return publicKey options
    POST /auth/webauthn/register/complete   — validate attestation, store credential

  Authentication (public):
    POST /auth/webauthn/authenticate/challenge  — generate & return publicKey options
    POST /auth/webauthn/authenticate/complete   — validate assertion, create session
  """

  use KithWeb, :controller

  alias Kith.Accounts
  alias Kith.Accounts.CoseKey
  alias KithWeb.UserAuth

  # ── Registration ──────────────────────────────────────────────────

  @doc """
  Generates a registration challenge and returns publicKey options as JSON.
  The challenge is stored in the session.
  """
  def register_challenge(conn, _params) do
    user = conn.assigns.current_scope.user
    wax_opts = Accounts.webauthn_opts()
    challenge = Wax.new_registration_challenge(wax_opts)

    # Existing credential IDs to exclude (prevent re-registration)
    exclude_credentials =
      Accounts.list_webauthn_credentials(user)
      |> Enum.map(fn cred ->
        %{id: Base.url_encode64(cred.credential_id, padding: false), type: "public-key"}
      end)

    conn
    |> put_session(:webauthn_challenge, challenge)
    |> json(%{
      publicKey: %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        rp: %{
          name: "Kith",
          id: challenge.rp_id
        },
        user: %{
          id: Base.url_encode64(to_string(user.id), padding: false),
          name: user.email,
          displayName: user.display_name || user.email
        },
        pubKeyCredParams: [
          %{type: "public-key", alg: -7},
          %{type: "public-key", alg: -257}
        ],
        timeout: 60_000,
        attestation: "none",
        excludeCredentials: exclude_credentials,
        authenticatorSelection: %{
          residentKey: "preferred",
          userVerification: "preferred"
        }
      }
    })
  end

  @doc """
  Validates the registration attestation and stores the credential.
  """
  def register_complete(conn, params) do
    user = conn.assigns.current_scope.user
    challenge = get_session(conn, :webauthn_challenge)

    if is_nil(challenge) do
      conn |> put_status(400) |> json(%{error: "No pending challenge"})
    else
      do_register_complete(conn, user, challenge, params)
    end
  end

  defp do_register_complete(conn, user, challenge, params) do
    attestation_object = Base.url_decode64!(params["attestationObject"], padding: false)
    client_data_json = Base.url_decode64!(params["clientDataJSON"], padding: false)
    name = params["name"] || "Security Key"

    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, {auth_data, _attestation_result}} ->
        handle_registration_result(conn, user, auth_data, name)

      {:error, error} ->
        conn
        |> delete_session(:webauthn_challenge)
        |> put_status(400)
        |> json(%{error: "Registration failed: #{Exception.message(error)}"})
    end
  end

  defp handle_registration_result(conn, user, auth_data, name) do
    case Accounts.register_webauthn_credential(user, auth_data, name) do
      {:ok, credential} ->
        conn
        |> delete_session(:webauthn_challenge)
        |> json(%{
          status: "ok",
          credential: %{
            id: credential.id,
            name: credential.name,
            created_at: credential.inserted_at
          }
        })

      {:error, changeset} ->
        conn
        |> delete_session(:webauthn_challenge)
        |> put_status(422)
        |> json(%{
          error: "Failed to store credential",
          details: changeset_errors(changeset)
        })
    end
  end

  # ── Authentication ────────────────────────────────────────────────

  @doc """
  Generates an authentication challenge. If email is provided, includes
  allowed credential IDs for that user.
  """
  def authenticate_challenge(conn, params) do
    wax_opts = Accounts.webauthn_opts()

    {allow_credentials, user_id} =
      case params["email"] do
        email when is_binary(email) and email != "" ->
          case Accounts.get_user_by_email(email) do
            nil ->
              {[], nil}

            user ->
              creds = Accounts.get_webauthn_allow_credentials(user)
              {creds, user.id}
          end

        _ ->
          {[], nil}
      end

    challenge_opts =
      if allow_credentials != [] do
        Keyword.put(wax_opts, :allow_credentials, allow_credentials)
      else
        wax_opts
      end

    challenge = Wax.new_authentication_challenge(challenge_opts)

    allow_cred_json =
      Enum.map(allow_credentials, fn {cred_id, _key} ->
        %{id: Base.url_encode64(cred_id, padding: false), type: "public-key"}
      end)

    conn
    |> put_session(:webauthn_auth_challenge, challenge)
    |> put_session(:webauthn_auth_user_id, user_id)
    |> json(%{
      publicKey: %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        rpId: challenge.rp_id,
        timeout: 60_000,
        userVerification: "preferred",
        allowCredentials: allow_cred_json
      }
    })
  end

  @doc """
  Validates the authentication assertion and creates a session.
  """
  def authenticate_complete(conn, params) do
    challenge = get_session(conn, :webauthn_auth_challenge)

    if is_nil(challenge) do
      conn |> put_status(400) |> json(%{error: "No pending challenge"})
    else
      do_authenticate_complete(conn, challenge, params)
    end
  end

  defp do_authenticate_complete(conn, challenge, params) do
    credential_id = Base.url_decode64!(params["credentialId"], padding: false)
    auth_data_bin = Base.url_decode64!(params["authenticatorData"], padding: false)
    signature = Base.url_decode64!(params["signature"], padding: false)
    client_data_json = Base.url_decode64!(params["clientDataJSON"], padding: false)

    case Accounts.get_webauthn_credential_by_credential_id(credential_id) do
      nil ->
        conn
        |> delete_session(:webauthn_auth_challenge)
        |> put_status(401)
        |> json(%{error: "Unknown credential"})

      db_credential ->
        verify_credential(
          conn,
          db_credential,
          credential_id,
          auth_data_bin,
          signature,
          client_data_json,
          challenge
        )
    end
  end

  defp verify_credential(
         conn,
         db_credential,
         credential_id,
         auth_data_bin,
         signature,
         client_data_json,
         challenge
       ) do
    with {:ok, cose_key} <- CoseKey.decode(db_credential.public_key),
         {:ok, auth_data} <-
           authenticate_assertion(
             credential_id,
             auth_data_bin,
             signature,
             client_data_json,
             challenge,
             [{credential_id, cose_key}]
           ) do
      Accounts.touch_webauthn_credential(db_credential, auth_data.sign_count)
      user = Accounts.get_user!(db_credential.user_id)

      conn
      |> delete_session(:webauthn_auth_challenge)
      |> delete_session(:webauthn_auth_user_id)
      |> UserAuth.log_in_user(user, %{"remember_me" => "false"})
    else
      {:error, :invalid_key} ->
        conn
        |> delete_session(:webauthn_auth_challenge)
        |> delete_session(:webauthn_auth_user_id)
        |> put_status(401)
        |> json(%{error: "Invalid stored credential"})

      {:error, error} ->
        conn
        |> delete_session(:webauthn_auth_challenge)
        |> put_status(401)
        |> json(%{error: "Authentication failed: #{Exception.message(error)}"})
    end
  end

  # A structurally valid stored EC point can still be invalid for the curve.
  # OTP raises badarg for those keys; treat that as a rejected credential.
  defp authenticate_assertion(id, auth_data, signature, client_data, challenge, credentials) do
    Wax.authenticate(id, auth_data, signature, client_data, challenge, credentials)
  rescue
    ArgumentError ->
      {:error, :invalid_key}

    error in ErlangError ->
      case error.original do
        {:badarg, _, _} -> {:error, :invalid_key}
        :badarg -> {:error, :invalid_key}
        _ -> reraise error, __STACKTRACE__
      end
  end

  # ── Credential Management ─────────────────────────────────────────

  @doc """
  Lists all WebAuthn credentials for the current user.
  """
  def list_credentials(conn, _params) do
    user = conn.assigns.current_scope.user
    credentials = Accounts.list_webauthn_credentials(user)

    json(conn, %{
      credentials:
        Enum.map(credentials, fn c ->
          %{
            id: c.id,
            name: c.name,
            created_at: c.inserted_at,
            last_used_at: c.last_used_at
          }
        end)
    })
  end

  @doc """
  Deletes a WebAuthn credential.
  """
  def delete_credential(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    case Accounts.delete_webauthn_credential(user, id) do
      {:ok, _credential} ->
        json(conn, %{status: "ok"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Credential not found"})

      {:error, :last_credential} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Cannot remove your last credential. Add a password or another key first."
        })
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
