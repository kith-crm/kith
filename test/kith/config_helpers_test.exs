defmodule Kith.ConfigHelpersTest do
  use ExUnit.Case, async: false

  alias Kith.ConfigHelpers

  describe "s3_endpoint_config/1" do
    test "keeps the https scheme of the endpoint" do
      assert ConfigHelpers.s3_endpoint_config("https://s3.example.com") ==
               [scheme: "https://", host: "s3.example.com", port: 443]
    end

    test "keeps the http scheme and a custom port" do
      assert ConfigHelpers.s3_endpoint_config("http://localhost:9000") ==
               [scheme: "http://", host: "localhost", port: 9000]
    end

    test "keeps a custom port on an https endpoint" do
      assert ConfigHelpers.s3_endpoint_config("https://minio.internal:9443") ==
               [scheme: "https://", host: "minio.internal", port: 9443]
    end
  end

  describe "read_secret/1" do
    test "reads from the plain env var when no _FILE variant is set" do
      System.put_env("KITH_TEST_SECRET", "plain-value")
      on_exit(fn -> System.delete_env("KITH_TEST_SECRET") end)

      assert ConfigHelpers.read_secret("KITH_TEST_SECRET") == "plain-value"
    end

    test "reads from a file when the _FILE variant points at one, taking precedence" do
      path =
        Path.join(System.tmp_dir!(), "kith_test_secret_#{System.unique_integer([:positive])}")

      File.write!(path, "from-file\n")

      System.put_env("KITH_TEST_SECRET", "plain-value")
      System.put_env("KITH_TEST_SECRET_FILE", path)

      on_exit(fn ->
        System.delete_env("KITH_TEST_SECRET")
        System.delete_env("KITH_TEST_SECRET_FILE")
        File.rm(path)
      end)

      assert ConfigHelpers.read_secret("KITH_TEST_SECRET") == "from-file"
    end
  end
end
