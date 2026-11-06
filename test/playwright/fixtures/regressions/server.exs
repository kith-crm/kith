System.put_env("KITH_TEST_SERVER", "1")
Code.require_file("boot.exs", __DIR__)
Process.sleep(:infinity)
