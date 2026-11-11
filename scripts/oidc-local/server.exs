if Mix.env() != :test or System.get_env("KITH_OIDC_E2E") != "1",
  do: raise("real provider harness requires isolated test mode")

state = Path.expand(".oidc-local")
app_port = String.to_integer(System.get_env("KITH_OIDC_APP_PORT", "8444"))
fixture_port = String.to_integer(System.get_env("KITH_OIDC_FIXTURE_PORT", "8445"))
run = state |> Path.join("run.json") |> File.read!() |> Jason.decode!()
database = "kith_local_" <> run["run_id"] <> System.get_env("KITH_OIDC_DATABASE_SUFFIX", "")
if byte_size(database) > 63, do: raise("test database name exceeds PostgreSQL identifier limit")
:inet_db.set_lookup([:file, :dns])
:inet_db.add_host({127, 0, 0, 1}, [~c"kith.test", ~c"fixture.test", ~c"authentik.test"])

Application.put_env(
  :kith,
  Kith.Repo,
  Keyword.merge(Application.get_env(:kith, Kith.Repo),
    username: "authentik",
    password: System.fetch_env!("POSTGRES_PASSWORD"),
    port: 15449,
    database: database,
    pool_size: String.to_integer(System.get_env("KITH_OIDC_POOL_SIZE", "4")),
    ownership_timeout:
      String.to_integer(System.get_env("KITH_OIDC_OWNERSHIP_TIMEOUT_MS", "120000"))
  )
)

Application.put_env(
  :kith,
  Oban,
  Keyword.merge(Application.get_env(:kith, Oban, []),
    testing: :manual,
    plugins: false,
    queues: false
  )
)

Application.put_env(:kith, Kith.PromEx, disabled: true)

Application.put_env(
  :kith,
  KithWeb.Endpoint,
  Keyword.merge(Application.get_env(:kith, KithWeb.Endpoint),
    server: false,
    http: false,
    code_reloader: false,
    watchers: [],
    url: [scheme: "https", host: "kith.test", port: app_port],
    check_origin: ["https://kith.test:#{app_port}"]
  )
)

Application.put_env(:kith, :auth, %{
  oidc_enabled: true,
  password_login_enabled: System.get_env("KITH_OIDC_PASSWORD", "true") == "true",
  registration_enabled: true,
  oidc: [
    issuer: run["issuer"],
    client_id: run["client_id"],
    client_secret: run["client_secret"],
    display_name: "Authentik",
    cacertfile: Path.join(state, "ca.pem")
  ]
})

Application.put_env(:kith, :require_tos_acceptance, true)
System.put_env("KITH_TEST_FIXTURE_TOKEN", run["control_token"])
Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

:ok =
  case Ecto.Adapters.Postgres.storage_up(Application.fetch_env!(:kith, Kith.Repo)) do
    :ok -> :ok
    {:error, :already_up} -> :ok
  end

{:ok, _, _} =
  Ecto.Migrator.with_repo(Kith.Repo, fn repo ->
    Ecto.Migrator.run(repo, "priv/repo/migrations", :up, all: true)
  end)

{:ok, _} = Application.ensure_all_started(:kith)
Ecto.Adapters.SQL.Sandbox.mode(Kith.Repo, :auto)
Code.require_file("../../test/playwright/fixtures/oidc/control.exs", __DIR__)

defmodule Kith.RealProviderPlug do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{request_path: "/__fixture__"} = conn, kind) do
    if kind == :app and conn.method == "POST" do
      {:ok, body, conn} = read_body(conn)
      args = Jason.decode!(body)

      if args["action"] in [
           "prepare",
           "stale",
           "expire",
           "revoke_sessions",
           "snapshot",
           "environment"
         ] and
           get_req_header(conn, "authorization") == [
             "Bearer " <> System.fetch_env!("KITH_TEST_FIXTURE_TOKEN")
           ] do
        send_resp(
          conn,
          200,
          Jason.encode!(
            if args["action"] == "environment" do
              %{
                password: Application.fetch_env!(:kith, :auth).password_login_enabled,
                database_suffix: System.get_env("KITH_OIDC_DATABASE_SUFFIX", "")
              }
            else
              Kith.OIDCBrowserControl.run(args["action"], args["args"])
            end
          )
        )
      else
        send_resp(conn, 404, "")
      end
    else
      Kith.OIDCBrowserPlug.call(conn, :app)
    end
  end

  def call(conn, :app), do: KithWeb.Endpoint.call(conn, [])
  def call(conn, :fixture), do: send_resp(conn, 404, "")
end

for {host, port, kind} <- [
      {"kith.test", app_port, :app},
      {"fixture.test", fixture_port, :fixture}
    ] do
  {:ok, _} =
    Bandit.start_link(
      plug: {Kith.RealProviderPlug, kind},
      scheme: :https,
      ip: {0, 0, 0, 0},
      port: port,
      certfile: Path.join(state, host <> ".pem"),
      keyfile: Path.join(state, host <> "-key.pem"),
      startup_log: false
    )
end

case Kith.Auth.OIDC.Metadata.get(Application.fetch_env!(:kith, :auth).oidc) do
  {:ok, _metadata} ->
    File.write!(
      Path.join(state, "runtime-tls-check.txt"),
      "PASS runtime verified provider TLS and discovery\n"
    )

  {:error, reason} ->
    raise "Real provider discovery failed: #{inspect(reason)}"
end

Process.sleep(:infinity)
