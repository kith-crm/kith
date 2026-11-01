System.put_env("PR44_SERVER", "1")
Code.require_file("boot.exs", __DIR__)
Process.sleep(:infinity)
