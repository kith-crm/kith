defmodule Mix.Tasks.Ci.Audit do
  @moduledoc """
  Runs Hex, both npm audits and the reviewed Sobelow check from the project root.
  Install Mix and both npm dependency graphs first. All checks run; any failure
  fails the task. Diagnostics are printed directly to the terminal.
  """

  use Mix.Task

  @shortdoc "Run Hex, npm and reviewed Sobelow security checks"

  @impl Mix.Task
  def run([]) do
    checks = [
      {"Hex", "mix", ["hex.audit"],
       [env: [{"HEX_IGNORE_ADVISORIES", ""}, {"HEX_IGNORE_RETIREMENTS", ""}]]},
      {"npm root", "npm", ["audit", "--audit-level=low"], []},
      {"npm assets", "npm", ["audit", "--audit-level=low", "--prefix", "assets"], []},
      {"Sobelow", "mix", ["run", "--no-start", "scripts/security/sobelow_check.exs"], []}
    ]

    failed =
      for {name, executable, arguments, options} <- checks,
          not passed?(name, executable, arguments, options),
          do: name

    if failed != [], do: Mix.raise("Security checks failed: #{Enum.join(failed, ", ")}")
  end

  defp passed?(name, executable, arguments, options) do
    Mix.shell().info("\n==> #{name}")

    {_, status} =
      System.cmd(executable, arguments, options ++ [stderr_to_stdout: true, into: IO.stream()])

    if status != 0, do: Mix.shell().error("#{name} failed (exit #{status})")
    status == 0
  rescue
    error in ErlangError ->
      Mix.shell().error("Unable to run #{executable}: #{Exception.message(error)}")
      false
  end
end
