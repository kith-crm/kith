defmodule Mix.Tasks.Ci.AuditTest do
  use ExUnit.Case, async: true

  @gate Path.expand("../../lib/mix/tasks/ci.audit.ex", __DIR__)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "kith-audit-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(Path.join(directory, "bin"))
    File.mkdir_p!(Path.join(directory, "assets"))
    on_exit(fn -> File.rm_rf!(directory) end)

    # Exercise the real task with controlled external command outcomes.
    executable!(directory, "mix", """
    #!/bin/sh
    case "$*" in
      hex.audit)
        test -z "$HEX_IGNORE_ADVISORIES" || exit 94
        test -z "$HEX_IGNORE_RETIREMENTS" || exit 95
        name=hex
        ;;
      'run --no-start scripts/security/sobelow_check.exs') name=sobelow ;;
      *) exit 91 ;;
    esac
    echo "$name ran"
    case ",$AUDIT_FAILURES," in *,"$name",*) exit 11;; esac
    """)

    executable!(directory, "npm", """
    #!/bin/sh
    case "$*" in
      'audit --audit-level=low') name=npm-root ;;
      'audit --audit-level=low --prefix assets') name=npm-assets ;;
      *) exit 96 ;;
    esac
    echo "$name ran"
    case ",$AUDIT_FAILURES," in *,"$name",*) exit 12;; esac
    """)

    %{directory: directory}
  end

  test "clears inherited Hex suppressions and runs all four checks", %{directory: directory} do
    {output, status} = run_gate(directory, [])
    assert status == 0, output
    assert_all_checks_ran(output)
    refute File.exists?(Path.join(directory, "tmp/security/dependency-audit.json"))
  end

  for failure <- ["hex", "npm-root", "npm-assets", "sobelow"] do
    test "#{failure} failure blocks while every check still runs", %{directory: directory} do
      {output, status} = run_gate(directory, [unquote(failure)])
      assert status != 0
      assert output =~ "Security checks failed"
      assert_all_checks_ran(output)
    end
  end

  test "reports simultaneous failures", %{directory: directory} do
    {output, status} = run_gate(directory, ["hex", "npm-root", "npm-assets", "sobelow"])
    assert status != 0
    assert output =~ "Security checks failed: Hex, npm root, npm assets, Sobelow"
    assert_all_checks_ran(output)
  end

  test "invocation failure blocks without preventing the other executable", %{
    directory: directory
  } do
    executable!(directory, "mix", "#!/kith-missing-audit-interpreter\n")
    {output, status} = run_gate(directory, [])
    assert status != 0
    assert output =~ "Hex failed (exit"
    assert output =~ "Sobelow failed (exit"
    assert output =~ "npm-root ran"
    assert output =~ "npm-assets ran"
  end

  defp run_gate(directory, failures) do
    runner = "Mix.start(); Code.require_file(#{inspect(@gate)}); Mix.Tasks.Ci.Audit.run([])"

    System.cmd(System.find_executable("elixir"), ["-e", runner],
      cd: directory,
      env: [
        {"PATH", Path.join(directory, "bin") <> ":" <> System.get_env("PATH", "")},
        {"AUDIT_FAILURES", Enum.join(failures, ",")},
        {"HEX_IGNORE_ADVISORIES", "EEF-CVE-inherited"},
        {"HEX_IGNORE_RETIREMENTS", "inherited-package"},
        {"ERL_FLAGS", "+S 2:2"}
      ],
      stderr_to_stdout: true
    )
  end

  defp assert_all_checks_ran(output) do
    for name <- ["hex", "npm-root", "npm-assets", "sobelow"] do
      assert output =~ "#{name} ran"
    end
  end

  defp executable!(directory, name, contents) do
    path = Path.join([directory, "bin", name])
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
