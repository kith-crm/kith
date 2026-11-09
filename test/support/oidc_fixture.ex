defmodule Kith.OIDCFixture do
  @moduledoc "Real HTTPS OpenID issuer with RSA-signed tokens and per-test controllable responses."
  use Plug.Router
  plug :match
  plug :dispatch

  def start do
    dir = Path.join(System.tmp_dir!(), "kith-oidc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    key = Path.join(dir, "key.pem")
    cert = Path.join(dir, "cert.pem")

    ca_key = Path.join(dir, "ca-key.pem")
    ca = Path.join(dir, "ca.pem")
    csr = Path.join(dir, "leaf.csr")
    extensions = Path.join(dir, "leaf.ext")

    File.write!(
      extensions,
      "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n"
    )

    openssl([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      ca_key,
      "-out",
      ca,
      "-days",
      "1",
      "-subj",
      "/CN=Kith OIDC test CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE"
    ])

    openssl([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      key,
      "-out",
      csr,
      "-subj",
      "/CN=localhost"
    ])

    openssl([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      ca,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-out",
      cert,
      "-days",
      "1",
      "-extfile",
      extensions
    ])

    pem = File.read!(key)
    [entry] = :public_key.pem_decode(pem)
    private = :public_key.pem_entry_decode(entry)

    jwk = %{
      "kty" => "RSA",
      "kid" => "one",
      "alg" => "RS256",
      "use" => "sig",
      "n" => integer(elem(private, 2)),
      "e" => integer(elem(private, 3))
    }

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          pem: pem,
          jwk: jwk,
          claims: %{},
          requests: [],
          behavior: %{},
          metadata: %{},
          codes: %{},
          client_id: "kith",
          client_secret: "fixture-secret",
          redirect_uris: ["https://kith.test/auth/oidc/callback"]
        }
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, {:issuer_agent, agent}},
        scheme: :https,
        port: 0,
        ip: {127, 0, 0, 1},
        certfile: cert,
        keyfile: key,
        startup_log: false
      )

    Process.unlink(server)
    Process.unlink(agent)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    issuer = "https://localhost:#{port}"
    Agent.update(agent, &Map.put(&1, :issuer, issuer))

    %{
      agent: agent,
      server: server,
      dir: dir,
      config: [
        issuer: issuer,
        client_id: "kith",
        client_secret: "fixture-secret",
        cacertfile: ca
      ]
    }
  end

  def stop(fixture) do
    if Process.alive?(fixture.server), do: GenServer.stop(fixture.server)
    if Process.alive?(fixture.agent), do: Agent.stop(fixture.agent)
    File.rm_rf!(fixture.dir)
  end

  def update(fixture, updates), do: Agent.update(fixture.agent, &Map.merge(&1, updates))
  def requests(fixture), do: Agent.get(fixture.agent, &Enum.reverse(&1.requests))
  def init(opts), do: opts

  def call(conn, {:issuer_agent, agent}),
    do: super(Plug.Conn.put_private(conn, :issuer_agent, agent), [])

  match _ do
    agent = conn.private.issuer_agent
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    Agent.update(
      agent,
      &Map.update!(&1, :requests, fn requests ->
        [{conn.request_path, body, conn.req_headers} | requests]
      end)
    )

    conn = put_private(conn, :request_body, body)
    state = Agent.get(agent, & &1)
    behavior = state.behavior[conn.request_path]

    conn =
      case behavior do
        {:delay, ms} ->
          Process.sleep(ms)
          conn

        _ ->
          conn
      end

    case behavior do
      {:redirect, url} -> conn |> put_resp_header("location", url) |> send_resp(302, "")
      {:status, status} -> send_resp(conn, status, "failure")
      _ -> respond(conn, state)
    end
  end

  defp respond(%{request_path: "/.well-known/openid-configuration"} = conn, state) do
    json(
      conn,
      Map.merge(
        %{
          "issuer" => state.issuer,
          "authorization_endpoint" => state.issuer <> "/authorize",
          "token_endpoint" => state.issuer <> "/token",
          "jwks_uri" => state.issuer <> "/jwks",
          "response_types_supported" => ["code"],
          "response_modes_supported" => ["query"],
          "grant_types_supported" => ["authorization_code"],
          "token_endpoint_auth_methods_supported" => ["client_secret_basic"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "code_challenge_methods_supported" => ["S256"]
        },
        state.metadata
      )
    )
  end

  defp respond(%{request_path: "/jwks"} = conn, state), do: json(conn, %{"keys" => [state.jwk]})

  defp respond(%{request_path: "/token"} = conn, state) do
    params = URI.decode_query(conn.private.request_body)

    issued =
      Agent.get_and_update(conn.private.issuer_agent, fn current ->
        {issued, codes} = Map.pop(current.codes, params["code"])
        {issued, %{current | codes: codes}}
      end)

    if valid_redemption?(conn, params, issued, state) do
      token_response(conn, state, issued)
    else
      conn |> put_status(400) |> json(%{"error" => "invalid_grant"})
    end
  end

  defp respond(%{request_path: "/userinfo"} = conn, state),
    do: json(conn, state[:userinfo] || %{"sub" => "subject"})

  defp respond(%{request_path: "/authorize"} = conn, state) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    if valid_authorization?(conn, params, state) do
      code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      issued = %{
        client_id: params["client_id"],
        redirect_uri: params["redirect_uri"],
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        expires_at: System.monotonic_time(:second) + 300
      }

      Agent.update(conn.private.issuer_agent, &put_in(&1, [:codes, code], issued))

      url =
        params["redirect_uri"] <>
          "?" <> URI.encode_query(%{"code" => code, "state" => params["state"]})

      conn |> put_resp_header("location", url) |> send_resp(302, "")
    else
      conn |> put_status(400) |> json(%{"error" => "invalid_request"})
    end
  end

  defp respond(conn, _), do: send_resp(conn, 404, "")

  defp valid_authorization?(conn, params, state) do
    conn.method == "GET" and params["client_id"] == state.client_id and
      params["redirect_uri"] in state.redirect_uris and params["response_type"] == "code" and
      params["response_mode"] == "query" and params["code_challenge_method"] == "S256" and
      is_binary(params["code_challenge"]) and is_binary(params["nonce"])
  end

  defp valid_redemption?(_, _, nil, _), do: false

  defp valid_redemption?(conn, params, issued, state) do
    expected_auth = "Basic " <> Base.encode64(state.client_id <> ":" <> state.client_secret)

    conn.method == "POST" and get_req_header(conn, "authorization") == [expected_auth] and
      issued.client_id == state.client_id and issued.redirect_uri == params["redirect_uri"] and
      params["grant_type"] == "authorization_code" and
      issued.expires_at > System.monotonic_time(:second) and
      valid_verifier?(params["code_verifier"], issued.challenge)
  end

  defp valid_verifier?(verifier, challenge) when is_binary(verifier) do
    actual = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    Plug.Crypto.secure_compare(actual, challenge)
  end

  defp valid_verifier?(_, _), do: false

  defp token_response(conn, state, issued) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => state.issuer,
          "sub" => "subject",
          "aud" => "kith",
          "iat" => now,
          "exp" => now + 300,
          "email" => "person@example.test",
          "email_verified" => true,
          "nonce" => issued.nonce
        },
        state.claims
      )

    signing_opts =
      if state[:omit_kid], do: [], else: [private_key_id: state[:kid] || state.jwk["kid"]]

    {:ok, token} =
      Assent.JWTAdapter.sign(
        claims,
        state[:alg] || "RS256",
        state[:signing_key] || state.pem,
        signing_opts
      )

    json(conn, %{
      "access_token" => "fixture-access",
      "token_type" => "Bearer",
      "id_token" => Map.get(state, :token_override, token)
    })
  end

  defp json(conn, data),
    do:
      conn
      |> put_resp_header("cache-control", "max-age=600")
      |> put_resp_content_type("application/json")
      |> send_resp(conn.status || 200, Jason.encode!(data))

  defp integer(value), do: value |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  defp openssl(args) do
    {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
  end
end
