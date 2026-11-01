defmodule Kith.DependencyAuditTest do
  use ExUnit.Case, async: true

  @gate Path.expand("../../scripts/security/dependency_audit.exs", __DIR__)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "kith-audit-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(Path.join(directory, "bin"))
    File.mkdir_p!(Path.join(directory, "assets"))
    on_exit(fn -> File.rm_rf!(directory) end)

    # Exercise the real gate in a fresh VM and isolated working directory. Fake
    # tools control only audit outcomes; the gate still writes its real reports.
    executable!(directory, "mix", """
    #!/bin/sh
    test "$1" = hex.audit || exit 91
    test -z "$HEX_IGNORE_ADVISORIES" || exit 94
    test -z "$HEX_IGNORE_RETIREMENTS" || exit 95
    echo 'hex audit ran with empty ignore variables'
    case ",$AUDIT_FAILURES," in *,hex,*) exit 11;; esac
    """)

    executable!(directory, "npm", """
    #!/bin/sh
    test "$1" = audit && test "$2" = --audit-level=low || exit 96
    case "$PWD" in */assets) name=npm-assets;; *) name=npm-root;; esac
    echo "$name audit ran"
    case ",$AUDIT_FAILURES," in *,$name,*) exit 12;; esac
    """)

    %{directory: directory}
  end

  test "clears inherited Hex suppressions and preserves both npm audits", %{directory: directory} do
    {output, status, report} = run_gate(directory, [])

    assert status == 0, output
    assert Enum.map(report["results"], & &1["name"]) == ["hex", "npm-root", "npm-assets"]
    assert Enum.all?(report["results"], &(&1["status"] == 0))
    assert String.contains?(output, "empty ignore variables")
    refute Map.has_key?(report, "accepted_advisories")
    refute String.contains?(output, "Accepted")
    assert_raw_logs(directory, report)
  end

  for failure <- ["hex", "npm-root", "npm-assets"] do
    test "#{failure} failure blocks while every audit still runs", %{directory: directory} do
      failure = unquote(failure)
      {output, status, report} = run_gate(directory, [failure])

      assert status != 0
      assert String.contains?(output, "Dependency audits failed")
      assert length(report["results"]) == 3

      for result <- report["results"] do
        assert result["status"] != 0 == (result["name"] == failure)
      end

      assert_raw_logs(directory, report)
    end
  end

  test "records simultaneous failures independently", %{directory: directory} do
    {_output, status, report} = run_gate(directory, ["hex", "npm-root", "npm-assets"])
    assert status != 0
    assert Enum.all?(report["results"], &(&1["status"] != 0))
    assert_raw_logs(directory, report)
  end

  test "audit invocation failure blocks and does not prevent other audits", %{
    directory: directory
  } do
    # An unavailable interpreter makes invocation fail even though the tool exists.
    executable!(directory, "mix", "#!/kith-missing-audit-interpreter\n")
    {_output, status, report} = run_gate(directory, [])
    assert status != 0
    [hex, root, assets] = Enum.map(report["results"], & &1["status"])
    assert hex != 0
    assert [root, assets] == [0, 0]
    assert_raw_logs(directory, report)
  end

  defp run_gate(directory, failures) do
    jason_path = :code.which(Jason) |> List.to_string() |> Path.dirname()
    runner = "Mix.start(); Code.eval_file(#{inspect(@gate)})"

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", jason_path, "-e", runner],
        cd: directory,
        env: [
          {"PATH", Path.join(directory, "bin") <> ":" <> System.get_env("PATH", "")},
          {"AUDIT_FAILURES", Enum.join(failures, ",")},
          {"HEX_IGNORE_ADVISORIES", "EEF-CVE-inherited"},
          {"HEX_IGNORE_RETIREMENTS", "inherited-package"}
        ],
        stderr_to_stdout: true
      )

    report =
      directory
      |> Path.join("tmp/security/dependency-audit.json")
      |> File.read!()
      |> Jason.decode!()

    {output, status, report}
  end

  defp executable!(directory, name, contents) do
    path = Path.join([directory, "bin", name])
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp assert_raw_logs(directory, report) do
    for result <- report["results"] do
      assert directory |> Path.join(result["report"]) |> File.regular?()
    end
  end
end
