# Run with: mix run --no-start scripts/security/dependency_audit.exs
# All advisories and retirements block, including when ignore variables are inherited.
File.mkdir_p!("tmp/security")

checks = [
  {"hex", "mix", ["hex.audit"], ".",
   [{"HEX_IGNORE_ADVISORIES", ""}, {"HEX_IGNORE_RETIREMENTS", ""}]},
  {"npm-root", "npm", ["audit", "--audit-level=low"], ".", []},
  {"npm-assets", "npm", ["audit", "--audit-level=low"], "assets", []}
]

results =
  Enum.map(checks, fn {name, executable, arguments, directory, env} ->
    {output, status} =
      try do
        System.cmd(executable, arguments, cd: directory, env: env, stderr_to_stdout: true)
      rescue
        error in ErlangError ->
          {"Unable to run #{executable}: #{Exception.message(error)}\n", 127}
      end

    report = "tmp/security/#{name}-audit.log"
    File.write!(report, output)
    IO.write(output)
    %{name: name, directory: directory, status: status, report: report}
  end)

File.write!(
  "tmp/security/dependency-audit.json",
  Jason.encode!(
    %{
      generated_at: DateTime.utc_now(),
      results: results
    },
    pretty: true
  ) <> "\n"
)

failed = Enum.reject(results, &(&1.status == 0))

if failed != [],
  do: Mix.raise("Dependency audits failed; see tmp/security/dependency-audit.json")
