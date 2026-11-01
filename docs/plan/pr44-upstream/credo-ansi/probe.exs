ExUnit.start()
Code.require_file("lib/credo/cli/output/shell.ex")

defmodule CredoANSIProbe do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Credo.CLI.Output.Shell

  test "stdout and stderr match captured Bunt1.0 bytes in colored and plain modes" do
    {rows, _} = Code.eval_file(System.fetch_env!("CREDO_ANSI_EXPECTED"))

    if directory = System.get_env("CREDO_ANSI_REPORT_DIR") do
      File.write!(Path.join(directory, "comparisons.txt"), to_string(length(rows) * 2))
    end

    for {enabled, input, expected} <- rows do
      Application.put_env(:elixir, :ansi_enabled, enabled)
      assert capture_io(fn ->
        {:ok, pid} = Shell.start_link()
        Shell.puts(input)
        GenServer.stop(pid)
      end) == expected

      assert capture_io(:stderr, fn ->
        {:ok, pid} = Shell.start_link()
        Shell.warn(input)
        GenServer.stop(pid)
      end) == expected
    end
  end

  test "explicit no-color and suppressed output remain supported" do
    Application.put_env(:elixir, :ansi_enabled, true)
    assert capture_io(fn ->
      {:ok, pid} = Shell.start_link()
      Shell.use_colors(false)
      Shell.puts([:orange, "plain"])
      Shell.suppress_output(fn -> Shell.puts("hidden") end)
      GenServer.stop(pid)
    end) == "plain\n"
  end
end
