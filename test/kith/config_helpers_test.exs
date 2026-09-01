defmodule Kith.ConfigHelpersTest do
  use ExUnit.Case, async: false

  alias Kith.ConfigHelpers

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
