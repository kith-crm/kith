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
