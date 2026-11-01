defmodule Kith.BoundedHTTPTest do
  use ExUnit.Case, async: true

  test "normal JSON decoding survives the streaming response boundary" do
    plug = fn conn -> Req.Test.json(conn, %{"people" => [%{"name" => "Alice"}]}) end

    assert {:ok, %{body: %{"people" => [%{"name" => "Alice"}]}}} =
             Kith.BoundedHTTP.get("http://example.test", plug: plug)
  end

  test "compressed response is never expanded" do
    compressed = :zlib.gzip(String.duplicate("A", 100_000))

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, compressed)
    end

    assert {:ok, %{body: ^compressed}} =
             Kith.BoundedHTTP.get("http://example.test", plug: plug, compressed: true)
  end

  test "oversized response fails instead of decoding or returning partial content" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("A", 20 * 1024 * 1024 + 1))
    end

    assert {:error, %Req.TransportError{reason: :response_too_large}} =
             Kith.BoundedHTTP.get("http://example.test", plug: plug, retry: false)
  end

  test "real Finch chunked transport halts after cumulative response limit" do
    observer = self()

    plug = fn conn, _opts ->
      conn = Plug.Conn.send_chunked(conn, 200)
      chunk = String.duplicate("B", 1024 * 1024)

      Enum.reduce_while(1..22, conn, fn index, conn ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} ->
            send(observer, {:chunk_sent, index})
            {:cont, conn}

          {:error, _} ->
            {:halt, conn}
        end
      end)
    end

    server = start_supervised!({Bandit, plug: plug, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:error, %Req.TransportError{reason: :response_too_large}} =
             Kith.BoundedHTTP.get("http://127.0.0.1:#{port}", retry: false)

    assert_receive {:chunk_sent, 1}
    assert_receive {:chunk_sent, 20}
  end
end
