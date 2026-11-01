lock = Mix.Dep.Lock.read()

nodes =
  for {name, {:hex, _, version, _, _, children, _, _}} <- lock do
    %{name: name, version: version, children: children}
  end

versions = Map.new(nodes, &{&1.name, &1.version})

edges =
  for parent <- nodes, {child, requirement, options} <- parent.children do
    version = versions[child]

    %{
      parent: parent.name,
      child: child,
      requirement: requirement,
      version: version,
      installed: not is_nil(version),
      matches:
        if(version,
          do: Version.match?(version, requirement),
          else: Keyword.get(options, :optional, false)
        )
    }
  end

parent = Enum.find(Mix.Dep.cached(), &(&1.app == :ex_cldr_calendars))

# Read the actual changed parent's active requirements, which are not
# represented by a lock entry because this candidate uses a local path source.
parent_edges =
  for dependency <- parent.deps do
    child = dependency.app
    requirement = dependency.requirement

    %{
      parent: :ex_cldr_calendars,
      child: child,
      requirement: requirement,
      version: versions[child],
      installed: true,
      matches: Version.match?(Map.fetch!(versions, child), requirement)
    }
  end

direct =
  for {name, requirement} <- Mix.Project.config()[:deps], is_binary(requirement) do
    %{
      name: name,
      requirement: requirement,
      matches: Version.match?(Map.fetch!(versions, name), requirement)
    }
  end

failures = Enum.reject(edges ++ parent_edges, & &1.matches) ++ Enum.reject(direct, & &1.matches)

report = %{
  runtime: %{
    elixir: System.version(),
    otp: System.otp_release(),
    erts: to_string(:erlang.system_info(:version)),
    native_json_available: Code.ensure_loaded?(:json)
  },
  hex_nodes: length(nodes),
  installed_hex_edges: Enum.count(edges, & &1.installed),
  patched_parent_active_edges: parent_edges,
  parent_manifest_sha256:
    parent.opts[:dest]
    |> Path.join("mix.exs")
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower),
  direct: direct,
  edges: edges,
  failures: failures,
  versions: versions,
  scope: "Narrow path-parent fixture; not the complete Kith dependency graph"
}

File.write!("dependency-graph.json", Jason.encode!(report, pretty: true) <> "\n")
IO.puts("#{length(nodes)} Hex packages; #{report.installed_hex_edges} installed Hex edges")
if failures != [], do: Mix.raise("Installed dependency constraint mismatch")
