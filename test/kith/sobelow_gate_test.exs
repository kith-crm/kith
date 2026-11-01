defmodule Kith.SobelowGateTest do
  use ExUnit.Case, async: true

  @gate Path.expand("../../scripts/security/sobelow_check.exs", __DIR__)

  setup do
    directory = Path.join(System.tmp_dir!(), "kith-sobelow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "bin"))
    File.mkdir_p!(Path.join(directory, "scripts/security"))
    File.write!(Path.join(directory, "scripts/security/sobelow-exceptions.json"), "[]")

    File.write!(Path.join(directory, "bin/mix"), """
    #!/bin/sh
    test "$*" = 'sobelow --format json --private --no-config' || exit 98
    printf '%s\n' "$SCANNER_OUTPUT"
    exit "$SCANNER_STATUS"
    """)

    File.chmod!(Path.join(directory, "bin/mix"), 0o755)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "successful empty scan passes an empty reviewed baseline", %{directory: directory} do
    {output, status} = scan(directory, 0, ~s({"findings":{}}))
    assert status == 0, output
  end

  test "scanner failures block and preserve the raw diagnostic", %{directory: directory} do
    {output, status} = scan(directory, 17, "scanner deliberately failed")
    assert status != 0
    assert output =~ "Sobelow failed (17)"
    assert File.read!(Path.join(directory, "tmp/security/sobelow.log")) =~ "deliberately failed"
  end

  test "malformed scanner output blocks and remains archived", %{directory: directory} do
    {_output, status} = scan(directory, 0, "not-json")
    assert status != 0
    assert File.read!(Path.join(directory, "tmp/security/sobelow.log")) == "not-json\n"
  end

  test "an unreviewed finding blocks", %{directory: directory} do
    finding = %{"type" => "XSS.Raw", "file" => "lib/unsafe.ex", "line" => 1, "variable" => "body"}
    {output, status} = scan(directory, 0, Jason.encode!(%{findings: %{high: [finding]}}))
    assert status != 0
    assert output =~ "Unreviewed"
  end

  test "changing a reviewed sanitizer guard blocks an otherwise unchanged sink", %{
    directory: directory
  } do
    File.mkdir_p!(Path.join(directory, "lib"))
    File.write!(Path.join(directory, "lib/sink.ex"), "reviewed sink")
    File.write!(Path.join(directory, "lib/guard.ex"), "reviewed sanitizer")

    hash = fn file ->
      :crypto.hash(:sha256, File.read!(Path.join(directory, file))) |> Base.encode16(case: :lower)
    end

    finding = %{"type" => "XSS.Raw", "file" => "lib/sink.ex", "line" => 1, "variable" => "body"}

    exception =
      Map.merge(finding, %{
        "source_sha256" => hash.("lib/sink.ex"),
        "reviewed_sources" => [
          %{"file" => "lib/guard.ex", "source_sha256" => hash.("lib/guard.ex")}
        ],
        "reason" => "Test fixture sanitizer guard",
        "owner" => "test",
        "evidence" => "test fixture",
        "review_by" => Date.add(Date.utc_today(), 30) |> Date.to_iso8601()
      })

    File.write!(
      Path.join(directory, "scripts/security/sobelow-exceptions.json"),
      Jason.encode!([exception])
    )

    response = Jason.encode!(%{findings: %{low: [finding]}})
    {output, status} = scan(directory, 0, response)
    assert status == 0, output
    File.write!(Path.join(directory, "lib/guard.ex"), "unsafe changed sanitizer")
    {output, status} = scan(directory, 0, response)
    assert status != 0
    assert output =~ "Reviewed guard changed"
  end

  defp scan(directory, scanner_status, scanner_output) do
    jason_path = :code.which(Jason) |> List.to_string() |> Path.dirname()

    System.cmd(
      System.find_executable("elixir"),
      ["-pa", jason_path, "-e", "Code.require_file(#{inspect(@gate)})"],
      cd: directory,
      env: [
        {"PATH", Path.join(directory, "bin") <> ":" <> System.get_env("PATH", "")},
        {"SCANNER_STATUS", to_string(scanner_status)},
        {"SCANNER_OUTPUT", scanner_output},
        {"ERL_FLAGS", "+S 2:2"}
      ],
      stderr_to_stdout: true
    )
  end
end
