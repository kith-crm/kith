# Run with: mix run --no-start scripts/security/dependency_audit.exs
# Installation warnings remain visible; only this explicit policy gate applies exceptions.
exceptions = [
  {"EEF-CVE-2026-95105", "Cloak AES-CTR unused; only authenticated AES-GCM readers configured"},
  {"EEF-CVE-2026-94206", "Cloak PBKDF2 fields unused; password hashes use pbkdf2_elixir"},
  {"EEF-CVE-2026-32686",
   "Decimal 2.x retained by parents; BoundedDecimal checks all money fields and importer before parsing"},
  {"EEF-CVE-2026-97853",
   "Decimal.round precision is the fixed literal 2; no untrusted places argument"}
]

owner = "kith-crm maintainers"
review_by = ~D[2026-11-29]

if Date.compare(Date.utc_today(), review_by) == :gt,
  do: Mix.raise("Dependency exceptions expired; owner: #{owner}")

sources = Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("config/*.exs")

Enum.each(sources, fn path ->
  source = File.read!(path)

  if Regex.match?(~r/Cloak\.(?:Ciphers\.AES\.CTR|(?:Ecto|Fields)\.PBKDF2)/, source),
    do: Mix.raise("Cloak exception boundary changed in #{path}")
end)

for {id, boundary} <- exceptions do
  IO.puts("Accepted #{id}; owner=#{owner}; review_by=#{review_by}; #{boundary}")
end

ignored = Enum.map_join(exceptions, ",", &elem(&1, 0))

File.mkdir_p!("tmp/security")

checks = [
  {"hex", "mix", ["hex.audit"], ".",
   [{"HEX_IGNORE_ADVISORIES", ignored}, {"HEX_IGNORE_RETIREMENTS", ""}]},
  {"npm-root", "npm", ["audit", "--audit-level=low"], ".", []},
  {"npm-assets", "npm", ["audit", "--audit-level=low"], "assets", []}
]

results =
  Enum.map(checks, fn {name, executable, arguments, directory, env} ->
    {output, status} =
      System.cmd(executable, arguments, cd: directory, env: env, stderr_to_stdout: true)

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
      owner: owner,
      review_by: review_by,
      accepted_advisories: Enum.map(exceptions, &elem(&1, 0)),
      results: results
    },
    pretty: true
  ) <> "\n"
)

failed = Enum.reject(results, &(&1.status == 0))

if failed != [],
  do: Mix.raise("Dependency audits failed; see tmp/security/dependency-audit.json")
