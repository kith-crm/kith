# Local regression harness only: jobs run when the test explicitly drains them.
if System.get_env("PR44_E2E") != "1", do: raise("Set PR44_E2E=1 for this local test harness")

Application.put_env(
  :kith,
  Oban,
  Application.get_env(:kith, Oban, [])
  |> Keyword.merge(testing: :manual, plugins: false, queues: false)
)

Application.put_env(:kith, :signup_double_optin, false)
Application.put_env(:kith, :monica_rate_limit, 100_000)
Application.put_env(:kith, Kith.PromEx, disabled: true)

Application.put_env(
  :kith,
  KithWeb.Endpoint,
  Application.get_env(:kith, KithWeb.Endpoint, [])
  |> Keyword.merge(
    server: System.get_env("PR44_SERVER") == "1",
    check_origin: false,
    code_reloader: false,
    watchers: [],
    live_reload: [],
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))]
  )
)

Application.put_env(:kith, Kith.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: System.get_env("SMTP_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("SMTP_PORT", "1025")),
  ssl: false,
  tls: :never,
  auth: :never,
  from: "noreply@pr44.local"
)

Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:kith)
if Mix.env() == :test, do: Ecto.Adapters.SQL.Sandbox.mode(Kith.Repo, :auto)
