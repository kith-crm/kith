defmodule Kith.SentryReqClientTest do
  use ExUnit.Case, async: true

  alias Kith.SentryReqClient

  describe "child_spec/0" do
    test "returns a supervised Finch child spec named after the module" do
      spec = SentryReqClient.child_spec()
      assert {Finch, :start_link, [[name: SentryReqClient]]} = spec.start
      assert spec.id == SentryReqClient
    end
  end

  describe "post/3" do
    setup do
      unless Process.whereis(SentryReqClient),
        do: start_supervised!({Finch, name: SentryReqClient})

      :ok
    end

    test "returns {:ok, status, headers, body} on 200" do
      url = start_test_server(200, ~s({"id":"test123"}))
      assert {:ok, 200, _headers, body} = SentryReqClient.post(url, [], "{}")
      assert body == ~s({"id":"test123"})
    end

    test "returns {:ok, 429, ...} on rate limit response" do
      url = start_test_server(429, "")
      assert {:ok, 429, _headers, _body} = SentryReqClient.post(url, [], "{}")
    end

    test "passes headers through to the request" do
      url = start_test_server(200, "ok")
      headers = [{"authorization", "Bearer token123"}, {"content-type", "application/json"}]
      assert {:ok, 200, _headers, _body} = SentryReqClient.post(url, headers, "{}")
    end

    test "returns {:error, reason} for unreachable host" do
      assert {:error, _reason} = SentryReqClient.post("http://127.0.0.1:1/store", [], "{}")
    end
  end

  defp start_test_server(status, body) do
    plug = fn conn, _opts -> Plug.Conn.send_resp(conn, status, body) end
    {:ok, server} = Bandit.start_link(plug: plug, port: 0)
    on_exit(fn -> Process.exit(server, :kill) end)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    "http://localhost:#{port}/store"
  end
end
