defmodule Kith.ConfigHelpersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kith.ConfigHelpers

  describe "oban_pruner_max_age_seconds/0" do
    test "defaults to 7 days when OBAN_PRUNER_MAX_AGE_DAYS is unset" do
      System.delete_env("OBAN_PRUNER_MAX_AGE_DAYS")

      assert ConfigHelpers.oban_pruner_max_age_seconds() == 604_800
    end

    test "reads OBAN_PRUNER_MAX_AGE_DAYS when set" do
      System.put_env("OBAN_PRUNER_MAX_AGE_DAYS", "30")
      on_exit(fn -> System.delete_env("OBAN_PRUNER_MAX_AGE_DAYS") end)

      assert ConfigHelpers.oban_pruner_max_age_seconds() == 30 * 24 * 60 * 60
    end

    test "OBAN_PRUNER_MAX_AGE_DAYS=14 yields two weeks in seconds" do
      System.put_env("OBAN_PRUNER_MAX_AGE_DAYS", "14")
      on_exit(fn -> System.delete_env("OBAN_PRUNER_MAX_AGE_DAYS") end)

      assert ConfigHelpers.oban_pruner_max_age_seconds() == 1_209_600
    end

    test "OBAN_PRUNER_MAX_AGE_DAYS=0 is clamped to one day and warns" do
      System.put_env("OBAN_PRUNER_MAX_AGE_DAYS", "0")
      on_exit(fn -> System.delete_env("OBAN_PRUNER_MAX_AGE_DAYS") end)

      log =
        capture_log(fn ->
          assert ConfigHelpers.oban_pruner_max_age_seconds() == 86_400
        end)

      assert log =~ "clamping to 1 day"
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
