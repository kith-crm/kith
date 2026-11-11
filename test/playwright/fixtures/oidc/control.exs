if Mix.env() != :test or System.get_env("KITH_OIDC_E2E") != "1",
  do: raise("OIDC browser controls require the isolated test build")

defmodule Kith.OIDCBrowserControl do
  import Ecto.Query
  alias Kith.{Accounts, Repo}

  def run("prepare", args) do
    email = args["email"] || "browser-#{System.unique_integer([:positive])}@example.test"

    {:ok, user} =
      Accounts.register_user(%{
        "email" => email,
        "password" => "ValidP@ssword123!",
        "tos_accepted" => true
      })

    user =
      user
      |> Ecto.Changeset.change(
        confirmed_at: DateTime.utc_now(:second),
        role: args["role"] || "admin",
        account_id: args["account_id"] || user.account_id
      )
      |> Repo.update!()

    subject = "browser-#{user.id}"

    if args["linked"] != false do
      Repo.insert!(%Accounts.OIDCIdentity{user_id: user.id, issuer: issuer(), subject: subject})
    end

    base = %{email: email, user_id: user.id, account_id: user.account_id, subject: subject}

    if args["mfa"] do
      secret = Accounts.generate_totp_secret()

      {:ok, {_user, recovery}} =
        Accounts.enable_totp(
          %{user | authenticated_at: DateTime.utc_now(:second)},
          secret,
          :pot.totp(secret)
        )

      Map.merge(base, %{recovery: hd(recovery), secret: secret})
    else
      base
    end
  end

  def run("claims", args) do
    Kith.OIDCFixture.update(fixture(), %{
      claims: Map.merge(%{"auth_time" => System.system_time(:second)}, args)
    })

    %{ok: true}
  end

  def run("behavior", args) do
    behavior =
      case args["mode"] do
        "timeout" -> %{"/token" => {:delay, 6000}}
        "unavailable" -> %{"/.well-known/openid-configuration" => {:status, 503}}
        "deny" -> %{"/authorize" => {:redirect, args["redirect"]}}
        "normal" -> %{}
      end

    Kith.OIDCFixture.update(fixture(), %{behavior: behavior})
    config = Application.fetch_env!(:kith, :auth).oidc
    Kith.Cache.delete({Kith.Auth.OIDC.Metadata, config[:issuer], config[:cacertfile], :discovery})
    %{ok: true}
  end

  def run("expire", _args) do
    Repo.update_all(from(t in Kith.Auth.OIDC.Transaction, where: is_nil(t.consumed_at)),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    %{ok: true}
  end

  def run("revoke_sessions", args) do
    Repo.delete_all(
      from(t in Accounts.UserToken,
        where: t.user_id == ^args["user_id"] and t.context == "session"
      )
    )

    %{ok: true}
  end

  def run("stale", args) do
    Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.user_id == ^args["user_id"] and t.context == "session"
      ),
      set: [authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)]
    )

    %{ok: true}
  end

  def run("email_confirmation", args) do
    user = Accounts.get_user!(args["user_id"])

    changed =
      user
      |> Accounts.change_user_email(%{email: args["email"]})
      |> Ecto.Changeset.apply_changes()

    Accounts.deliver_user_update_email_instructions(changed, user.email, fn url ->
      Process.put(:fixture_confirmation, "/users/settings/confirm-email/" <> url)
      url
    end)

    %{url: Process.get(:fixture_confirmation)}
  end

  def run("snapshot", args) do
    user = Accounts.get_user!(args["user_id"])
    %{identities: length(Accounts.OIDC.list(user)), recovery: Accounts.recovery_code_count(user)}
  end

  def run("rotate", _args) do
    # A fresh RSA key exercises the relying party's unknown-kid JWKS refresh.
    other = Kith.OIDCFixture.start()
    state = Agent.get(other.agent, & &1)
    current = Agent.get(fixture().agent, & &1)

    Kith.OIDCFixture.update(fixture(), %{
      pem: state.pem,
      jwk: Map.put(state.jwk, "kid", "rotated-#{System.unique_integer([:positive])}"),
      claims: current.claims
    })

    Kith.OIDCFixture.stop(other)
    %{ok: true}
  end

  defp fixture, do: Application.fetch_env!(:kith, :oidc_browser_fixture)
  defp issuer, do: Application.fetch_env!(:kith, :auth).oidc[:issuer]
end

defmodule Kith.OIDCBrowserPlug do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{request_path: "/__fixture__"} = conn, _opts) do
    expected = "Bearer " <> System.fetch_env!("KITH_TEST_FIXTURE_TOKEN")

    if get_req_header(conn, "authorization") == [expected] do
      {:ok, body, conn} = read_body(conn)

      result =
        if conn.method == "GET",
          do: %{run: System.fetch_env!("KITH_TEST_FIXTURE_TOKEN")},
          else: control(Jason.decode!(body))

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(result))
    else
      send_resp(conn, 404, "")
    end
  end

  def call(conn, :app), do: KithWeb.Endpoint.call(conn, [])

  def call(%{request_path: "/authorize"} = conn, :issuer) do
    conn = fetch_query_params(conn)

    if conn.query_params["approved"] == "true" do
      Kith.OIDCFixture.call(conn, {:issuer_agent, fixture().agent})
    else
      fields =
        Enum.map(conn.query_params, fn {key, value} ->
          ["<input type=hidden name=\"", escape(key), "\" value=\"", escape(value), "\">"]
        end)

      html = [
        "<!doctype html><html><head><title>Test identity provider</title></head><body><h1>Test identity provider</h1><form method=get action=/authorize>",
        fields,
        "<input type=hidden name=approved value=true><button>Authorize</button></form></body></html>"
      ]

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    end
  end

  def call(conn, :issuer), do: Kith.OIDCFixture.call(conn, {:issuer_agent, fixture().agent})

  defp control(%{"action" => action, "args" => args}),
    do: Kith.OIDCBrowserControl.run(action, args)

  defp fixture, do: Application.fetch_env!(:kith, :oidc_browser_fixture)
  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
