defmodule Kith.Storage.LocalTest do
  use Kith.DataCase, async: false

  alias Kith.Storage.Local

  @test_dir "priv/uploads/test/local_test"

  setup do
    # Ensure clean test directory
    path = Local.full_path(@test_dir)
    File.rm_rf!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    :ok
  end

  test "all public operations reject absolute, dot, encoded and backslash paths" do
    for key <- [
          "/etc/passwd",
          "../escape",
          "safe/../escape",
          "safe/./file",
          "safe//file",
          "safe/%2e%2e/file",
          "safe\\..\\file",
          "safe/" <> <<0>>
        ] do
      assert {:error, :invalid_path} = Local.read(key)
      assert {:error, :invalid_path} = Local.upload_binary("overwrite", key)
      assert {:error, :invalid_path} = Local.delete(key)
      assert {:error, :invalid_path} = Local.url(key)
    end
  end

  test "legacy filenames with literal percent signs remain readable" do
    key = "#{@test_dir}/100% complete.pdf"
    path = Local.full_path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "historical file contents")
    assert Local.read(key) == {:ok, "historical file contents"}
    assert Local.delete(key) == :ok
  end

  test "symlinks cannot redirect reads, writes or deletes outside storage" do
    outside =
      Path.join(System.tmp_dir!(), "storage_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "outside secret")
    on_exit(fn -> File.rm_rf!(outside) end)
    key = "#{@test_dir}/link/secret.txt"
    link = Local.full_path("#{@test_dir}/link")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(outside, link)

    assert {:error, :invalid_path} = Local.read(key)
    assert {:error, :invalid_path} = Local.upload_binary("overwrite", key)
    assert {:error, :invalid_path} = Local.delete(key)
    assert File.read!(Path.join(outside, "secret.txt")) == "outside secret"
  end

  test "rechecks the path for each use after a previously valid file is replaced" do
    key = "#{@test_dir}/replace.txt"

    outside =
      Path.join(System.tmp_dir!(), "storage_replace_#{System.unique_integer([:positive])}")

    File.write!(outside, "outside secret")
    on_exit(fn -> File.rm(outside) end)
    assert {:ok, ^key} = Local.upload_binary("inside bytes", key)
    assert {:ok, path} = Local.confined_path(key)
    File.rm!(path)
    assert {:error, :enoent} = Local.read(key)
    File.ln_s!(outside, path)
    assert {:error, :invalid_path} = Local.read(key)
    assert {:error, :invalid_path} = Local.delete(key)
    assert File.read!(outside) == "outside secret"
  end

  describe "upload/3" do
    test "copies file to correct location" do
      # Create a temp source file
      source =
        Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer([:positive])}.txt")

      File.write!(source, "hello world")

      key = "#{@test_dir}/test_file.txt"
      assert {:ok, ^key} = Local.upload(source, key)
      assert File.exists?(Local.full_path(key))

      File.rm!(source)
    end
  end

  describe "upload_binary/3" do
    test "writes binary to correct location" do
      key = "#{@test_dir}/binary_test.txt"
      assert {:ok, ^key} = Local.upload_binary("binary content", key)
      assert File.read!(Local.full_path(key)) == "binary content"
    end

    test "creates directories automatically" do
      key = "#{@test_dir}/deep/nested/dir/file.txt"
      assert {:ok, ^key} = Local.upload_binary("content", key)
      assert File.exists?(Local.full_path(key))
    end
  end

  describe "delete/1" do
    test "removes file from disk" do
      key = "#{@test_dir}/to_delete.txt"
      {:ok, _} = Local.upload_binary("content", key)
      assert File.exists?(Local.full_path(key))

      assert :ok = Local.delete(key)
      refute File.exists?(Local.full_path(key))
    end

    test "returns error for missing file" do
      assert {:error, :not_found} = Local.delete("#{@test_dir}/nonexistent.txt")
    end
  end

  describe "url/1" do
    test "returns relative URL path" do
      assert Local.url("1/photos/abc.jpg") == "/uploads/1/photos/abc.jpg"
    end
  end
end
