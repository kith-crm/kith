defmodule Kith.Imports.Sources.MonicaApi.HTTPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kith.Imports.Sources.MonicaApi.HTTP

  # This scale exceeds the Unix millisecond clock, keeping admission tests in
  # window zero. Resetting the real ETS bucket advances their budget under test
  # control, independent of scheduler pauses. No request waits for expiry.
  @controlled_scale_ms 1_000_000_000_000_000

  setup do
    keys = [:monica_rate_limit, :monica_rate_limit_scale_ms, :monica_rate_limit_retry_sleep_ms]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:kith, &1)})
    configure(1_000, 60_000)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:kith, key, value)
        {key, :error} -> Application.delete_env(:kith, key)
      end)
    end)

    :ok
  end

  test "charges exactly once at dispatch and preserves ordinary request options" do
    host = unique_host()

    plug = fn conn ->
      assert hits(host) == 1
      assert conn.method == "GET"
      assert conn.query_string == "page=2"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]
      Req.Test.json(conn, %{"data" => [1]})
    end

    assert {:ok, %{status: 200, body: %{"data" => [1]}}} =
             HTTP.get("/contacts",
               base_url: "https://#{host}",
               params: [page: 2],
               auth: {:bearer, "fixture-key"},
               plug: plug,
               retry: false,
               receive_timeout: 1234
             )

    assert hits(host) == 1
  end

  test "every retry, including a transport failure and a 429, acquires exactly one slot" do
    host = unique_host()

    adapter = fn request ->
      case hits(host) do
        1 ->
          {request, %Req.TransportError{reason: :closed}}

        2 ->
          {request, Req.Response.new(status: 429, headers: [{"retry-after", "0"}])}

        3 ->
          {request, Req.Response.new(status: 200, body: "done")}
      end
    end

    # A function adapter exercises existing callers' transport injection too.
    logs =
      capture_log(fn ->
        {result, _deprecation_warning} =
          ExUnit.CaptureIO.with_io(:stderr, fn ->
            HTTP.get("https://#{host}", adapter: adapter, retry_delay: 0)
          end)

        assert {:ok, %{body: "done"}} = result
      end)

    assert logs =~ "socket closed"
    assert logs =~ "status 429"

    assert hits(host) == 3
  end

  test "redirects charge each prepared destination and retain Req credential stripping" do
    origin = unique_host()
    destination = unique_host()

    plug = fn conn ->
      case {conn.host, conn.request_path} do
        {^origin, "/start"} ->
          assert hits(origin) == 1
          assert hits(destination) == 0
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]

          conn
          |> Plug.Conn.put_resp_header("location", "/middle")
          |> Plug.Conn.send_resp(302, "")

        {^origin, "/middle"} ->
          assert hits(origin) == 2
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]

          conn
          |> Plug.Conn.put_resp_header("location", "https://#{destination}/final")
          |> Plug.Conn.send_resp(303, "")

        {^destination, "/final"} ->
          assert hits(origin) == 2
          assert hits(destination) == 1
          assert Plug.Conn.get_req_header(conn, "authorization") == []
          Req.Test.json(conn, %{"redirected" => true})
      end
    end

    assert {:ok, %{body: %{"redirected" => true}}} =
             HTTP.get("https://#{origin}/start", auth: {:bearer, "fixture-key"}, plug: plug)
  end

  test "concurrent callers share the configured budget until the bucket is reset" do
    configure(2, @controlled_scale_ms)
    host = unique_host()
    tasks = start_requests(host, 7)

    for _ <- 1..3 do
      receive_dispatches(2)
      wait_for_denial(host)
      refute_received {:dispatch, _}
      reset_host(host)
    end

    receive_dispatches(1)
    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task) end)
    refute_received {:dispatch, _}
  end

  test "a saturated host does not block a different host" do
    configure(1, @controlled_scale_ms)
    saturated = unique_host()
    independent = unique_host()
    observer = self()

    plug = fn conn ->
      send(observer, {:dispatch, conn.host})
      Req.Test.json(conn, %{})
    end

    assert {:ok, _} = HTTP.get("https://#{saturated}", plug: plug)
    assert_receive {:dispatch, ^saturated}
    blocked = Task.async(fn -> HTTP.get("https://#{saturated}", plug: plug) end)
    wait_for_denial(saturated)

    assert {:ok, _} = HTTP.get("https://#{independent}", plug: plug)
    assert_receive {:dispatch, ^independent}
    refute_received {:dispatch, ^saturated}
    Task.shutdown(blocked, :brutal_kill)
  end

  test "a configured budget above 55 admits exactly 70 requests before blocking" do
    configure(70, @controlled_scale_ms)
    host = unique_host()
    tasks = start_requests(host, 71)

    receive_dispatches(70)
    wait_for_denial(host)
    refute_received {:dispatch, _}

    reset_host(host)
    receive_dispatches(1)
    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task) end)
    refute_received {:dispatch, _}
  end

  test "55 is the fallback when the configured budget is absent" do
    configure(55, @controlled_scale_ms)
    Application.delete_env(:kith, :monica_rate_limit)
    host = unique_host()
    tasks = start_requests(host, 56)

    receive_dispatches(55)
    wait_for_denial(host)
    refute_received {:dispatch, _}

    reset_host(host)
    receive_dispatches(1)
    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task) end)
    refute_received {:dispatch, _}
  end

  test "rate-limit callback surrounds every attempt and cannot skip acquisition" do
    host = unique_host()
    observer = self()

    callback = fn phase, elapsed ->
      send(observer, {phase, elapsed, hits(host)})
      :ignored
    end

    plug = fn conn ->
      assert hits(host) in [1, 2]
      Plug.Conn.send_resp(conn, if(hits(host) == 1, do: 503, else: 200), "")
    end

    logs =
      capture_log(fn ->
        assert {:ok, %{status: 200}} =
                 HTTP.get("https://#{host}",
                   plug: plug,
                   retry_delay: 0,
                   on_rate_limit: callback
                 )
      end)

    assert logs =~ "status 503"

    assert_receive {:before_wait, 0, 0}
    assert_receive {:after_wait, first_wait, 1}
    assert is_integer(first_wait) and first_wait >= 0
    assert_receive {:before_wait, 0, 1}
    assert_receive {:after_wait, second_wait, 2}
    assert is_integer(second_wait) and second_wait >= 0
    refute_received {:before_wait, _, _}
  end

  test "cancellation callbacks can stop dispatch before or after waiting" do
    for phase <- [:before_wait, :after_wait] do
      host = unique_host()
      observer = self()
      callback = fn current, _ -> if current == phase, do: throw(:cancelled) end

      plug = fn conn ->
        send(observer, :unexpected_dispatch)
        Req.Test.json(conn, %{})
      end

      assert catch_throw(HTTP.get("https://#{host}", plug: plug, on_rate_limit: callback)) ==
               :cancelled

      assert hits(host) == if(phase == :before_wait, do: 0, else: 1)
      refute_received :unexpected_dispatch
    end
  end

  test "retains bounded, binary-safe response handling with injected transports" do
    host = unique_host()
    binary = <<0, 255, 254, 1>>

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.send_resp(200, binary)
    end

    assert {:ok, %{body: ^binary}} = HTTP.get("https://#{host}", plug: plug)

    oversized = fn conn ->
      Plug.Conn.send_resp(conn, 200, :binary.copy("X", 20 * 1024 * 1024 + 1))
    end

    assert {:error, %Req.TransportError{reason: :response_too_large}} =
             HTTP.get("https://#{host}", plug: oversized, retry: false)

    assert hits(host) == 2
  end

  test "real Finch transport charges retries and redirects and honors Retry-After" do
    configure(1_000, 60_000)
    reset_host("127.0.0.1")
    reset_host("localhost")
    observer = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    plug = fn conn, _ ->
      case conn.request_path do
        "/start" ->
          attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          send(
            observer,
            {:real_dispatch, conn.host, hits(conn.host), System.monotonic_time(:millisecond)}
          )

          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]

          if attempt == 1 do
            conn
            |> Plug.Conn.put_resp_header("retry-after", "1")
            |> Plug.Conn.send_resp(429, "")
          else
            conn
            |> Plug.Conn.put_resp_header("location", "http://localhost:#{conn.port}/final")
            |> Plug.Conn.send_resp(302, "")
          end

        "/final" ->
          send(
            observer,
            {:real_dispatch, conn.host, hits(conn.host), System.monotonic_time(:millisecond)}
          )

          assert Plug.Conn.get_req_header(conn, "authorization") == []
          Req.Test.json(conn, %{"done" => true})
      end
    end

    server = start_supervised!({Bandit, plug: plug, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    logs =
      capture_log(fn ->
        assert {:ok, %{body: %{"done" => true}}} =
                 HTTP.get("http://127.0.0.1:#{port}/start", auth: {:bearer, "fixture-key"})
      end)

    assert logs =~ "status 429"
    assert logs =~ "retry in 1000ms"

    assert_receive {:real_dispatch, "127.0.0.1", 1, first}
    assert_receive {:real_dispatch, "127.0.0.1", 2, second}
    assert second - first >= 950
    assert_receive {:real_dispatch, "localhost", 1, _}
    assert hits("127.0.0.1") == 2
    assert hits("localhost") == 1
  end

  test "real connection failures acquire a slot on every bounded retry" do
    reset_host("127.0.0.1")
    observer = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        for _ <- 1..3 do
          {:ok, socket} = :gen_tcp.accept(listener, 5000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5000)
          send(observer, {:closed_connection, hits("127.0.0.1")})
          :gen_tcp.close(socket)
        end
      end)

    logs =
      capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :closed}} =
                 HTTP.get("http://127.0.0.1:#{port}", max_retries: 2, retry_delay: 0)
      end)

    assert logs =~ "socket closed"
    assert logs =~ "2 attempts left"
    assert logs =~ "1 attempt left"

    Task.await(server)
    assert_receive {:closed_connection, 1}
    assert_receive {:closed_connection, 2}
    assert_receive {:closed_connection, 3}
    assert hits("127.0.0.1") == 3
  end

  defp configure(limit, scale) do
    Application.put_env(:kith, :monica_rate_limit, limit)
    Application.put_env(:kith, :monica_rate_limit_scale_ms, scale)
    Application.put_env(:kith, :monica_rate_limit_retry_sleep_ms, 5)
  end

  defp unique_host, do: "boundary-#{System.unique_integer([:positive])}.example"

  defp hits(host) do
    :ets.match_object(Kith.RateLimiter.ETS, {{"monica_api:#{host}", :_}, :_, :_})
    |> Enum.map(fn {_, count, _} -> count end)
    |> Enum.sum()
  end

  defp reset_host(host), do: Kith.RateLimiter.reset("monica_api:#{host}", 60_000)

  defp wait_for_denial(host, retries \\ 100)
  defp wait_for_denial(_host, 0), do: flunk("expected a denied acquisition")

  defp wait_for_denial(host, retries) do
    if hits(host) > (Application.get_env(:kith, :monica_rate_limit) || 55) do
      :ok
    else
      Process.sleep(5)
      wait_for_denial(host, retries - 1)
    end
  end

  defp start_requests(host, count) do
    observer = self()

    plug = fn conn ->
      send(observer, {:dispatch, self()})
      Req.Test.json(conn, %{})
    end

    callback = fn
      :before_wait, _ ->
        send(observer, {:ready, self()})

        receive do
          :dispatch_request -> :ok
        after
          5000 -> flunk("request was never released from its start barrier")
        end

      :after_wait, _ ->
        :ok
    end

    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          HTTP.get("https://#{host}", plug: plug, on_rate_limit: callback)
        end)
      end

    Enum.each(tasks, fn %{pid: pid} -> assert_receive {:ready, ^pid}, 1000 end)
    Enum.each(tasks, fn %{pid: pid} -> send(pid, :dispatch_request) end)
    tasks
  end

  defp receive_dispatches(count) do
    for _ <- 1..count do
      assert_receive {:dispatch, _pid}, 1000
    end
  end
end
