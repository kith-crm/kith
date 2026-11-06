defmodule KithWeb.UploadsControllerTest do
  use KithWeb.ConnCase, async: true

  alias Kith.Storage.Local
  import Kith.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    key = "#{user.account_id}/documents/#{Ecto.UUID.generate()}.html"
    assert {:ok, ^key} = Local.upload_binary("<script>secret</script>", key)
    on_exit(fn -> Local.delete(key) end)
    %{conn: log_in_user(conn, user), key: key}
  end

  test "serves account-owned bytes with conservative MIME and nosniff", %{conn: conn, key: key} do
    conn = get(conn, "/uploads/#{key}")
    assert response(conn, 200) == "<script>secret</script>"
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "serves existing literal-percent filenames after one route decode", %{conn: conn, key: key} do
    [account | _] = String.split(key, "/")
    legacy_key = "#{account}/documents/100% complete.pdf"
    path = Local.full_path(legacy_key)
    File.write!(path, "historical document")
    on_exit(fn -> File.rm(path) end)
    assert Local.read(legacy_key) == {:ok, "historical document"}
    conn = get(conn, "/uploads/#{URI.encode(legacy_key)}")
    assert response(conn, 200) == "historical document"
  end

  test "denies another account's existing file", %{key: key} do
    conn = build_conn() |> log_in_user(user_fixture()) |> get("/uploads/#{key}")
    assert json_response(conn, 403) == %{"error" => "Forbidden"}
  end

  test "handles removal after a valid key has been established", %{conn: conn, key: key} do
    assert {:ok, _path} = Local.confined_path(key)
    assert :ok = Local.delete(key)
    conn = get(conn, "/uploads/#{key}")
    assert json_response(conn, 404) == %{"error" => "File not found"}
  end

  test "rejects replacement with a symlink before serving", %{conn: conn, key: key} do
    assert {:ok, path} = Local.confined_path(key)
    outside = Path.join(System.tmp_dir!(), "upload_secret_#{Ecto.UUID.generate()}")
    File.write!(outside, "outside secret")
    on_exit(fn -> File.rm(outside) end)
    File.rm!(path)
    File.ln_s!(outside, path)
    on_exit(fn -> File.rm(path) end)
    conn = get(conn, "/uploads/#{key}")
    assert json_response(conn, 400) == %{"error" => "Invalid path"}
    assert File.read!(outside) == "outside secret"
  end

  test "rejects encoded traversal keys", %{conn: conn, key: key} do
    [account | _] = String.split(key, "/")
    conn = get(conn, "/uploads/#{account}/documents/%252e%252e/secret")
    assert json_response(conn, 400) == %{"error" => "Invalid path"}
  end
end
