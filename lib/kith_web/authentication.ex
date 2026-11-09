defmodule KithWeb.Authentication do
  @moduledoc "Completion boundary for verified password and OIDC first factors."
  import Plug.Conn
  import Phoenix.Controller
  alias Kith.Accounts
  alias Kith.Auth.{Challenges, Policy}
  alias KithWeb.UserAuth

  def require_recent(user, max_age_seconds \\ 600)

  def require_recent(%Accounts.User{} = user, max_age) do
    persisted = Kith.Repo.get(Accounts.User, user.id)

    if not is_nil(persisted) and fresh?(user.authenticated_at, max_age) and
         (not persisted.totp_enabled or fresh?(user.mfa_authenticated_at, max_age)),
       do: :ok,
       else: {:error, :reauthentication_required}
  end

  def require_recent(_, _), do: {:error, :reauthentication_required}

  defp fresh?(%DateTime{} = timestamp, max_age) do
    age = DateTime.diff(DateTime.utc_now(:second), timestamp)
    age >= 0 and age <= max_age
  end

  defp fresh?(_, _), do: false

  @doc """
  Completes a consumed protocol flow with its verified principal.

  Task 8 may supply `browser_binding:` from the Lax cookie already verified by
  transaction consumption when the Strict cookie is absent. The supplied value
  must match the consumed flow's binding hash; never pass public intent/owner
  parameters. Omitting options retains the current session binding behavior.
  """
  def begin_oidc(
        conn,
        user,
        %Kith.Auth.OIDC.Transaction{} = flow,
        %Kith.Auth.Principal{} = principal,
        opts \\ []
      ) do
    binding = Keyword.get(opts, :browser_binding)

    if valid_oidc_completion?(user, flow, principal) and verified_binding?(flow, binding) do
      begin(conn, user, %{
        intent: flow.intent,
        browser_binding: binding,
        method: :oidc,
        principal: principal,
        session_token: flow.session_token,
        return_to: flow.return_to,
        authenticated_at: DateTime.utc_now(:second)
      })
    else
      invalid(conn)
    end
  end

  defp verified_binding?(_flow, nil), do: true

  defp verified_binding?(%{binding_hash: hash}, binding)
       when is_binary(hash) and is_binary(binding),
       do: Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, binding))

  defp verified_binding?(_, _), do: false

  defp valid_oidc_completion?(user, flow, principal) do
    flow.consumed_at != nil and flow.issuer == principal.issuer and
      valid_oidc_intent?(user, flow, principal)
  end

  defp valid_oidc_intent?(_user, %{intent: :login}, _principal), do: true

  defp valid_oidc_intent?(user, %{intent: intent} = flow, principal)
       when intent in [:link, :reauth] do
    flow.user_id == user.id and is_integer(principal.auth_time) and
      principal.auth_time >= DateTime.to_unix(flow.initiated_at) - 60 and
      principal.auth_time <= System.os_time(:second) + 60 and
      (intent == :link or same_identity?(user, principal))
  end

  defp valid_oidc_intent?(_, _, _), do: false

  defp same_identity?(user, principal) do
    case Accounts.OIDC.resolve(principal) do
      {:ok, %{id: id}} -> id == user.id
      _ -> false
    end
  end

  @doc "Only pass server-verified first-factor evidence and transaction context."
  def begin(conn, user, attrs) do
    user = Accounts.get_user!(user.id)

    completion =
      Map.merge(
        %{
          intent: :login,
          authenticated_at: DateTime.utc_now(:second),
          method: :oidc,
          return_to: get_session(conn, :user_return_to),
          remember_me: false,
          mfa_authenticated_at: nil
        },
        attrs
      )
      |> Map.put(:user, user)

    if Challenges.validate_origin(user, completion) == :ok do
      begin_verified(conn, user, completion)
    else
      invalid(conn)
    end
  end

  defp begin_verified(conn, %{totp_enabled: true} = user, completion) do
    binding =
      completion[:browser_binding] || get_session(conn, :auth_challenge_binding) ||
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, handle} = Challenges.issue(user, Map.put(completion, :browser_binding, binding))

    conn
    |> put_session(:auth_challenge_binding, binding)
    |> put_session(:totp_token, handle)
    |> redirect(to: "/users/two-factor")
  end

  defp begin_verified(conn, _user, completion), do: finish(conn, completion)

  def finish(conn, %{user: user} = completion) do
    user = Accounts.get_user!(user.id)

    user = %{
      user
      | authenticated_at: completion.authenticated_at,
        mfa_authenticated_at: completion[:mfa_authenticated_at]
    }

    with true <-
           completion[:method] not in [:password, "password"] or
             Policy.password_login_enabled?(),
         :ok <- Challenges.validate_origin(user, completion),
         :ok <- require_recent(user),
         :ok <- complete_intent(user, completion) do
      # This browser may have other pending MFA flows. Retain their cancellation
      # identity across rotation so logout can revoke them without breaking tabs.
      binding = completion[:browser_binding] || get_session(conn, :auth_challenge_binding)
      token = completion[:session_token] || get_session(conn, :user_token)
      if token, do: Accounts.delete_user_session_token(token)

      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:auth_challenge_binding, binding)
      |> put_session(:user_return_to, safe_return_to(completion[:return_to]))
      |> put_flash(:info, "Authentication completed successfully.")
      |> UserAuth.log_in_user(user, %{
        "remember_me" => to_string(completion[:remember_me] == true)
      })
    else
      _ -> invalid(conn)
    end
  end

  defp complete_intent(_user, %{intent: :login}), do: :ok
  defp complete_intent(_user, %{intent: :reauth, principal: nil}), do: :ok

  defp complete_intent(user, %{intent: :reauth, principal: principal}) do
    case Accounts.OIDC.resolve(principal) do
      {:ok, %{id: id}} when id == user.id -> :ok
      _ -> {:error, :invalid}
    end
  end

  defp complete_intent(_user, %{intent: :reauth}), do: :ok

  defp complete_intent(user, %{intent: :link, principal: principal}) do
    case Accounts.OIDC.link(user, principal) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp complete_intent(_, _), do: {:error, :invalid}

  def safe_return_to("/" <> rest = path) do
    if not String.starts_with?(rest, "/") and not Regex.match?(~r/[\\%\s\x00-\x1f]/, rest),
      do: path,
      else: "/settings/security"
  end

  def safe_return_to(_), do: "/dashboard"

  defp invalid(conn) do
    conn
    |> delete_session(:totp_token)
    |> put_flash(:error, "Your authentication has expired. Please try again.")
    |> redirect(to: "/users/log-in")
  end
end
