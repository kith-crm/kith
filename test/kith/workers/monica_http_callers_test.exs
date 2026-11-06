defmodule Kith.Workers.MonicaHTTPCallersTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi
  alias Kith.Workers.MonicaDocumentImportWorker
  alias Kith.Workers.MonicaMiscDataWorker
  alias Kith.Workers.MonicaPhotoSyncWorker

  @controlled_scale_ms 1_000_000_000_000_000

  setup do
    user = user_fixture()
    host = "caller-#{System.unique_integer([:positive])}.example"
    Kith.TestEnv.put_env_restoring(:kith, :monica_rate_limit, 10)
    Kith.TestEnv.put_env_restoring(:kith, :monica_rate_limit_scale_ms, @controlled_scale_ms)
    Kith.TestEnv.put_env_restoring(:kith, :monica_rate_limit_retry_sleep_ms, 5)

    import_job =
      import_fixture(user.account_id, user.id, %{
        source: "monica_api",
        api_url: "https://#{host}",
        api_key_encrypted: "fixture-key"
      })

    %{user: user, host: host, import_job: import_job}
  end

  test "photo listings acquire exactly one slot at dispatch and retain bearer auth", ctx do
    configure_transport(fn conn ->
      assert hits(ctx.host) == 1
      assert conn.request_path == "/api/photos"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]
      Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
    end)

    assert :ok = perform_job(MonicaPhotoSyncWorker, photo_args(ctx))
    assert hits(ctx.host) == 1
  end

  @tag timeout: 5_000, capture_log: true
  test "photo 429 retries stop at Req's finite limit without an outer sleep loop", ctx do
    Kith.TestEnv.put_env_restoring(:kith, :monica_req_options,
      plug: fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(429, "")
      end,
      retry_delay: 0
    )

    assert {:error, :rate_limited} = perform_job(MonicaPhotoSyncWorker, photo_args(ctx))
    assert hits(ctx.host) == 4
  end

  test "document downloads charge actual redirect hosts and store binary bytes", ctx do
    download_host = "download-#{ctx.host}"
    final_host = "final-#{ctx.host}"
    binary = <<80, 75, 3, 4, 0, 255, 128>>

    configure_transport(fn conn ->
      assert hits(ctx.host) == 0

      case conn.host do
        ^download_host ->
          assert hits(download_host) == 1
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]

          conn
          |> Plug.Conn.put_resp_header("location", "https://#{final_host}/file.zip")
          |> Plug.Conn.send_resp(302, "")

        ^final_host ->
          assert hits(final_host) == 1
          assert Plug.Conn.get_req_header(conn, "authorization") == []

          conn
          |> Plug.Conn.put_resp_content_type("application/zip")
          |> Plug.Conn.send_resp(200, binary)
      end
    end)

    contact = contact_fixture(ctx.user.account_id)
    args = document_args(ctx, contact, "https://#{download_host}/file.zip")
    assert :ok = perform_job(MonicaDocumentImportWorker, args)
    assert [document] = Kith.Contacts.list_documents(contact.id)
    assert document.file_size == byte_size(binary)
    assert {:ok, ^binary} = Kith.Storage.read(document.storage_key)
    assert Imports.count_import_records_by_type(ctx.import_job.id, "document") == 1
  end

  @tag capture_log: true
  test "source connection retries and redirects consume exactly one slot each", ctx do
    destination = "redirect-#{ctx.host}"

    plug = fn conn ->
      case {conn.host, hits(ctx.host)} do
        {host, 1} when host == ctx.host ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]
          conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(429, "")

        {host, 2} when host == ctx.host ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://#{destination}/api/me")
          |> Plug.Conn.send_resp(302, "")

        {^destination, 2} ->
          assert hits(destination) == 1
          assert Plug.Conn.get_req_header(conn, "authorization") == []
          Req.Test.json(conn, %{})
      end
    end

    credential = %{
      url: "https://legacy:ignored@#{ctx.host}",
      api_key: "fixture-key",
      req_options: [plug: plug, retry_delay: 0]
    }

    assert :ok = MonicaApi.test_connection(credential)
    assert hits(ctx.host) == 2
    assert hits(destination) == 1
  end

  @tag capture_log: true
  test "misc cancellation after a 429 prevents a retry from being dispatched", ctx do
    contact = contact_fixture(ctx.user.account_id)
    observer = self()

    configure_transport(fn conn ->
      send(observer, :misc_dispatched)
      assert hits(ctx.host) == 1
      {:ok, _} = Imports.update_import_status(Imports.get_import!(ctx.import_job.id), "cancelled")
      conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(429, "")
    end)

    options = Application.fetch_env!(:kith, :monica_req_options) |> Keyword.delete(:retry)
    Application.put_env(:kith, :monica_req_options, options ++ [retry_delay: 0])

    assert :ok = perform_job(MonicaMiscDataWorker, misc_args(ctx, contact))
    assert_received :misc_dispatched
    refute_received :misc_dispatched
    assert hits(ctx.host) == 1
    assert Imports.get_import!(ctx.import_job.id).status == "cancelled"
  end

  defp misc_args(ctx, contact) do
    Map.put(photo_args(ctx), "plan", [
      %{"source_id" => "42", "local_id" => contact.id, "endpoints" => ["calls"]}
    ])
  end

  test "source, photos and downloads share the configured budget until bucket resets", ctx do
    Application.put_env(:kith, :monica_rate_limit, 1)
    observer = self()

    configure_transport(fn conn ->
      send(observer, {:dispatch, conn.request_path})

      if conn.request_path == "/api/photos" do
        Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, "bytes")
      end
    end)

    assert :ok =
             MonicaApi.test_connection(%{
               url: "https://#{ctx.host}",
               api_key: "fixture-key",
               req_options: Application.fetch_env!(:kith, :monica_req_options)
             })

    assert_received {:dispatch, "/api/me"}

    photo = Task.async(fn -> perform_job(MonicaPhotoSyncWorker, photo_args(ctx)) end)

    try do
      wait_for_denial(ctx.host)
      refute_received {:dispatch, _}
      Kith.RateLimiter.reset("monica_api:#{ctx.host}", @controlled_scale_ms)
      assert :ok = Task.await(photo)
      assert_received {:dispatch, "/api/photos"}
    after
      Task.shutdown(photo, :brutal_kill)
    end

    contact = contact_fixture(ctx.user.account_id)

    doc =
      Task.async(fn ->
        perform_job(
          MonicaDocumentImportWorker,
          document_args(ctx, contact, "https://#{ctx.host}/file")
        )
      end)

    try do
      wait_for_denial(ctx.host)
      refute_received {:dispatch, _}
      Kith.RateLimiter.reset("monica_api:#{ctx.host}", @controlled_scale_ms)
      assert :ok = Task.await(doc)
      assert_received {:dispatch, "/file"}
      assert [_] = Kith.Contacts.list_documents(contact.id)
    after
      Task.shutdown(doc, :brutal_kill)
    end
  end

  test "misc cancellation while blocked on admission prevents dispatch after the wait", ctx do
    Application.put_env(:kith, :monica_rate_limit, 1)
    Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://#{ctx.host}")
    observer = self()

    configure_transport(fn conn ->
      send(observer, :unexpected_dispatch)
      Req.Test.json(conn, %{"data" => []})
    end)

    contact = contact_fixture(ctx.user.account_id)
    task = Task.async(fn -> perform_job(MonicaMiscDataWorker, misc_args(ctx, contact)) end)

    try do
      wait_for_denial(ctx.host)
      {:ok, _} = Imports.update_import_status(Imports.get_import!(ctx.import_job.id), "cancelled")
      Kith.RateLimiter.reset("monica_api:#{ctx.host}", @controlled_scale_ms)
      assert :ok = Task.await(task)
      refute_received :unexpected_dispatch
      assert Imports.get_import!(ctx.import_job.id).status == "cancelled"
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  @tag capture_log: true
  test "oversized photo listings and document downloads preserve response limits", ctx do
    oversized = String.duplicate("x", 20 * 1024 * 1024 + 1)
    configure_transport(fn conn -> Plug.Conn.send_resp(conn, 200, oversized) end)

    assert {:error, %Req.TransportError{reason: :response_too_large}} =
             perform_job(MonicaPhotoSyncWorker, photo_args(ctx))

    contact = contact_fixture(ctx.user.account_id)

    assert :ok =
             perform_job(
               MonicaDocumentImportWorker,
               document_args(ctx, contact, "https://#{ctx.host}/oversized")
             )

    assert Kith.Contacts.list_documents(contact.id) == []
    assert hits(ctx.host) == 2
  end

  @tag capture_log: true
  test "photo 429 retry can recover and persists the successful summary", ctx do
    Kith.TestEnv.put_env_restoring(:kith, :monica_req_options,
      plug: fn conn ->
        if hits(ctx.host) == 1 do
          conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(429, "")
        else
          Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
        end
      end,
      retry_delay: 0
    )

    assert :ok = perform_job(MonicaPhotoSyncWorker, photo_args(ctx))
    assert hits(ctx.host) == 2
    assert Imports.get_import!(ctx.import_job.id).sync_summary["total"] == 0
  end

  defp wait_for_denial(host, retries \\ 100)
  defp wait_for_denial(_host, 0), do: flunk("expected denied acquisition")

  defp wait_for_denial(host, retries) do
    if hits(host) > 1 do
      :ok
    else
      Process.sleep(5)
      wait_for_denial(host, retries - 1)
    end
  end

  defp document_args(ctx, contact, url) do
    %{
      "account_id" => ctx.user.account_id,
      "user_id" => ctx.user.id,
      "contact_id" => contact.id,
      "import_id" => ctx.import_job.id,
      "credential_url" => "https://#{ctx.host}",
      "documents" => [%{"id" => 501, "original_filename" => "file.zip", "download_url" => url}]
    }
  end

  defp photo_args(ctx),
    do: %{"import_id" => ctx.import_job.id, "credential_url" => "https://#{ctx.host}"}

  defp configure_transport(plug, options \\ []) do
    Kith.TestEnv.put_env_restoring(
      :kith,
      :monica_req_options,
      [plug: plug, retry: false] ++ options
    )
  end

  defp hits(host) do
    :ets.match_object(Kith.RateLimiter.ETS, {{"monica_api:#{host}", :_}, :_, :_})
    |> Enum.map(fn {_, count, _} -> count end)
    |> Enum.sum()
  end
end
