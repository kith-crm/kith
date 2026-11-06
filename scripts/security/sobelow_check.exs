# Fail closed on every unreviewed finding, changed reviewed source, expired
# exception, scanner error, or malformed output. Never ignore an entire category.
{output, status} =
  try do
    System.cmd("mix", ["sobelow", "--format", "json", "--private", "--no-config"],
      stderr_to_stdout: true
    )
  rescue
    error in ErlangError -> {Exception.message(error), 127}
  end

File.mkdir_p!("tmp/security")
File.write!("tmp/security/sobelow.log", output)
File.write!("tmp/security/sobelow.json", output)
if status != 0, do: raise("Sobelow failed (#{status}); see tmp/security/sobelow.log")
report = Jason.decode!(output)
findings = report |> Map.fetch!("findings") |> Map.values() |> List.flatten()
exceptions = "scripts/security/sobelow-exceptions.json" |> File.read!() |> Jason.decode!()

key = fn finding -> Map.take(finding, ["type", "file", "line", "variable"]) end
today = Date.utc_today()

Enum.each(exceptions, fn exception ->
  for field <- ["reason", "owner", "evidence"] do
    if String.trim(Map.fetch!(exception, field)) == "", do: raise("Empty exception #{field}")
  end

  if Date.compare(Date.from_iso8601!(exception["review_by"]), today) == :lt,
    do: raise("Expired Sobelow exception: #{inspect(key.(exception))}")

  digest = :crypto.hash(:sha256, File.read!(exception["file"])) |> Base.encode16(case: :lower)

  if digest != exception["source_sha256"],
    do: raise("Reviewed source changed; re-review Sobelow exception: #{exception["file"]}")

  Enum.each(Map.get(exception, "reviewed_sources", []), fn source ->
    digest = :crypto.hash(:sha256, File.read!(source["file"])) |> Base.encode16(case: :lower)

    if digest != source["source_sha256"],
      do: raise("Reviewed guard changed; re-review Sobelow exception: #{source["file"]}")
  end)
end)

remaining = Enum.map(findings, key) -- Enum.map(exceptions, key)
stale = Enum.map(exceptions, key) -- Enum.map(findings, key)

if remaining != [] or stale != [] do
  raise(
    "Sobelow policy failed. Unreviewed: #{inspect(remaining, pretty: true)}; stale exceptions: #{inspect(stale, pretty: true)}"
  )
end

IO.puts(
  "Sobelow: #{length(findings)} exact, source-bound exceptions reviewed; no unreviewed findings"
)
