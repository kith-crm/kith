defmodule Kith.Auth.Challenges do
  @moduledoc "Browser-bound MFA completion, serialized across challenges for one user."
  import Ecto.Query
  alias Kith.Accounts
  alias Kith.Accounts.User
  alias Kith.Auth.{Challenge, Principal}
  alias Kith.Repo

  def issue(%User{} = user, attrs) do
    with true <- is_binary(attrs[:browser_binding]) and byte_size(attrs.browser_binding) >= 16,
         true <- attrs[:intent] in [:login, :reauth, :link],
         %DateTime{} <- attrs[:authenticated_at],
         :ok <- validate_origin(user, attrs) do
      handle = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      payload = %{
        "session_token" => encode_token(attrs[:session_token]),
        "return_to" => attrs[:return_to],
        "remember_me" => attrs[:remember_me] == true,
        "method" => to_string(attrs[:method] || :oidc),
        "principal" => encode_principal(attrs[:principal])
      }

      %Challenge{}
      |> Ecto.Changeset.change(%{
        handle_hash: hash(handle),
        binding_hash: hash(attrs.browser_binding),
        user_id: user.id,
        intent: attrs.intent,
        authenticated_at: attrs.authenticated_at,
        expires_at: DateTime.add(DateTime.utc_now(), 300),
        payload: Jason.encode!(payload)
      })
      |> Repo.insert!(log: false)

      {:ok, handle}
    else
      _ -> {:error, :invalid}
    end
  end

  def complete(handle, binding, code)
      when is_binary(handle) and is_binary(binding) and is_binary(code) do
    Repo.transaction(fn ->
      row =
        Repo.one(from(c in Challenge, where: c.handle_hash == ^hash(handle), lock: "FOR UPDATE"),
          log: false
        )

      validate_challenge!(row, binding)

      case Kith.RateLimiter.check_totp_user(row.user_id) do
        :ok -> :ok
        _ -> Repo.rollback(:rate_limited)
      end

      user =
        Repo.one!(from(u in User, where: u.id == ^row.user_id, lock: "FOR UPDATE"))
        |> Repo.preload(:account)

      payload = Jason.decode!(row.payload)

      completion = %{
        user: user,
        intent: row.intent,
        authenticated_at: row.authenticated_at,
        session_token: decode_token(payload["session_token"]),
        return_to: payload["return_to"],
        method: payload["method"],
        remember_me: payload["remember_me"],
        principal: decode_principal(payload["principal"])
      }

      unless validate_origin(user, completion) == :ok, do: Repo.rollback(:invalid)

      unless user.totp_enabled and
               (Accounts.valid_totp_code?(user.totp_secret, code) or
                  Accounts.use_recovery_code(user, code)),
             do: Repo.rollback(:invalid)

      now = DateTime.utc_now(:second)
      Repo.update!(Ecto.Changeset.change(row, consumed_at: DateTime.utc_now()), log: false)
      Map.put(completion, :mfa_authenticated_at, now)
    end)
  end

  def complete(_, _, _), do: {:error, :invalid}

  @doc "Invalidates pending MFA flows on logout, including login flows without a session token."
  def cancel_browser(binding) when is_binary(binding) do
    Repo.update_all(
      from(c in Challenge, where: c.binding_hash == ^hash(binding) and is_nil(c.consumed_at)),
      [set: [consumed_at: DateTime.utc_now()]],
      log: false
    )

    :ok
  end

  def cancel_browser(_), do: :ok

  @doc "Checks the originating session, including on callbacks without the Strict session cookie."
  def validate_origin(_user, %{intent: :login}), do: :ok

  def validate_origin(user, %{intent: intent, session_token: token})
      when intent in [:reauth, :link] and is_binary(token) do
    case Accounts.get_user_by_session_token(token) do
      {%{id: id}, _} when id == user.id -> :ok
      _ -> {:error, :invalid}
    end
  end

  def validate_origin(_, _), do: {:error, :invalid}

  defp validate_challenge!(nil, _), do: Repo.rollback(:invalid)

  defp validate_challenge!(row, binding) do
    cond do
      row.consumed_at != nil -> Repo.rollback(:invalid)
      not Plug.Crypto.secure_compare(row.binding_hash, hash(binding)) -> Repo.rollback(:invalid)
      DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt -> Repo.rollback(:expired)
      true -> :ok
    end
  end

  defp encode_principal(nil), do: nil
  defp encode_principal(%Principal{} = principal), do: Map.from_struct(principal)
  defp decode_principal(nil), do: nil

  defp decode_principal(p),
    do: %Principal{
      issuer: p["issuer"],
      subject: p["subject"],
      email: p["email"],
      email_verified: p["email_verified"],
      name: p["name"],
      auth_time: p["auth_time"]
    }

  defp encode_token(nil), do: nil
  defp encode_token(token), do: Base.encode64(token)
  defp decode_token(nil), do: nil
  defp decode_token(token), do: Base.decode64!(token)
  defp hash(value), do: :crypto.hash(:sha256, value)
end
