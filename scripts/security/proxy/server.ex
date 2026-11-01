# Test-only listener around the actual packaged endpoint. The before-send hook
# observes the endpoint's final identity; it never invokes the resolver itself.
{:ok, _} = Application.ensure_all_started(:kith)

if KithWeb.Endpoint.config(:check_origin) == false do
  raise "The proxy browser fixture requires the production origin check to remain enabled"
end

defmodule Kith.SignupIdentityObserver do
  @path "/tmp/kith-signup-observations.jsonl"

  def attach do
    File.write!(@path, "")

    :telemetry.attach_many(
      "proxy-smoke-signup-identity-observer",
      [[:phoenix, :live_view, :mount, :stop], [:phoenix, :live_view, :handle_event, :stop]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(
        [:phoenix, :live_view, :mount, :stop],
        _measurements,
        %{socket: %{view: KithWeb.UserLive.Registration} = socket},
        _configuration
      ) do
    if Phoenix.LiveView.connected?(socket) do
      info = socket.private.connect_info
      peer = info.peer_data.address
      canonical = for {"x-kith-client-ip", value} <- info.x_headers, do: value

      record(%{
        kind: "websocket_signup_mount",
        socket_peer: address(peer),
        canonical_header_values: canonical,
        signup_peer: address(socket.assigns.signup_peer),
        connected: true
      })
    end
  end

  def handle_event(
        [:phoenix, :live_view, :handle_event, :stop],
        _measurements,
        %{
          socket: %{view: KithWeb.UserLive.Registration} = socket,
          event: "save",
          params: %{"user" => %{"email" => email}}
        },
        _configuration
      ) do
    # Observe the assign consumed by the application's real limiter; deriving
    # an identity here would hide a broken socket integration.
    peer = address(socket.assigns.signup_peer)

    record(%{
      kind: "websocket_signup_save",
      signup_peer: peer,
      counter: Kith.RateLimiter.ETS.get("signup:#{peer}", 60_000),
      email: email,
      user_exists: not is_nil(Kith.Accounts.get_user_by_email(email)),
      connected: Phoenix.LiveView.connected?(socket)
    })
  end

  def handle_event(_event, _measurements, _metadata, _configuration), do: :ok

  def record(observation), do: File.write!(@path, Jason.encode!(observation) <> "\n", [:append])

  defp address(nil), do: nil
  defp address(ip), do: ip |> Kith.TrustedProxies.normalize() |> :inet.ntoa() |> to_string()
end

:ok = Kith.SignupIdentityObserver.attach()

defmodule Kith.ProxyIdentityProbe do
  import Plug.Conn
  require Logger

  def init(options), do: options

  def call(conn, _options) do
    conn
    |> register_before_send(fn final ->
      probe_id = get_req_header(final, "x-kith-probe-id") |> List.first()
      Logger.info("proxy_identity:#{probe_id}")
      peer = final |> get_peer_data() |> Map.fetch!(:address) |> Kith.TrustedProxies.normalize()

      if final.method == "POST" and final.request_path == "/users/log-in" do
        client = address(final.remote_ip)

        Kith.SignupIdentityObserver.record(%{
          kind: "http_login_post",
          socket_peer: address(peer),
          client: client,
          status: final.status,
          counter: Kith.RateLimiter.ETS.get("login:#{client}", 60_000)
        })
      end

      final
      |> put_resp_header("x-kith-verified-client", address(final.remote_ip))
      |> put_resp_header("x-kith-socket-peer", address(peer))
    end)
    |> KithWeb.Endpoint.call(KithWeb.Endpoint.init([]))
  end

  defp address(ip), do: ip |> :inet.ntoa() |> to_string()
end

{:ok, _} = Bandit.start_link(plug: Kith.ProxyIdentityProbe, port: 4000, ip: {0, 0, 0, 0})
Process.sleep(:infinity)
