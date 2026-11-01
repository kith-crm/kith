defmodule Kith.TrustedProxiesTest do
  use ExUnit.Case, async: true

  alias Kith.TrustedProxies

  @proxy {172, 30, 44, 2}
  @client {203, 0, 113, 9}
  @ipv6 {8193, 3512, 0, 0, 0, 0, 0, 9}

  test "configuration defaults to no trust and accepts only exact host identities" do
    assert TrustedProxies.parse!("") == []
    assert TrustedProxies.parse!("  ") == []

    assert TrustedProxies.parse!("172.30.44.2/32, 2001:db8::9/128,172.30.44.2") ==
             [@proxy, @ipv6]

    assert TrustedProxies.parse!("::ffff:172.30.44.2/128") == [@proxy]
  end

  test "broad ranges, nonliteral addresses, zones and ambiguous configuration fail closed" do
    for value <- [
          "172.16.0.0/12",
          "127.0.0.1/8",
          "2001:db8::/64",
          "172.30.44.2/128",
          "::1/32",
          "proxy.internal",
          "127.1",
          "0172.30.44.2",
          "::1%lo0",
          "[::1]:4000",
          "172.30.44.2,",
          ",172.30.44.2",
          "172.30.44.2//32",
          String.duplicate("1", 4097),
          Enum.map_join(1..33, ",", &"192.0.2.#{&1}")
        ] do
      assert_raise ArgumentError, ~r/TRUSTED_PROXIES/, fn -> TrustedProxies.parse!(value) end
    end
  end

  test "only an allowlisted peer's one canonical header can replace its identity" do
    assert TrustedProxies.resolve(@proxy, [{"x-kith-client-ip", "203.0.113.9"}], [@proxy]) ==
             @client

    assert TrustedProxies.resolve(@proxy, [{"x-kith-client-ip", "2001:db8::9"}], [@proxy]) ==
             @ipv6

    assert TrustedProxies.resolve(@ipv6, [{"x-kith-client-ip", "203.0.113.9"}], [@ipv6]) ==
             @client

    assert TrustedProxies.resolve(@proxy, [{"x-kith-client-ip", "::ffff:203.0.113.9"}], [@proxy]) ==
             @client

    assert TrustedProxies.resolve(@client, [{"x-kith-client-ip", "172.30.44.2"}], [@proxy]) ==
             @client

    assert TrustedProxies.resolve(@proxy, [{"x-kith-client-ip", "203.0.113.9"}], []) == @proxy

    assert TrustedProxies.resolve(@proxy, [{"x-forwarded-for", "203.0.113.9"}], [@proxy]) ==
             @proxy
  end

  test "mapped IPv6 ingress peers have exactly the same trust identity as IPv4" do
    mapped = {0, 0, 0, 0, 0, 65_535, 44_062, 11_266}

    assert TrustedProxies.resolve(mapped, [{"x-kith-client-ip", "203.0.113.9"}], [@proxy]) ==
             @client
  end

  test "malformed, duplicate, chained and overlong canonical headers preserve the peer" do
    for headers <- [
          [],
          [{"x-kith-client-ip", ""}],
          [{"x-kith-client-ip", "203.0.113.9,198.51.100.2"}],
          [{"x-kith-client-ip", "203.0.113.9:4000"}],
          [{"x-kith-client-ip", "[2001:db8::9]:4000"}],
          [{"x-kith-client-ip", "203.0.113.9 "}],
          [{"x-kith-client-ip", "127.1"}],
          [{"x-kith-client-ip", "2001:db8::9%eth0"}],
          [{"x-kith-client-ip", String.duplicate("a", 46)}],
          [{"x-kith-client-ip", <<255>>}],
          [{"x-kith-client-ip", "203.0.113.9"}, {"X-Kith-Client-IP", "198.51.100.2"}]
        ] do
      assert TrustedProxies.resolve(@proxy, headers, [@proxy]) == @proxy
    end
  end
end
