defmodule Kith.Workers.ExportCacheTest do
  use ExUnit.Case, async: true

  import Bitwise

  test "exports with the same logical key reserve private, independent files" do
    {:ok, first} =
      Kith.Workers.ExportWorker.cache_export("export_42", ~s({"name":"Ada"}), "token-a")

    on_exit(fn -> File.rm_rf!(first) end)

    {:ok, second} =
      Kith.Workers.ExportWorker.cache_export("export_42", ~s({"name":"Grace"}), "token-b")

    on_exit(fn -> File.rm_rf!(second) end)

    assert first != second
    assert File.read!(Path.join(first, "export.json")) == ~s({"name":"Ada"})
    assert File.read!(Path.join(second, "export.json")) == ~s({"name":"Grace"})

    assert %{"key" => "export_42", "token" => "token-a", "expires_at" => expiry} =
             first |> Path.join("export.meta") |> File.read!() |> Jason.decode!()

    assert expiry > System.system_time(:second) + 86_300

    assert band(File.stat!(first).mode, 0o777) == 0o700
    assert band(File.stat!(Path.join(first, "export.json")).mode, 0o777) == 0o600
    assert band(File.stat!(Path.join(first, "export.meta")).mode, 0o777) == 0o600
  end
end
