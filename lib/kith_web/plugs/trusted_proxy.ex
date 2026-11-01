defmodule KithWeb.Plugs.TrustedProxy do
  @moduledoc "Validates the ingress socket peer before accepting its canonical client address."
  @behaviour Plug

  alias Kith.TrustedProxies

  require Logger

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    peer = conn |> Plug.Conn.get_peer_data() |> Map.fetch!(:address) |> TrustedProxies.normalize()
    address = TrustedProxies.resolve(peer, conn.req_headers)
    conn = %{conn | remote_ip: peer}

    conn =
      if address == peer do
        conn
      else
        Plug.RewriteOn.call(conn, remote_ip: "x-kith-client-ip")
      end

    # RewriteOn parses the original header; normalize mapped IPv6 for the same
    # key/log identity used by the socket resolver.
    conn = %{conn | remote_ip: address}
    Logger.metadata(client_ip: format_address(address))
    conn
  end

  defp format_address(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_address(_address), do: "unknown"
end
