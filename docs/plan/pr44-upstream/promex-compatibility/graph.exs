lock = Mix.Dep.Lock.read()

hex_nodes =
  for {name, {:hex, package, version, _, build_tools, dependencies, _, _}} <- lock do
    metadata_path = Path.join(["deps", Atom.to_string(name), "hex_metadata.config"])
    {:ok, terms} = :file.consult(String.to_charlist(metadata_path))
    metadata = Map.new(terms)
    true = metadata["name"] == Atom.to_string(package) and metadata["version"] == version

    edges =
      for {child, requirement, options} <- dependencies do
        child_lock = lock[child]
        child_version = if child_lock, do: elem(child_lock, 2)
        optional = Keyword.get(options, :optional, false)

        %{
          package: child,
          requirement: requirement,
          optional: optional,
          installed: not is_nil(child_lock),
          version: child_version,
          matches:
            if(child_version, do: Version.match?(child_version, requirement), else: optional)
        }
      end

    requirement = metadata["elixir"]

    %{
      name: name,
      version: version,
      build_tools: build_tools,
      elixir_requirement: requirement,
      runtime_matches: is_nil(requirement) or Version.match?(System.version(), requirement),
      dependencies: edges
    }
  end

parent = Enum.find(Mix.Dep.cached(), &(&1.app == :prom_ex))
{:ok, parent_version} = parent.status
parent_requirement = PromEx.MixProject.project()[:elixir]
true = Version.match?(System.version(), parent_requirement)

parent_edges =
  for child <- parent.deps do
    version = lock |> Map.fetch!(child.app) |> elem(2)

    %{
      package: child.app,
      requirement: child.requirement,
      optional: Keyword.get(child.opts, :optional, false),
      installed: true,
      version: version,
      matches: Version.match?(version, child.requirement)
    }
  end

edges = Enum.flat_map(hex_nodes, & &1.dependencies) ++ parent_edges
failures = Enum.reject(edges, & &1.matches)
[] = failures
[] = Enum.reject(hex_nodes, & &1.runtime_matches)

report = %{
  runtime: %{elixir: System.version(), otp: System.otp_release()},
  parent: %{
    name: :prom_ex,
    version: parent_version,
    source: parent.opts[:path],
    elixir_requirement: parent_requirement,
    runtime_matches: Version.match?(System.version(), parent_requirement),
    dependencies: parent_edges
  },
  hex_nodes: length(hex_nodes),
  installed_edges: Enum.count(edges, & &1.installed),
  constraint_failures: failures,
  nodes: Enum.sort_by(hex_nodes, & &1.name),
  core_installed: Map.has_key?(lock, :telemetry_metrics_prometheus_core)
}

File.write!("resolved-graph.json", Jason.encode!(report, pretty: true))

IO.puts(
  "#{report.hex_nodes} Hex nodes; #{report.installed_edges} installed edges including candidate parent; zero mismatches"
)
