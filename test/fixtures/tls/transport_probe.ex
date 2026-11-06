# Invoked in an isolated BEAM by TLSTransportBoundaryTest. This fixture owns its
# DNS map, CA bundle, local listening sockets and temporary download directory.
defmodule KithTLSProbe.Downloader do
  @behaviour OctoFetch.Downloader
  @impl true
  def default_version, do: "1"
  @impl true
  def base_url(url, _version), do: url
  @impl true
  def download_name(_version, _os, _arch), do: "artifact.bin"
  @impl true
  def pre_download_hook(_name, _output), do: :cont
  @impl true
  def post_write_hook(_file), do: :ok
  @impl true
  def download(output, opts \\ []), do: OctoFetch.download(__MODULE__, output, opts)
end

defmodule KithTLSProbe do
  import ExUnit.Assertions

  @body "synthetic dependency transport artifact"

  def run(client, directory) do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "/CN=Kith synthetic test CA", template: :root_ca)
    ca_der = X509.Certificate.to_der(ca)
    isolate_castore(directory, ca)

    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:assent)
    {:ok, _} = Application.ensure_all_started(:octo_fetch)

    request = &request(client, &1, ca_der, directory)

    cases = [
      {"trusted exact DNS", ["localhost"], "localhost", :trusted, :ok},
      {"trusted wildcard DNS", ["*.example.com"], "api.example.com", :trusted, :ok},
      {"trusted wrong DNS", ["localhost"], "wrong.example.com", :trusted, :hostname},
      {"partial wildcard cross-label", ["a*.example.com"], "a.evil.example.com", :trusted,
       :hostname},
      {"DNS wildcard cannot match IP", ["*.0.0.1"], "127.0.0.1", :trusted, :hostname},
      {"untrusted CA", ["localhost"], "localhost", :untrusted, :ca}
    ]

    for {label, names, host, trust, expected} <- cases do
      key = X509.PrivateKey.new_ec(:secp256r1)

      certificate =
        if trust == :trusted do
          X509.Certificate.new(X509.PublicKey.derive(key), "/CN=unused.example.net", ca, ca_key,
            extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(names)]
          )
        else
          other_ca_key = X509.PrivateKey.new_ec(:secp256r1)

          other_ca =
            X509.Certificate.self_signed(other_ca_key, "/CN=Untrusted test CA",
              template: :root_ca
            )

          X509.Certificate.new(
            X509.PublicKey.derive(key),
            "/CN=unused.example.net",
            other_ca,
            other_ca_key,
            extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(names)]
          )
        end

      with_server(directory, certificate, key, host, response(), fn url ->
        assert_outcome(request.(url), expected, label)
      end)
    end

    key = X509.PrivateKey.new_ec(:secp256r1)

    certificate =
      X509.Certificate.new(X509.PublicKey.derive(key), "/CN=localhost", ca, ca_key,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])]
      )

    for {destination_host, expected} <- [{"localhost", :ok}, {"wrong.example.com", :hostname}] do
      with_server(directory, certificate, key, destination_host, response(), fn destination ->
        redirect =
          "HTTP/1.1 302 Found\r\nLocation: #{destination}/artifact.bin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

        with_server(directory, certificate, key, "localhost", redirect, fn source ->
          assert_outcome(request.(source), expected, "redirect to #{destination_host}")
        end)
      end)
    end

    IO.puts("TLS_TRANSPORT_OK #{client}: 8 real-handshake cases")
  end

  defp isolate_castore(directory, ca) do
    original = :code.lib_dir(:castore) |> List.to_string()
    isolated = Path.join(directory, "castore-test")
    File.mkdir_p!(isolated)
    File.cp_r!(Path.join(original, "ebin"), Path.join(isolated, "ebin"))
    File.mkdir_p!(Path.join(isolated, "priv"))
    File.write!(Path.join(isolated, "priv/cacerts.pem"), X509.Certificate.to_pem(ca))
    assert true == :code.replace_path(:castore, String.to_charlist(Path.join(isolated, "ebin")))
    assert CAStore.file_path() == Path.join(isolated, "priv/cacerts.pem")
  end

  defp request("assent", base_url, ca_der, _directory) do
    Assent.HTTPAdapter.request(:get, base_url <> "/artifact.bin", nil, [],
      http_adapter:
        {Assent.HTTPAdapter.Req,
         [
           retry: false,
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000, transport_opts: [cacerts: [ca_der]]]
         ]}
    )
    |> case do
      {:ok, %{status: 200, body: @body}} -> :ok
      {:error, error} -> {:error, inspect(error, limit: :infinity)}
      unexpected -> flunk("Unexpected Assent result: #{inspect(unexpected)}")
    end
  end

  defp request("octofetch", base_url, _ca_der, directory) do
    output = Path.join(directory, "download-#{System.unique_integer([:positive])}")
    File.mkdir_p!(output)
    checksum = :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower)

    result =
      OctoFetch.download(KithTLSProbe.Downloader, output,
        github_repo: base_url,
        download_versions: %{"1" => [{:linux, :amd64, checksum}]},
        override_operating_system: :linux,
        override_architecture: :amd64
      )

    case result do
      {:ok, [file], []} ->
        assert File.read!(file) == @body
        :ok

      {:error, error} ->
        assert File.ls!(output) == []
        {:error, error}

      unexpected ->
        flunk("Unexpected OctoFetch result: #{inspect(unexpected)}")
    end
  end

  defp assert_outcome(result, :ok, label), do: assert(result == :ok, label)

  defp assert_outcome(result, expected, label) do
    assert {:error, message} = result, label
    reason = if expected == :ca, do: "unknown_ca", else: "hostname_check_failed"
    assert message =~ reason, "#{label}: #{message}"
  end

  defp with_server(directory, certificate, key, hostname, response, fun) do
    id = System.unique_integer([:positive])
    certfile = Path.join(directory, "server-#{id}.pem")
    keyfile = Path.join(directory, "key-#{id}.pem")
    File.write!(certfile, X509.Certificate.to_pem(certificate))
    File.write!(keyfile, X509.PrivateKey.to_pem(key))

    {:ok, listener} =
      :ssl.listen(0,
        mode: :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        versions: [:"tlsv1.2"]
      )

    {:ok, {_ip, port}} = :ssl.sockname(listener)
    server = Task.async(fn -> serve(listener, response) end)

    try do
      fun.("https://#{hostname}:#{port}")
    after
      :ssl.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp serve(listener, response) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} ->
            case :ssl.recv(socket, 0, 5_000) do
              {:ok, _request} -> :ssl.send(socket, response)
              {:error, _reason} -> :ok
            end

            :ssl.close(socket)

          {:error, _reason} ->
            :ssl.close(socket)
        end

        serve(listener, response)

      {:error, :closed} ->
        :ok
    end
  end

  defp response do
    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: #{byte_size(@body)}\r\nConnection: close\r\n\r\n#{@body}"
  end
end

[client, directory] = System.argv()
KithTLSProbe.run(client, directory)
