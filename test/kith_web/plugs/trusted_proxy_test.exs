defmodule KithWeb.Plugs.TrustedProxyTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias KithWeb.Plugs.{RateLimiter, TrustedProxy}

  @proxy {172, 30, 44, 2}
  @client {203, 0, 113, 9}

  setup do
    previous = Application.get_env(:kith, :trusted_proxies)
    Application.put_env(:kith, :trusted_proxies, [@proxy])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kith, :trusted_proxies, previous),
        else: Application.delete_env(:kith, :trusted_proxies)
    end)

    :ok
  end

  test "the actual socket peer controls trust even when conn.remote_ip has been changed" do
    conn =
      request(@client)
      |> Map.put(:remote_ip, @proxy)
      |> put_req_header("x-kith-client-ip", "198.51.100.99")
      |> put_req_header("x-forwarded-for", "198.51.100.100")
      |> TrustedProxy.call([])

    assert conn.remote_ip == @client
    assert Logger.metadata()[:client_ip] == "203.0.113.9"
  end

  test "IPv4 and IPv6 canonical identities drive both throttling and request log metadata" do
    for address <- ["203.0.113.10", "2001:db8::10", "::ffff:203.0.113.11"] do
      key_prefix = "proxy-test-#{System.unique_integer([:positive])}"
      opts = RateLimiter.init(limit: 1, period: 60_000, key_prefix: key_prefix)

      conn =
        request(@proxy)
        |> put_req_header("x-kith-client-ip", address)
        |> TrustedProxy.call([])

      identity = conn.remote_ip |> :inet.ntoa() |> to_string()
      assert Logger.metadata()[:client_ip] == identity
      refute RateLimiter.call(conn, opts).halted
      assert RateLimiter.call(conn, opts).status == 429

      key = "rate_limit:#{key_prefix}:#{identity}"
      assert Kith.RateLimiter.ETS.get(key, 60_000) == 2
    end
  end

  test "changing forged headers cannot escape an untrusted peer's budget" do
    opts =
      RateLimiter.init(
        limit: 2,
        period: 60_000,
        key_prefix: "untrusted-proxy-#{System.unique_integer([:positive])}"
      )

    responses =
      for index <- 1..3 do
        request(@client)
        |> put_req_header("x-kith-client-ip", "198.51.100.#{index}")
        |> put_req_header("x-forwarded-for", "192.0.2.#{index}")
        |> TrustedProxy.call([])
        |> RateLimiter.call(opts)
      end

    assert Enum.map(responses, & &1.halted) == [false, false, true]
    assert Enum.all?(responses, &(&1.remote_ip == @client))
    assert Logger.metadata()[:client_ip] == "203.0.113.9"
  end

  test "trusted peers with malformed or duplicate headers retain their socket identity" do
    for headers <- [
          [{"x-kith-client-ip", "not-an-address"}],
          [{"x-kith-client-ip", "203.0.113.9,198.51.100.9"}],
          [{"x-kith-client-ip", "203.0.113.9"}, {"x-kith-client-ip", "198.51.100.9"}]
        ] do
      conn = request(@proxy) |> Map.put(:req_headers, headers) |> TrustedProxy.call([])
      assert conn.remote_ip == @proxy
      assert Logger.metadata()[:client_ip] == "172.30.44.2"
    end
  end

  test "mapped ingress addresses normalize before matching the configured IPv4 proxy" do
    peer = {0, 0, 0, 0, 0, 65_535, 44_062, 11_266}

    conn =
      request(peer)
      |> put_req_header("x-kith-client-ip", "203.0.113.9")
      |> TrustedProxy.call([])

    assert conn.remote_ip == @client
  end

  defp request(peer) do
    conn = Plug.Test.conn(:get, "/api/proxy-test")
    {adapter, payload} = conn.adapter
    peer_data = %{address: peer, port: 1234, ssl_cert: nil}
    %{conn | remote_ip: peer, adapter: {adapter, Map.put(payload, :peer_data, peer_data)}}
  end
end
