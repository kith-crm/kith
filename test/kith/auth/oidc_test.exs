defmodule Kith.Auth.OIDCTest do
  use Kith.DataCase, async: false
  alias Kith.Auth.OIDC
  alias Kith.Auth.OIDC.{Metadata, Transactions}
  alias Kith.OIDCFixture

  setup do
    fixture = OIDCFixture.start()
    on_exit(fn -> OIDCFixture.stop(fixture) end)
    {:ok, fixture: fixture, config: fixture.config}
  end

  defp flow(config, intent \\ :login) do
    attrs = %{
      intent: intent,
      issuer: config[:issuer],
      redirect_uri: "https://kith.test/auth/oidc/callback",
      return_to: "/dashboard"
    }

    {:ok, flow} = Transactions.start(attrs, "browser")
    flow
  end

  defp authorize(flow, config) do
    {:ok, url} = OIDC.authorize(flow, config)

    {:ok, %{status: 302, headers: headers}} =
      Metadata.HTTPAdapter.request(:get, url, nil, [], config)

    {"location", location} = List.keyfind(headers, "location", 0)
    uri = URI.parse(location)
    assert URI.to_string(%{uri | query: nil}) == flow.redirect_uri
    URI.decode_query(uri.query)
  end

  defp redeem(flow, params, config) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => params["code"],
        "redirect_uri" => flow.redirect_uri,
        "code_verifier" => flow.code_verifier
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"authorization",
       "Basic " <> Base.encode64(config[:client_id] <> ":" <> config[:client_secret])}
    ]

    Metadata.HTTPAdapter.request(:post, config[:issuer] <> "/token", body, headers, config)
  end

  defp callback(_fixture, flow, config) do
    params = authorize(flow, config)
    {:ok, consumed} = Transactions.consume(params["state"], "browser")
    OIDC.callback(consumed, params, config)
  end

  test "arbitrary request parameters cannot select discovery" do
    assert {:error, :invalid_metadata} = Metadata.get(%{"issuer" => "https://attacker.test"})
  end

  test "authorization uses S256, a string nonce, code/query and exact redirect", %{config: config} do
    flow = flow(config)
    assert {:ok, url} = OIDC.authorize(flow, config)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, flow.code_verifier), padding: false)

    assert query["code_challenge_method"] == "S256"
    assert query["nonce"] == flow.nonce
    assert query["state"] == flow.state
    assert query["response_type"] == "code"
    refute Map.has_key?(query, "prompt")
    refute Map.has_key?(query, "max_age")
    assert query["response_mode"] == "query"
    assert query["scope"] == "openid email profile"
    assert query["redirect_uri"] == flow.redirect_uri
    refute Map.has_key?(query, "code_verifier")
  end

  test "signed callback restores verifier and returns only a verified Principal", %{
    fixture: fixture,
    config: config
  } do
    flow = flow(config)
    assert {:ok, principal} = callback(fixture, flow, config)
    assert principal.__struct__ == Kith.Auth.Principal
    assert principal.issuer == config[:issuer]
    assert principal.subject == "subject"
    assert principal.email_verified == true

    [{"/token", body, headers}] =
      Enum.filter(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/token"))

    assert URI.decode_query(body)["code_verifier"] == flow.code_verifier
    assert {"authorization", "Basic " <> Base.encode64("kith:fixture-secret")} in headers
  end

  test "unconsumed and switched-issuer transactions are rejected before redemption", %{
    fixture: fixture,
    config: config
  } do
    flow = flow(config)
    assert {:error, _} = OIDC.callback(flow, %{"state" => flow.state, "code" => "code"}, config)
    assert {:error, _} = OIDC.authorize(flow, Keyword.put(config, :issuer, "https://other.test"))
    assert OIDCFixture.requests(fixture) == []
  end

  test "invalid signed claim values fail closed", %{fixture: fixture, config: config} do
    now = System.system_time(:second)
    # Sequential HTTPS exchanges must not move a +61s rejection into the +60s allowance.
    config = Keyword.put(config, :now, DateTime.from_unix!(now))

    for claims <- [
          %{"iss" => "https://other.test"},
          %{"aud" => "other"},
          %{"aud" => 2},
          %{"aud" => ["kith", "other"]},
          %{"azp" => "other"},
          %{"sub" => ""},
          %{"sub" => 3},
          %{"exp" => now - 61},
          %{"exp" => "forever"},
          %{"iat" => now + 61},
          %{"iat" => now - 361},
          %{"iat" => nil},
          %{"nonce" => "wrong"},
          %{"nonce" => true},
          %{"email_verified" => "true"},
          %{"email" => 3},
          %{"auth_time" => "today"}
        ] do
      OIDCFixture.update(fixture, %{claims: claims})
      assert {:error, :invalid_token} = callback(fixture, flow(config), config), inspect(claims)
    end
  end

  test "RS256 signature and algorithm are pinned", %{fixture: fixture, config: config} do
    OIDCFixture.update(fixture, %{alg: "HS256", signing_key: "fixture-secret"})
    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
    other = OIDCFixture.start()
    pem = Agent.get(other.agent, & &1.pem)
    OIDCFixture.stop(other)
    OIDCFixture.update(fixture, %{alg: "RS256", signing_key: pem})
    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
  end

  test "metadata exact issuer and advertised profile are validated", %{
    fixture: fixture,
    config: config
  } do
    for metadata <- [
          %{"issuer" => config[:issuer] <> "/"},
          %{"token_endpoint" => "http://localhost/token"},
          %{"token_endpoint_auth_methods_supported" => ["client_secret_post"]},
          %{"id_token_signing_alg_values_supported" => ["HS256"]},
          %{"code_challenge_methods_supported" => ["plain"]},
          %{"response_types_supported" => ["token"]},
          %{"response_modes_supported" => ["form_post"]}
        ] do
      OIDCFixture.update(fixture, %{metadata: metadata})
      assert {:error, :invalid_metadata} = Metadata.get(config)
    end
  end

  test "UserInfo must preserve the verified subject", %{fixture: fixture, config: config} do
    OIDCFixture.update(fixture, %{
      metadata: %{"userinfo_endpoint" => config[:issuer] <> "/userinfo"},
      userinfo: %{"sub" => "attacker"}
    })

    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
  end

  test "discovery redirects and untrusted TLS are unavailable", %{
    fixture: fixture,
    config: config
  } do
    assert {:error, :unavailable} = Metadata.get(Keyword.delete(config, :cacertfile))

    OIDCFixture.update(fixture, %{
      behavior: %{"/.well-known/openid-configuration" => {:redirect, config[:issuer] <> "/other"}}
    })

    assert {:error, :unavailable} = Metadata.get(config)
  end

  test "the real HTTPS adapter bounds a delayed response to five seconds", %{
    fixture: fixture,
    config: config
  } do
    OIDCFixture.update(fixture, %{
      behavior: %{"/.well-known/openid-configuration" => {:delay, 6500}}
    })

    started = System.monotonic_time(:millisecond)
    assert {:error, :unavailable} = Metadata.get(config)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4500 and elapsed < 6000
  end

  test "successful metadata and keys expire at 300 seconds", %{fixture: fixture, config: config} do
    {:ok, clock} = Agent.start_link(fn -> 1000 end)
    config = Keyword.put(config, :clock, fn -> Agent.get(clock, & &1) end)
    assert {:ok, _} = Metadata.get(config)
    assert {:ok, _} = Metadata.get(config)

    assert Enum.count(
             OIDCFixture.requests(fixture),
             &(elem(&1, 0) == "/.well-known/openid-configuration")
           ) == 1

    Agent.update(clock, fn _ -> 1300 end)
    assert {:ok, _} = Metadata.get(config)

    assert Enum.count(
             OIDCFixture.requests(fixture),
             &(elem(&1, 0) == "/.well-known/openid-configuration")
           ) == 2
  end

  test "unknown kid refreshes keys once and failed refresh cannot use stale keys", %{
    fixture: fixture,
    config: config
  } do
    assert {:ok, _} = callback(fixture, flow(config), config)
    rotated = OIDCFixture.start()
    %{jwk: jwk, pem: pem} = Agent.get(rotated.agent, & &1)
    OIDCFixture.stop(rotated)
    OIDCFixture.update(fixture, %{jwk: Map.put(jwk, "kid", "two"), pem: pem})
    assert {:ok, _} = callback(fixture, flow(config), config)
    assert Enum.count(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/jwks")) == 2
    OIDCFixture.update(fixture, %{kid: "unknown", behavior: %{"/jwks" => {:status, 503}}})
    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
    assert Enum.count(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/jwks")) == 3
  end

  test "JWKS expiry requires a successful fetch", %{fixture: fixture, config: config} do
    {:ok, clock} = Agent.start_link(fn -> 1000 end)
    config = Keyword.put(config, :clock, fn -> Agent.get(clock, & &1) end)
    assert {:ok, _} = callback(fixture, flow(config), config)
    Agent.update(clock, fn _ -> 1300 end)
    OIDCFixture.update(fixture, %{behavior: %{"/jwks" => {:status, 503}}})
    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
    assert Enum.count(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/jwks")) == 2
  end

  test "sensitive authentication requests interactive login and max_age and binds auth_time to initiation",
       %{
         fixture: fixture,
         config: config
       } do
    user = Kith.AccountsFixtures.user_fixture()

    for intent <- [:link, :reauth], offset <- [-61, -60, 0, 61] do
      {:ok, flow} =
        Transactions.start(
          %{
            intent: intent,
            issuer: config[:issuer],
            redirect_uri: "https://kith.test/auth/oidc/callback",
            return_to: "/settings/security",
            user_id: user.id,
            session_token: <<0, 1, 2>>
          },
          "browser"
        )

      now = DateTime.to_unix(flow.initiated_at)
      {:ok, url} = OIDC.authorize(flow, config)
      query = URI.decode_query(URI.parse(url).query)
      assert query["max_age"] == "0"
      assert query["prompt"] == "login"
      OIDCFixture.update(fixture, %{claims: %{"auth_time" => now + offset}})
      result = callback(fixture, flow, Keyword.put(config, :now, flow.initiated_at))

      if offset in [-60, 0],
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, :invalid_token})
    end
  end

  test "clock skew and initial token age accept only their specified boundaries", %{
    fixture: fixture,
    config: config
  } do
    now = DateTime.utc_now()
    seconds = DateTime.to_unix(now)
    config = Keyword.put(config, :now, now)

    for claims <- [
          %{"iat" => seconds - 360},
          %{"iat" => seconds + 60},
          %{"exp" => seconds - 59},
          %{"aud" => ["kith", "other"], "azp" => "kith"}
        ] do
      OIDCFixture.update(fixture, %{claims: claims})
      assert {:ok, _} = callback(fixture, flow(config), config)
    end

    OIDCFixture.update(fixture, %{claims: %{"exp" => seconds - 60}})
    assert {:error, :invalid_token} = callback(fixture, flow(config), config)
  end

  test "provider denial and wrong state do not redeem a code", %{fixture: fixture, config: config} do
    flow = flow(config)
    {:ok, consumed} = Transactions.consume(flow.state, "browser")

    assert {:error, _} =
             OIDC.callback(consumed, %{"state" => flow.state, "error" => "access_denied"}, config)

    assert {:error, _} = OIDC.callback(consumed, %{"state" => "wrong", "code" => "code"}, config)
    refute Enum.any?(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/token"))
    assert {:error, :invalid_transaction} = Transactions.consume(flow.state, "browser")
  end

  test "TLS handshake stalls hit the real three second connection timeout" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    acceptor =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        receive do
          :stop -> :gen_tcp.close(socket)
        after
          7000 -> :gen_tcp.close(socket)
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :unavailable} =
             Metadata.HTTPAdapter.request(:get, "https://localhost:#{port}/", nil, [], [])

    elapsed = System.monotonic_time(:millisecond) - started
    send(acceptor.pid, :stop)
    Task.await(acceptor)
    :gen_tcp.close(listener)
    assert elapsed >= 2500 and elapsed < 4200
  end

  test "expired flows cannot initiate provider authorization", %{fixture: fixture, config: config} do
    {:ok, old} =
      Transactions.start(
        %{
          intent: :login,
          issuer: config[:issuer],
          redirect_uri: "https://kith.test/auth/oidc/callback",
          return_to: "/dashboard"
        },
        "browser",
        now: DateTime.add(DateTime.utc_now(), -300)
      )

    assert {:error, :invalid_transaction} = OIDC.authorize(old, config)
    assert OIDCFixture.requests(fixture) == []
  end

  test "token redirects do not forward credentials", %{fixture: fixture, config: config} do
    OIDCFixture.update(fixture, %{
      behavior: %{"/token" => {:redirect, config[:issuer] <> "/credential-trap"}}
    })

    assert {:error, _} = callback(fixture, flow(config), config)
    refute Enum.any?(OIDCFixture.requests(fixture), &(elem(&1, 0) == "/credential-trap"))
  end

  test "hostname verification remains enabled with the fixture CA", %{config: config} do
    wrong_host = String.replace(config[:issuer], "localhost", "127.0.0.1")
    assert {:error, :unavailable} = Metadata.get(Keyword.put(config, :issuer, wrong_host))
  end

  test "unsigned and malformed JWTs fail closed", %{fixture: fixture, config: config} do
    unsigned =
      Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false) <>
        "." <> Base.url_encode64("{}", padding: false) <> "."

    for token <- [unsigned, "not-a-jwt", "e30.e30.invalid"] do
      OIDCFixture.update(fixture, %{token_override: token})
      assert {:error, :invalid_token} = callback(fixture, flow(config), config)
    end
  end

  test "a token without kid can use a single unambiguous RSA key", %{
    fixture: fixture,
    config: config
  } do
    OIDCFixture.update(fixture, %{omit_kid: true})
    assert {:ok, _} = callback(fixture, flow(config), config)
  end

  test "HTTPS authorization codes are unique and a redeemed code cannot be replayed", %{
    config: config
  } do
    flow = flow(config)
    params = authorize(flow, config)
    other = authorize(flow(config), config)
    refute params["code"] == other["code"]
    {:ok, consumed} = Transactions.consume(params["state"], "browser")

    assert {:ok, %Kith.Auth.Principal{subject: "subject"}} =
             OIDC.callback(consumed, params, config)

    assert {:ok, %{status: 400}} = redeem(consumed, params, config)
  end

  test "the token endpoint rejects a verifier not bound to the issued challenge", %{
    config: config
  } do
    flow = flow(config)
    params = authorize(flow, config)
    {:ok, consumed} = Transactions.consume(params["state"], "browser")

    assert {:error, _} =
             OIDC.callback(%{consumed | code_verifier: String.duplicate("x", 43)}, params, config)
  end

  test "the token endpoint binds codes to the redirect and authenticated client", %{
    config: config
  } do
    for change <- [:redirect, :client, :secret] do
      flow = flow(config)
      params = authorize(flow, config)
      {:ok, consumed} = Transactions.consume(params["state"], "browser")

      {consumed, config} =
        case change do
          :redirect -> {%{consumed | redirect_uri: "https://kith.test/other"}, config}
          :client -> {consumed, Keyword.put(config, :client_id, "other-client")}
          :secret -> {consumed, Keyword.put(config, :client_secret, "wrong-secret")}
        end

      assert {:ok, %{status: 400}} = redeem(consumed, params, config)
    end
  end

  test "the token endpoint rejects an unissued code", %{config: config} do
    flow = flow(config)
    {:ok, consumed} = Transactions.consume(flow.state, "browser")

    assert {:ok, %{status: 400}} = redeem(consumed, %{"code" => "never-issued"}, config)
  end
end
