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
        %{pem: pem, jwk: jwk, claims: %{}, requests: [], behavior: %{}, metadata: %{}}
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
          "nonce" => state[:nonce]
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

  defp respond(%{request_path: "/userinfo"} = conn, state),
    do: json(conn, state[:userinfo] || %{"sub" => "subject"})

  defp respond(%{request_path: "/authorize"} = conn, state) do
    conn = fetch_query_params(conn)
    Agent.update(conn.private.issuer_agent, &Map.put(&1, :nonce, conn.query_params["nonce"]))

    url =
      conn.query_params["redirect_uri"] <>
        "?" <>
        URI.encode_query(%{"code" => "fixture-code", "state" => conn.query_params["state"]})

    conn |> put_resp_header("location", url) |> send_resp(302, state.issuer)
  end

  defp respond(conn, _), do: send_resp(conn, 404, "")

  defp json(conn, data),
    do:
      conn
      |> put_resp_header("cache-control", "max-age=600")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(data))

  defp integer(value), do: value |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  defp openssl(args) do
    {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
  end
end
