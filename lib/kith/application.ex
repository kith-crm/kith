defmodule Kith.Application do
  @moduledoc false

  use Application
  import Cachex.Spec

  @impl true
  def start(_type, _args) do
    children = base_children() ++ mode_children()
    opts = [strategy: :one_for_one, name: Kith.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp base_children do
    # Install fuse circuit breakers before starting supervised children
    Kith.Geocoding.install_fuse()
    Kith.Weather.install_fuse()
    # Attach Sentry telemetry handler for Oban job failures
    Kith.SentryEventHandler.attach()
    # Capture crashes via Erlang logger handler (Sentry v10+, replaces PlugCapture)
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    [
      Kith.Vault,
      Kith.Repo,
      {Finch, name: Swoosh.Finch, pools: %{:default => [size: 10]}},
      {Oban, Application.fetch_env!(:kith, Oban)},
      {Cachex, name: :kith_cache, expiration: expiration(default: :timer.hours(24))},
      {Task.Supervisor, name: Kith.TaskSupervisor},
      # PubSub lives here (not in mode_children) so worker mode also starts
      # it. Required for cross-container progress broadcasts in the
      # split-deployment topology (app + worker containers).
      {Phoenix.PubSub, name: Kith.PubSub},
      # libcluster: connects this BEAM node to its peer(s) so PubSub spans
      # containers. Topology is configured at runtime via env-driven config
      # in `runtime.exs`; when no peers are set (dev/test), this supervisor
      # starts but does nothing.
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: Kith.ClusterSupervisor]]}
    ]
  end

  defp mode_children do
    case System.get_env("KITH_MODE", "web") do
      "worker" ->
        []

      _web ->
        [
          Kith.PromEx,
          KithWeb.Telemetry,
          KithWeb.Endpoint
        ]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    KithWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
