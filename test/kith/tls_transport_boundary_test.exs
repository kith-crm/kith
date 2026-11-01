defmodule Kith.TLSTransportBoundaryTest do
  use ExUnit.Case, async: true

  # OctoFetch deliberately exposes no CA override. Each probe runs in its own
  # BEAM with an unchanged copy of CAStore's code and a synthetic trust bundle.
  # This never edits the installed dependency's bundle or the parent's VM state.
  for client <- ["assent", "octofetch"] do
    @client client
    @tag timeout: 60_000
    test "#{client} validates certificates and redirect destinations over real TLS" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "kith-tls-#{@client}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      inetrc = Path.join(tmp_dir, "inetrc")

      File.write!(inetrc, """
      {lookup, [file]}.
      {host, {127,0,0,1}, ["localhost", "wrong.example.com", "api.example.com", "a.evil.example.com"]}.
      """)

      arguments =
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
          ["test/fixtures/tls_pr44/transport_probe.ex", @client, Path.expand(tmp_dir)]

      {output, status} =
        System.cmd(System.find_executable("elixir"), arguments,
          env:
            [{"ERL_INETRC", Path.expand(inetrc)}, {"ERL_FLAGS", "+S 2:2"}] ++
              Enum.map(
                ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy),
                &{&1, nil}
              ),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "TLS_TRANSPORT_OK #{@client}: 8 real-handshake cases"
    end
  end
end
