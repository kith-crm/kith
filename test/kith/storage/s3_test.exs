defmodule Kith.Storage.S3Test do
  # Global app env (S3 config): must not run alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kith.Storage.S3

  setup do
    Kith.TestEnv.configure_s3()
  end

  describe "presigned_url/2" do
    test "is identical within one UTC hour and changes in the next" do
      a = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 10:05:00])
      b = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 10:59:59])
      c = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 11:00:00])

      assert a == b
      refute a == c
      assert a =~ "X-Amz-Date=20261015T100000Z"
      assert a =~ "X-Amz-Expires=7200"
    end
  end

  test "reads through the actual Req adapter and signs every ExAws retry" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Kith.TestEnv.put_env_restoring(:ex_aws, :http_client, ExAws.Request.Req)

    Kith.TestEnv.put_env_restoring(:ex_aws, :retries,
      max_attempts: 2,
      base_backoff_in_ms: 1,
      max_backoff_in_ms: 1
    )

    fixture = fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/kith-test/assets/a.png"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      verify_signature!(conn, body)
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      Plug.Conn.send_resp(conn, if(attempt == 1, do: 503, else: 200), "image-data")
    end

    Kith.TestEnv.put_env_restoring(:ex_aws, :req_opts, plug: fixture)
    assert {:ok, "image-data"} = S3.read("assets/a.png")
    assert Agent.get(counter, & &1) == 2
  end

  # Independently recompute SigV4 from the request the Req adapter actually
  # delivers, rather than accepting the presence of an Authorization header.
  defp verify_signature!(conn, body) do
    [authorization] = Plug.Conn.get_req_header(conn, "authorization")

    [_, scope, signed_headers, signature] =
      Regex.run(
        ~r/^AWS4-HMAC-SHA256 Credential=test\/(.*),SignedHeaders=(.*),Signature=(.*)$/,
        authorization
      )

    [date, "us-east-1", "s3", "aws4_request"] = String.split(scope, "/")
    [timestamp] = Plug.Conn.get_req_header(conn, "x-amz-date")

    headers =
      signed_headers
      |> String.split(";")
      |> Enum.map_join("", fn name ->
        value = conn |> Plug.Conn.get_req_header(name) |> Enum.join(",")
        name <> ":" <> (value |> String.trim() |> String.replace(~r/\s+/, " ")) <> "\n"
      end)

    canonical =
      Enum.join(
        [
          conn.method,
          conn.request_path,
          conn.query_string,
          headers,
          signed_headers,
          sha256(body)
        ],
        "\n"
      )

    string_to_sign = Enum.join(["AWS4-HMAC-SHA256", timestamp, scope, sha256(canonical)], "\n")
    key = "AWS4test" |> hmac(date) |> hmac("us-east-1") |> hmac("s3") |> hmac("aws4_request")
    assert Base.encode16(hmac(key, string_to_sign), case: :lower) == signature
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp hmac(key, value), do: :crypto.mac(:hmac, :sha256, key, value)

  describe "csp_img_src/0" do
    test "scheme and host, default port omitted" do
      assert S3.csp_img_src() == "https://s3.example.com"
    end

    test "a custom port is kept" do
      Application.put_env(:ex_aws, :s3, scheme: "http://", host: "minio.local", port: 9000)
      assert S3.csp_img_src() == "http://minio.local:9000"
    end

    test "a config error returns an empty origin and logs" do
      # A non-keyword :s3 config makes ExAws.Config.new/1 raise. If this shape
      # stops raising on a future ExAws, pick another one that does.
      Application.put_env(:ex_aws, :s3, "not a keyword list")

      log = capture_log(fn -> assert S3.csp_img_src() == "" end)
      assert log =~ "Failed to build S3 CSP img-src:"
    end
  end
end
