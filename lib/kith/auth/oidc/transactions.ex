defmodule Kith.Auth.OIDC.Transactions do
  @moduledoc "Short-lived flow correlation. Consume before redeeming any callback, including denial."
  import Ecto.Query
  alias Kith.Auth.OIDC.Transaction
  alias Kith.Repo

  def start(attrs, browser_binding, opts \\ []) do
    with :ok <- validate(attrs, browser_binding) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      state = random()
      nonce = random()
      verifier = random()

      payload = %{
        "nonce" => nonce,
        "code_verifier" => verifier,
        "redirect_uri" => attrs.redirect_uri,
        "return_to" => attrs.return_to,
        "session_token" => encode_session(attrs[:session_token])
      }

      result =
        %Transaction{}
        |> Ecto.Changeset.change(%{
          state_hash: hash(state),
          binding_hash: hash(browser_binding),
          issuer: attrs.issuer,
          intent: attrs.intent,
          user_id: attrs[:user_id],
          payload: Jason.encode!(payload),
          initiated_at: now,
          expires_at: DateTime.add(now, 300)
        })
        |> Repo.insert(log: false)

      case result do
        {:ok, row} -> {:ok, restore(row, payload, state)}
        {:error, _} -> {:error, :invalid_transaction}
      end
    end
  end

  def consume(state, browser_binding, opts \\ [])

  def consume(state, browser_binding, opts)
      when is_binary(state) and is_binary(browser_binding) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      flow =
        Repo.one(from(f in Transaction, where: f.state_hash == ^hash(state), lock: "FOR UPDATE"),
          log: false
        )

      if valid?(flow, browser_binding, now) do
        flow = Repo.update!(Ecto.Changeset.change(flow, consumed_at: now), log: false)
        restore(flow, Jason.decode!(flow.payload), state)
      else
        Repo.rollback(:invalid_transaction)
      end
    end)
  end

  def consume(_, _, _), do: {:error, :invalid_transaction}

  defp valid?(nil, _, _), do: false

  defp valid?(flow, binding, now) do
    is_nil(flow.consumed_at) and DateTime.compare(flow.expires_at, now) == :gt and
      Plug.Crypto.secure_compare(flow.binding_hash, hash(binding))
  end

  defp restore(row, payload, state) do
    %{
      row
      | state: state,
        nonce: payload["nonce"],
        code_verifier: payload["code_verifier"],
        redirect_uri: payload["redirect_uri"],
        return_to: payload["return_to"],
        session_token: decode_session(payload["session_token"])
    }
  end

  defp validate(attrs, binding)
       when is_map(attrs) and is_binary(binding) and byte_size(binding) > 0 do
    valid =
      attrs[:intent] in [:login, :link, :reauth] and
        https?(attrs[:issuer]) and https?(attrs[:redirect_uri]) and local?(attrs[:return_to]) and
        ownership?(attrs)

    if valid, do: :ok, else: {:error, :invalid_transaction}
  end

  defp validate(_, _), do: {:error, :invalid_transaction}

  defp ownership?(%{intent: :login}), do: true
  defp ownership?(attrs), do: is_integer(attrs[:user_id]) and is_binary(attrs[:session_token])

  defp https?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil, query: nil}}
      when is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp https?(_), do: false

  defp local?("/" <> rest),
    do: not String.starts_with?(rest, "/") and not Regex.match?(~r/[\\%\s\x00-\x1f]/, rest)

  defp local?(_), do: false
  defp encode_session(nil), do: nil
  defp encode_session(token), do: Base.encode64(token)
  defp decode_session(nil), do: nil
  defp decode_session(token), do: Base.decode64!(token)
  defp hash(value), do: :crypto.hash(:sha256, value)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
