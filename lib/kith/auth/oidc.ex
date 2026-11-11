defmodule Kith.Auth.OIDC do
  @moduledoc "Confidential code-flow boundary. Provider credentials and tokens never leave this module."
  alias Assent.Strategy.OIDC, as: AssentOIDC
  alias Kith.Auth.OIDC.{Metadata, Transaction}
  alias Kith.Auth.Principal

  def authorize(%Transaction{} = flow, config) do
    with true <-
           flow.issuer == config[:issuer] and is_nil(flow.consumed_at) and
             unexpired?(flow, config),
         {:ok, metadata} <- Metadata.get(config),
         {:ok, %{url: url}} <- AssentOIDC.authorize_url(options(flow, config, metadata)) do
      # Assent 0.3.2 only generates PKCE verifiers; replace its generated challenge
      # with the challenge for the already persisted transaction verifier.
      uri = URI.parse(url)

      query =
        URI.decode_query(uri.query) |> Map.put("code_challenge", challenge(flow.code_verifier))

      {:ok, URI.to_string(%{uri | query: URI.encode_query(query)})}
    else
      false -> {:error, :invalid_transaction}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  def callback(%Transaction{} = flow, params, config) when is_map(params) do
    with true <- valid_callback?(flow, params, config),
         {:ok, metadata} <- Metadata.get(config),
         {:ok, %{user: principal}} <-
           AssentOIDC.callback(options(flow, config, metadata), params, __MODULE__) do
      {:ok, principal}
    else
      false -> {:error, :invalid_transaction}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  # Assent callback strategy hook; intentionally returns only verified identity.
  def fetch_user(config, %{"id_token" => token} = tokens) when is_binary(token) do
    metadata = config[:openid_configuration]

    with {:ok, header} <- header(token),
         {:ok, key} <- Metadata.key(metadata, header["kid"], config),
         {:ok, %{verified?: true, claims: claims}} <- Assent.JWTAdapter.verify(token, key),
         true <- valid_claims?(claims, config),
         :ok <- userinfo(metadata, tokens, claims, config) do
      {:ok,
       %Principal{
         issuer: config[:issuer],
         subject: claims["sub"],
         email: claims["email"],
         email_verified: claims["email_verified"],
         name: claims["name"],
         auth_time: claims["auth_time"]
       }}
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def fetch_user(_, _), do: {:error, :invalid_token}

  defp options(flow, config, metadata) do
    params = [scope: "email profile", response_mode: "query"]

    params =
      if flow.intent in [:link, :reauth],
        do: Keyword.merge(params, max_age: 0, prompt: "login"),
        else: params

    config ++
      [
        base_url: flow.issuer,
        redirect_uri: flow.redirect_uri,
        state: flow.state,
        code_verifier: true,
        nonce: flow.nonce,
        authorization_params: params,
        openid_configuration: metadata,
        client_authentication_method: "client_secret_basic",
        id_token_signed_response_alg: "RS256",
        http_adapter: {Metadata.HTTPAdapter, config},
        session_params: %{state: flow.state, nonce: flow.nonce, code_verifier: flow.code_verifier},
        transaction: flow
      ]
  end

  defp valid_callback?(flow, params, config) do
    flow.issuer == config[:issuer] and not is_nil(flow.consumed_at) and
      is_binary(params["state"]) and Plug.Crypto.secure_compare(flow.state, params["state"]) and
      (is_nil(params["iss"]) or params["iss"] == flow.issuer) and
      unexpired?(flow, config)
  end

  defp unexpired?(flow, config) do
    DateTime.compare(flow.expires_at, Keyword.get(config, :now, DateTime.utc_now())) == :gt
  end

  defp header(token) do
    with [header, _, _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(header, padding: false),
         {:ok, %{"alg" => "RS256"} = header} <- Jason.decode(decoded),
         true <- optional?(header, "kid", &is_binary/1) and not Map.has_key?(header, "crit") do
      {:ok, header}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp valid_claims?(claims, config) when is_map(claims) do
    now = config |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.to_unix()
    flow = config[:transaction]

    claims["iss"] == config[:issuer] and nonempty?(claims["sub"]) and
      audience?(claims, config[:client_id]) and
      times?(claims, now) and nonce?(claims["nonce"], flow.nonce) and
      optional_claims?(claims) and fresh?(claims["auth_time"], flow, now)
  end

  defp valid_claims?(_, _), do: false

  defp times?(claims, now) do
    is_integer(claims["exp"]) and claims["exp"] > now - 60 and
      is_integer(claims["iat"]) and claims["iat"] >= now - 360 and claims["iat"] <= now + 60 and
      optional?(claims, "nbf", &is_integer/1) and not_before?(claims["nbf"], now)
  end

  defp not_before?(nil, _), do: true
  defp not_before?(nbf, now), do: nbf <= now + 60

  defp nonce?(nonce, expected),
    do: is_binary(nonce) and Plug.Crypto.secure_compare(nonce, expected)

  defp optional_claims?(claims) do
    optional?(claims, "email_verified", &is_boolean/1) and
      optional?(claims, "email", &is_binary/1) and optional?(claims, "name", &is_binary/1) and
      optional?(claims, "auth_time", &is_integer/1)
  end

  defp audience?(claims, client) do
    audiences = claims["aud"]

    authorized_party?(claims, client) and includes_client?(audiences, client) and
      (not is_list(audiences) or length(audiences) <= 1 or claims["azp"] == client)
  end

  defp authorized_party?(%{"azp" => azp}, client), do: azp == client
  defp authorized_party?(_, _), do: true

  defp includes_client?(audiences, client) when is_list(audiences) do
    audiences != [] and Enum.all?(audiences, &nonempty?/1) and client in audiences
  end

  defp includes_client?(audience, client), do: audience == client

  defp optional?(claims, key, predicate),
    do: not Map.has_key?(claims, key) or predicate.(claims[key])

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp fresh?(auth_time, %{intent: intent} = flow, now) when intent in [:link, :reauth] do
    is_integer(auth_time) and auth_time >= DateTime.to_unix(flow.initiated_at) - 60 and
      auth_time <= now + 60
  end

  defp fresh?(auth_time, _, now), do: is_nil(auth_time) or auth_time <= now + 60

  defp userinfo(%{"userinfo_endpoint" => url}, tokens, claims, config) do
    with access when is_binary(access) <- tokens["access_token"],
         {:ok, %{status: 200, body: body}} <-
           Metadata.HTTPAdapter.request(
             :get,
             url,
             nil,
             [{"authorization", "Bearer " <> access}],
             config
           ),
         {:ok, %{"sub" => sub}} <- Jason.decode(body),
         true <- sub == claims["sub"] do
      :ok
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp userinfo(_, _, _, _), do: :ok
  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
end
