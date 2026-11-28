Code.require_file("boot.exs", __DIR__)
Code.require_file("control.exs", __DIR__)
fixture = Kith.OIDCFixture.start()
Application.put_env(:kith, :oidc_browser_fixture, fixture)

Kith.OIDCFixture.update(fixture, %{
  issuer: Application.fetch_env!(:kith, :auth).oidc[:issuer],
  redirect_uris: [KithWeb.Endpoint.url() <> "/auth/oidc/callback"]
})

for {kind, variable} <- [app: "PORT", issuer: "ISSUER_PORT"] do
  {:ok, _} =
    Bandit.start_link(
      plug: {Kith.OIDCBrowserPlug, kind},
      scheme: :https,
      ip: {127, 0, 0, 1},
      port: String.to_integer(System.fetch_env!(variable)),
      certfile: Path.join(System.fetch_env!("KITH_OIDC_TLS"), "cert.pem"),
      keyfile: Path.join(System.fetch_env!("KITH_OIDC_TLS"), "key.pem"),
      startup_log: false
    )
end

Process.sleep(:infinity)
