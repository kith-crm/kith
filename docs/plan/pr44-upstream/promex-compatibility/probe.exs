ExUnit.start()

Application.put_env(:prom_ex, :storage_adapter, PromEx.Storage.Peep)

defmodule PromExUpstreamProbe.Controller do
  use Phoenix.Controller, formats: [:html]
  def index(conn, _), do: Plug.Conn.send_resp(conn, 200, "ok")
end

defmodule PromExUpstreamProbe.Router do
  use Phoenix.Router
  get("/fixture", PromExUpstreamProbe.Controller, :index)
end

defmodule PromExUpstreamProbe.Repo do
end

defmodule PromExUpstreamProbe.Dashboards do
  def __grafana_dashboard_uid__(_app, path, _title), do: "probe-" <> Path.rootname(path)
end

defmodule PromExUpstreamProbe.Test do
  use ExUnit.Case, async: false
  alias PromEx.MetricTypes.{Manual, Polling}

  setup_all do
    plugin_opts = [otp_app: :promex_upstream_probe]

    plugins = [
      {PromEx.Plugins.Application, [deps: [:phoenix, :ecto, :oban]]},
      {PromEx.Plugins.Beam, []},
      {PromEx.Plugins.Phoenix, [router: PromExUpstreamProbe.Router]},
      {PromEx.Plugins.Ecto, [repos: [PromExUpstreamProbe.Repo]]},
      {PromEx.Plugins.Oban, []}
    ]

    groups =
      Enum.map(plugins, fn {plugin, opts} ->
        category =
          plugin |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

        opts =
          plugin_opts
          |> Keyword.merge(opts)
          |> Keyword.put(:metric_prefix, [:kith, :prom_ex, category])

        groups =
          for kind <- [:event_metrics, :polling_metrics, :manual_metrics],
              group <- List.wrap(apply(plugin, kind, [opts])),
              do: group

        {category, groups}
      end)

    metrics =
      for {_category, groups} <- groups, group <- groups, metric <- group.metrics, do: metric

    {:ok, reporter} =
      PromEx.Storage.Peep.child_spec(PromExUpstreamProbe.Metrics, metrics).start
      |> then(fn {m, f, a} -> apply(m, f, a) end)

    Process.unlink(reporter)
    on_exit(fn -> if Process.alive?(reporter), do: GenServer.stop(reporter) end)
    %{groups: groups, metrics: metrics}
  end

  test "no-Core closure selects Peep; explicit adapters still win" do
    Application.delete_env(:prom_ex, :storage_adapter)

    expected =
      if Code.ensure_loaded?(TelemetryMetricsPrometheus.Core),
        do: PromEx.Storage.Core,
        else: PromEx.Storage.Peep

    assert PromEx.storage_adapter() == expected

    if expected == PromEx.Storage.Core do
      metric =
        Telemetry.Metrics.counter([:upstream, :core, :count], event_name: [:upstream, :core])

      {module, function, arguments} =
        PromEx.Storage.Core.child_spec(PromExUpstreamProbe.CoreMetrics, [metric]).start

      {:ok, pid} = apply(module, function, arguments)
      :telemetry.execute([:upstream, :core], %{}, %{})

      assert IO.iodata_to_binary(PromEx.Storage.Core.scrape(PromExUpstreamProbe.CoreMetrics)) =~
               "upstream_core_count 1"

      GenServer.stop(pid)
    end

    assert Code.ensure_loaded?(PromEx.Storage.Core) ==
             Code.ensure_loaded?(TelemetryMetricsPrometheus.Core)

    Application.put_env(:prom_ex, :storage_adapter, PromEx.Storage.Peep)
    assert PromEx.storage_adapter() == PromEx.Storage.Peep

    if System.get_env("PROMEX_PROBE_ORIGINAL") == "1" do
      assert_raise Protocol.UndefinedError, fn ->
        PromEx.Storage.Peep.scrape(:not_a_running_reporter)
      end
    else
      assert PromEx.Storage.Peep.scrape(:not_a_running_reporter) == :prom_ex_down
    end
  end

  test "all five plugin metric names, labels, types, units and histogram bounds remain defined",
       %{groups: groups, metrics: metrics} do
    assert Enum.map(groups, &elem(&1, 0)) == [:application, :beam, :phoenix, :ecto, :oban]
    for {_plugin, groups} <- groups, do: assert(groups != [])

    contract =
      Enum.map(metrics, fn metric ->
        %{
          name: metric.name,
          type: metric.__struct__,
          tags: metric.tags,
          event_name: metric.event_name,
          unit: metric.unit,
          buckets: Keyword.get(metric.reporter_options, :buckets),
          description: metric.description
        }
      end)
      |> Enum.sort_by(& &1.name)

    File.write!("plugin-contract.json", Jason.encode!(contract, pretty: true))

    for %Telemetry.Metrics.Distribution{} = metric <- metrics do
      calculator = Keyword.fetch!(metric.reporter_options, :peep_bucket_calculator)
      expected = metric.reporter_options[:buckets] |> Enum.uniq() |> Enum.sort()
      configuration = calculator.config(metric)
      assert calculator.number_of_buckets(configuration) == length(expected)

      for {bound, index} <- Enum.with_index(expected),
          do: assert(calculator.upper_bound(index, configuration) == to_string(bound * 1.0))
    end
  end

  test "actual Peep exporter receives representative telemetry from all five plugins", %{
    groups: groups
  } do
    for {category, groups} <- groups,
        category in [:application, :beam],
        %kind{measurements_mfa: {module, function, arguments}} <- groups,
        kind in [Manual, Polling] do
      apply(module, function, arguments)
    end

    conn = Plug.Test.conn(:get, "/fixture") |> Plug.Conn.send_resp(200, "ok")
    native = System.convert_time_unit(25, :millisecond, :native)
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: native}, %{conn: conn})

    :telemetry.execute(
      [:prom_ex_upstream_probe, :repo, :query],
      %{
        idle_time: native,
        queue_time: native,
        query_time: native,
        decode_time: native,
        total_time: native
      },
      %{repo: PromExUpstreamProbe.Repo, source: "contacts", result: {:ok, %{}}}
    )

    :telemetry.execute([:oban, :job, :stop], %{duration: native, queue_time: native}, %{
      conf: %{name: Oban},
      job: %{queue: "imports"},
      worker: "Kith.Workers.MonicaDocumentImportWorker",
      state: :success,
      attempt: 1
    })

    scrape = PromEx.Storage.Peep.scrape(PromExUpstreamProbe.Metrics) |> IO.iodata_to_binary()

    for family <- ["application", "beam", "phoenix", "ecto", "oban"],
        do: assert(scrape =~ "kith_prom_ex_#{family}")

    assert scrape =~ "# TYPE kith_prom_ex_phoenix_http_request_duration_milliseconds histogram"
    assert scrape =~ "kith_prom_ex_phoenix_http_request_duration_milliseconds_bucket{"
    assert scrape =~ "path=\"/fixture\""
    assert scrape =~ "worker=\"Kith.Workers.MonicaDocumentImportWorker\""
    assert scrape =~ "repo=\"PromExUpstreamProbe.Repo\""
    File.write!("scrape.prom", scrape)
  end

  test "all five bundled dashboards render valid JSON with stable Kith metric prefixes" do
    for family <- ["application", "beam", "phoenix", "ecto", "oban"] do
      dashboard =
        PromEx.DashboardRenderer.build(:prom_ex, family <> ".json", :kith)
        |> PromEx.DashboardRenderer.merge_assigns(
          datasource_id: "prometheus",
          title: "Kith " <> family,
          otp_app: :kith
        )
        |> PromEx.DashboardRenderer.render_dashboard(PromExUpstreamProbe.Dashboards)
        |> PromEx.DashboardRenderer.decode_dashboard()

      assert dashboard.valid_file?
      assert dashboard.valid_json?
      assert is_map(dashboard.decoded_dashboard)
      File.mkdir_p!("dashboards")
      File.write!("dashboards/" <> family <> ".json", dashboard.rendered_file)
    end
  end
end
