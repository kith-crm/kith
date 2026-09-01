defmodule Kith.StorageTest do
  use Kith.DataCase, async: true

  alias Kith.Storage

  describe "generate_key/3" do
    test "generates a UUID-based key with correct structure" do
      key = Storage.generate_key(1, "photos", "my_photo.jpg")
      assert key =~ ~r/^1\/photos\/[a-f0-9\-]+\.jpg$/
    end

    test "preserves file extension" do
      key = Storage.generate_key(42, "documents", "report.pdf")
      assert String.ends_with?(key, ".pdf")
      assert String.starts_with?(key, "42/documents/")
    end

    test "generates unique keys" do
      key1 = Storage.generate_key(1, "photos", "a.jpg")
      key2 = Storage.generate_key(1, "photos", "a.jpg")
      assert key1 != key2
    end
  end

  describe "csp_img_src/0" do
    test "is empty for the local backend (served from the app origin)" do
      assert Storage.csp_img_src() == ""
    end
  end

  describe "content_type/1" do
    test "detects image MIME types" do
      assert Storage.content_type("photo.jpg") == "image/jpeg"
      assert Storage.content_type("photo.jpeg") == "image/jpeg"
      assert Storage.content_type("photo.png") == "image/png"
      assert Storage.content_type("photo.gif") == "image/gif"
      assert Storage.content_type("photo.webp") == "image/webp"
    end

    test "detects document MIME types" do
      assert Storage.content_type("doc.pdf") == "application/pdf"
      assert Storage.content_type("doc.txt") == "text/plain"
    end

    test "returns octet-stream for unknown" do
      assert Storage.content_type("file.xyz") == "application/octet-stream"
    end
  end

  describe "validate path traversal" do
    test "upload rejects paths with .." do
      assert {:error, :invalid_path} = Storage.upload("/tmp/file", "../etc/passwd")
    end

    test "delete rejects paths with .." do
      assert {:error, :invalid_path} = Storage.delete("../../etc/passwd")
    end
  end

  describe "max_upload_size_bytes/0" do
    test "returns configured size in bytes" do
      assert is_integer(Storage.max_upload_size_bytes())
      assert Storage.max_upload_size_bytes() > 0
    end
  end

  describe "max_storage_size_bytes/0" do
    test "returns configured size in bytes" do
      assert is_integer(Storage.max_storage_size_bytes())
    end
  end
end
