if Mix.env() != :test or System.get_env("KITH_OIDC_E2E") != "1",
  do: raise("OIDC browser harness requires MIX_ENV=test KITH_OIDC_E2E=1")

:inet_db.set_lookup([:file, :dns])
:inet_db.add_host({127, 0, 0, 1}, [~c"kith.test", ~c"issuer.test"])

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
Application.put_env(:kith, :require_tos_acceptance, true)
Application.put_env(:kith, :signup_double_optin, false)

Application.put_env(
  :kith,
  KithWeb.Endpoint,
  Application.get_env(:kith, KithWeb.Endpoint, [])
  |> Keyword.merge(
    server: false,
    check_origin: ["https://kith.test:#{System.fetch_env!("PORT")}"],
    url: [scheme: "https", host: "kith.test", port: String.to_integer(System.fetch_env!("PORT"))],
    http: false,
    https: [port: String.to_integer(System.fetch_env!("PORT"))],
    code_reloader: false,
    watchers: []
  )
)

Application.put_env(:kith, :auth, %{
  oidc_enabled: true,
  password_login_enabled: System.get_env("KITH_OIDC_PASSWORD") == "true",
  registration_enabled: System.get_env("KITH_OIDC_REGISTRATION") == "true",
  oidc: [
    issuer: "https://issuer.test:#{System.fetch_env!("ISSUER_PORT")}",
    client_id: "kith",
    client_secret: "fixture-secret",
    display_name: "OpenID Connect",
    cacertfile: Path.join(System.fetch_env!("KITH_OIDC_TLS"), "ca.pem")
  ]
})

Application.put_env(:kith, :disable_signup, System.get_env("KITH_OIDC_REGISTRATION") != "true")
Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:kith)
Ecto.Adapters.SQL.Sandbox.mode(Kith.Repo, :auto)
