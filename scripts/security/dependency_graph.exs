# Run with: MIX_ENV=test mix run --no-start scripts/security/dependency_graph.exs
# Validate the complete lock, including children of unchanged parents and active
# optional integrations. Keep absent optionals visible without installing them.
lock = Mix.Dep.Lock.read()

nodes =
  for {name, {:hex, package, version, _checksum, tools, dependencies, repository, _outer}} <- lock do
    metadata_path = Path.join(["deps", Atom.to_string(name), "hex_metadata.config"])

    metadata =
      case :file.consult(String.to_charlist(metadata_path)) do
        {:ok, terms} -> Map.new(terms)
        _ -> Mix.raise("Missing or unreadable package metadata: #{metadata_path}")
      end

    unless metadata["name"] == Atom.to_string(package) and metadata["version"] == version,
      do: Mix.raise("Package metadata does not match lock: #{metadata_path}")

    edges =
      Enum.map(dependencies, fn {child, requirement, options} ->
        child_lock = Map.get(lock, child)
        version = if child_lock && elem(child_lock, 0) == :hex, do: elem(child_lock, 2)
        optional = Keyword.get(options, :optional, false)

        %{
          package: child,
          requirement: requirement,
          optional: optional,
          installed: not is_nil(child_lock),
          version: version,
          matches: if(version, do: Version.match?(version, requirement), else: optional)
        }
      end)

    elixir = metadata["elixir"]

    %{
      name: name,
      package: package,
      version: version,
      repository: repository,
      build_tools: tools,
      elixir_requirement: elixir,
      runtime_matches: is_nil(elixir) or Version.match?(System.version(), elixir),
      dependencies: edges
    }
  end

direct =
  Enum.map(Mix.Project.config()[:deps], fn dependency ->
    name = elem(dependency, 0)
    requirement = elem(dependency, 1)
    locked = Map.fetch!(lock, name)

    %{
      name: name,
      requirement: if(is_binary(requirement), do: requirement),
      matches:
        not is_binary(requirement) or
          (elem(locked, 0) == :hex and Version.match?(elem(locked, 2), requirement))
    }
  end)

edges = Enum.flat_map(nodes, & &1.dependencies)
failures = Enum.reject(edges, & &1.matches) ++ Enum.reject(direct, & &1.matches)
runtime_failures = Enum.reject(nodes, & &1.runtime_matches)

report = %{
  generated_at: DateTime.utc_now(),
  lock_sha256: :crypto.hash(:sha256, File.read!("mix.lock")) |> Base.encode16(case: :lower),
  runtime: %{elixir: System.version(), otp: System.otp_release()},
  hex_nodes: length(nodes),
  installed_edges: Enum.count(edges, & &1.installed),
  constraint_failures: failures,
  runtime_failures: runtime_failures,
  direct: direct,
  nodes: Enum.sort_by(nodes, & &1.name)
}

File.mkdir_p!("tmp/security")
File.write!("tmp/security/dependency-graph.json", Jason.encode!(report, pretty: true) <> "\n")
IO.puts("#{length(nodes)} Hex nodes; #{report.installed_edges} installed edges")

if failures != [] or runtime_failures != [],
  do: Mix.raise("Dependency constraint failures; see tmp/security/dependency-graph.json")
