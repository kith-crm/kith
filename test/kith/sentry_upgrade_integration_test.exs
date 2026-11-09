defmodule Kith.SentryUpgradeIntegrationTest do
  use ExUnit.Case, async: false

  require Logger

  import ExUnit.CaptureLog

  alias Kith.SentryEventHandler
  alias Sentry.Telemetry.Buffer

  setup do
    Sentry.flush()

    previous =
      Enum.filter(:persistent_term.get(), fn
        {{:sentry_config, _key}, _value} -> true
        _ -> false
      end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> :persistent_term.put(key, value) end)
    end)

    owner = self()

    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:sentry_envelope, body, conn.req_headers, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"id":"#{Sentry.UUID.uuid4_hex()}"}))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    config =
      Application.get_all_env(:sentry)
      |> Keyword.merge(
        dsn: "http://public-key@127.0.0.1:#{port}/1",
        client: Kith.SentryReqClient,
        filter: Kith.SentryFilter,
        before_send: {Kith.SentryScrubber, :before_send},
        before_send_metric: {SentryEventHandler, :before_send_metric},
        telemetry_processor_categories: [:error],
        logs: nil,
        traces_sample_rate: nil,
        traces_sampler: nil,
        dedup_events: false,
        send_client_reports: false,
        sample_rate: 1.0,
        send_result: :none,
        integrations: [oban: [capture_errors: false, cron: [enabled: false]]]
      )
      |> Sentry.Config.validate!()

    Sentry.Config.persist(config)
    :ok
  end

  test "actual envelope scrubs OIDC callback credentials and diagnostic strings" do
    assert {:ok, _} =
             Sentry.capture_exception(
               %RuntimeError{message: "Callback failed code=CODEMARK&state=STATEMARK"},
               request: %{
                 url: "https://kith.test/auth/oidc/callback?code=CODEMARK&state=STATEMARK",
                 query_string: "code=CODEMARK",
                 headers: [{"Cookie", "COOKIESECRET"}]
               },
               extra: %{
                 code_verifier: "VERIFIERMARK",
                 nonce: "NONCEMARK",
                 auth_challenge_binding: "BINDINGMARK"
               }
             )

    assert :ok = Sentry.flush(timeout: 5_000)
    assert_receive {:sentry_envelope, body, _, "/api/1/envelope/"}, 1_000

    for marker <- ~w(CODEMARK STATEMARK COOKIESECRET VERIFIERMARK NONCEMARK BINDINGMARK),
        do: refute(body =~ marker)
  end

  test "actual envelope filters complete provider diagnostics and retains the event" do
    query =
      URI.encode_query(%{
        "error" => "access_denied",
        "error_description" => "Rejected credential CREDENTIALMARK",
        "error_uri" => "https://issuer.test/diagnostics/URICREDENTIALMARK"
      })

    assert {:ok, _} =
             Sentry.capture_exception(%RuntimeError{message: "Provider denied authorization"},
               request: %{
                 url: "https://kith.test/auth/oidc/callback?" <> query,
                 query_string: query
               },
               extra: %{
                 provider: %{
                   error_description: "Rejected credential NESTEDMARK",
                   error_uri: "https://issuer.test/NESTEDURIMARK"
                 },
                 diagnostic:
                   "error_description=Rejected credential SERIALIZEDMARK&error=access_denied"
               }
             )

    assert :ok = Sentry.flush(timeout: 5_000)
    assert_receive {:sentry_envelope, body, _, "/api/1/envelope/"}, 1_000
    assert body =~ "Provider denied authorization"

    for marker <- ~w(CREDENTIALMARK URICREDENTIALMARK NESTEDMARK NESTEDURIMARK SERIALIZEDMARK),
        do: refute(body =~ marker)
  end

  test "actual envelope redacts request, URL, nested context and enriches user identity" do
    Logger.metadata(user_id: 12, account_id: 34)

    assert {:ok, _} =
             Sentry.capture_exception(%RuntimeError{message: "Synthetic transport failure"},
               request: %{
                 url:
                   "https://user:url-secret@example.com/callback?access_token=query-secret&page=2",
                 query_string: "api_key=serialized-secret&name=visible",
                 headers: [
                   {"Authorization", "Bearer header-secret"},
                   {"Content-Type", "application/json"}
                 ],
                 data: %{"rows" => [%{"password" => "body-secret", "name" => "visible"}]}
               },
               extra: %{
                 nested: [
                   %{
                     refresh_token: "extra-secret",
                     immich_api_key: "immich-secret",
                     api_key_encrypted: "import-secret",
                     amount: Decimal.new("12.34")
                   }
                 ]
               }
             )

    assert :ok = Sentry.flush(timeout: 5_000)
    assert_receive {:sentry_envelope, body, headers, "/api/1/envelope/"}, 1_000
    assert {"user-agent", "sentry-elixir/14.0.1"} in headers
    assert {"x-sentry-auth", authentication} = List.keyfind(headers, "x-sentry-auth", 0)
    assert authentication =~ "sentry_key=public-key"
    assert [{%{"type" => "event"}, event}] = Sentry.Test.decode_envelope!(body)
    assert event["user"] == %{"id" => 12, "account_id" => 34}

    assert event["request"]["data"]["rows"] == [
             %{"password" => "[FILTERED]", "name" => "visible"}
           ]

    assert URI.decode_query(event["request"]["query_string"]) == %{
             "api_key" => "[FILTERED]",
             "name" => "visible"
           }

    assert event["extra"]["nested"] == [
             %{
               "refresh_token" => "[FILTERED]",
               "immich_api_key" => "[FILTERED]",
               "api_key_encrypted" => "[FILTERED]",
               "amount" => "12.34"
             }
           ]

    for secret <-
          ~w(url-secret query-secret serialized-secret header-secret body-secret extra-secret) do
      refute body =~ secret
    end

    refute_receive {:sentry_envelope, _, _, _}
  end

  test "terminal Oban failure produces one event while retry attempts produce none" do
    assert Sentry.Config.integrations()[:oban][:capture_errors] == false

    refute Enum.any?(:telemetry.list_handlers([:oban, :job, :exception]), fn handler ->
             handler.id == Sentry.Integrations.Oban.ErrorReporter
           end)

    job = %Oban.Job{
      id: 1,
      worker: "Kith.Workers.MonicaMiscDataWorker",
      queue: "imports",
      attempt: 1,
      max_attempts: 2,
      args: %{"rows" => [%{"credential_api_key" => "queued-secret", "name" => "visible"}]}
    }

    metadata = %{
      job: job,
      reason: %RuntimeError{message: "Synthetic job failure"},
      stacktrace: [],
      kind: :error,
      state: :failure
    }

    capture_log(fn -> :telemetry.execute([:oban, :job, :exception], %{duration: 1}, metadata) end)
    assert :ok = Sentry.flush(timeout: 5_000)
    refute_receive {:sentry_envelope, _, _, _}

    terminal = %{metadata | job: %{job | attempt: 2}}
    capture_log(fn -> :telemetry.execute([:oban, :job, :exception], %{duration: 1}, terminal) end)
    assert :ok = Sentry.flush(timeout: 5_000)
    assert_receive {:sentry_envelope, body, _, _}, 1_000
    assert [{%{"type" => "event"}, event}] = Sentry.Test.decode_envelope!(body)
    assert event["extra"]["attempt"] == 2

    assert event["extra"]["args"]["rows"] == [
             %{"credential_api_key" => "[FILTERED]", "name" => "visible"}
           ]

    refute body =~ "queued-secret"
    refute_receive {:sentry_envelope, _, _, _}
  end

  test "disabled DSN, filters and redaction failures cannot emit an envelope" do
    assert :excluded = Sentry.capture_exception(%Ecto.NoResultsError{})
    Logger.metadata(user_id: 12)
    event = %{Sentry.Event.create_event(message: "Malformed event") | user: "invalid context"}
    assert :excluded = Sentry.send_event(event)
    Sentry.Config.put_config(:dsn, nil)
    assert :ignored = Sentry.capture_exception(%RuntimeError{message: "Disabled capture"})
    assert :ok = Sentry.flush(timeout: 5_000)
    refute_receive {:sentry_envelope, _, _, _}
  end

  test "error-only configuration does not transmit new SDK metrics or ordinary logs" do
    assert Sentry.Config.telemetry_processor_categories() == [:error]
    assert Sentry.Config.logs() == nil
    assert Sentry.Config.traces_sample_rate() == nil
    assert Sentry.Config.traces_sampler() == nil

    assert :ok =
             Sentry.Metrics.count("synthetic.metric", 1, attributes: %{api_key: "metric-secret"})

    capture_log(fn -> Logger.error("Synthetic ordinary log") end)
    assert :ok = Sentry.flush(timeout: 5_000)
    refute_receive {:sentry_envelope, _, _, _}
  end

  test "actual error buffer remains bounded when its scheduler is backpressured" do
    processor = Sentry.TelemetryProcessor.default_name()
    scheduler = Sentry.TelemetryProcessor.get_scheduler(processor)
    buffer = Sentry.TelemetryProcessor.get_buffer(processor, :error)
    capacity = :sys.get_state(buffer).capacity
    assert capacity > 0 and capacity <= 1_000
    assert :sys.get_state(scheduler).capacity <= 1_000
    :sys.suspend(scheduler)

    try do
      for index <- 1..(capacity + 5), do: Sentry.capture_message("Overflow #{index}")
      assert Buffer.size(buffer) == capacity
      events = Buffer.drain(buffer)

      assert Enum.map(events, & &1.message.formatted) ==
               Enum.map(6..(capacity + 5), &"Overflow #{&1}")
    after
      :sys.resume(scheduler)
    end

    assert :ok = Sentry.flush(timeout: 5_000)
    refute_receive {:sentry_envelope, _, _, _}
  end

  test "graceful application shutdown flushes queued error before stopping its HTTP client" do
    assert {:ok, _} = Sentry.capture_message("Synthetic shutdown event")

    try do
      assert :ok = Application.stop(:sentry)
      assert_receive {:sentry_envelope, body, _, _}, 1_000
      assert [{%{"type" => "event"}, event}] = Sentry.Test.decode_envelope!(body)
      assert event["message"]["formatted"] == "Synthetic shutdown event"
      assert is_nil(Process.whereis(Kith.SentryReqClient))
      refute_receive {:sentry_envelope, _, _, _}
    after
      assert :ok = Application.start(:sentry)
    end

    assert is_pid(Process.whereis(Kith.SentryReqClient))
  end
end
