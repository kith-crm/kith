defmodule Kith.Workers.MonicaApiCrawlWorkerTest do
  # async: false — tests set the global :monica_req_options app env.
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports
  alias Kith.Workers.MonicaApiCrawlWorker
  alias Kith.Workers.MonicaApiKeyReleaseWorker
  alias Kith.Workers.MonicaDocumentImportWorker
  alias Kith.Workers.MonicaPhotoSyncWorker

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  setup do
    user = user_fixture()
    seed_reference_data!()
    %{user: user, account_id: user.account_id}
  end

  defp api_import_fixture_with_stub(account_id, user_id) do
    # The worker reads api_key_encrypted from the DB.
    # In test env, Cloak encrypts/decrypts transparently.
    import_fixture(account_id, user_id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key",
      api_options: %{"photos" => false}
    })
  end

  describe "perform/1" do
    test "completes import and wipes API key", %{user: user, account_id: account_id} do
      # The worker builds a credential from the DB. When the API is unreachable,
      # the crawl still succeeds with errors in the summary (graceful degradation).
      import_job = api_import_fixture_with_stub(account_id, user.id)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      updated = Imports.get_import!(import_job.id)
      assert updated.status == "completed"
      assert updated.started_at != nil
      assert updated.completed_at != nil
      # API key should be wiped after completion
      assert is_nil(updated.api_key_encrypted)
    end

    test "respects 30-minute timeout" do
      assert MonicaApiCrawlWorker.timeout(%Oban.Job{}) == :timer.minutes(30)
    end

    test "builds correct options from import api_options", %{user: user, account_id: account_id} do
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"photos" => true, "extra_notes" => false}
        })

      # Just verify the import was created correctly
      assert import_job.api_options["photos"] == true
      assert import_job.api_options["extra_notes"] == false
    end

    test "build_opts forwards every wizard-saved option to the source module",
         %{user: user, account_id: account_id} do
      # Regression for Bug C: build_opts used to hand-curate a map containing
      # only "extra_notes" — every other wizard option (auto_merge_duplicates,
      # photos, pets, phone_default_region, …) was silently dropped before
      # reaching MonicaApi.crawl/5.
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{
            "auto_merge_duplicates" => true,
            "phone_default_region" => "US",
            "photos" => true,
            "pets" => true
          }
        })

      opts = MonicaApiCrawlWorker.build_opts(import_job)

      assert opts["auto_merge_duplicates"] == true
      assert opts["phone_default_region"] == "US"
      assert opts["photos"] == true
      assert opts["pets"] == true
      # extra_notes defaults to true unless explicitly false
      assert opts["extra_notes"] == true
    end

    test "build_opts honors extra_notes=false explicitly",
         %{user: user, account_id: account_id} do
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"extra_notes" => false}
        })

      assert MonicaApiCrawlWorker.build_opts(import_job)["extra_notes"] == false
    end

    test "build_opts handles missing api_options map", %{user: user, account_id: account_id} do
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: nil
        })

      opts = MonicaApiCrawlWorker.build_opts(import_job)
      assert opts["extra_notes"] == true
    end

    test "enqueues MonicaPhotoSyncWorker when photos opt-in", %{
      user: user,
      account_id: account_id
    } do
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"photos" => true}
        })

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      assert_enqueued(
        worker: MonicaPhotoSyncWorker,
        args: %{
          "import_id" => import_job.id,
          "credential_url" => "https://monica.test"
        }
      )

      # No credential in args — Oban stores them as plain JSON and Oban Web
      # renders them as-is. The worker reads the key from the Import row.
      [job] = all_enqueued(worker: MonicaPhotoSyncWorker)
      assert_no_credential_in_args(job)

      # The photo job still needs the key, so it is kept until the release
      # worker sees every follow-up job finish.
      assert Imports.get_import!(import_job.id).api_key_encrypted == "test-key"
      assert_enqueued(worker: MonicaApiKeyReleaseWorker, args: %{"import_id" => import_job.id})
    end

    test "does not enqueue MonicaPhotoSyncWorker when photos opt-out", %{
      user: user,
      account_id: account_id
    } do
      import_job = api_import_fixture_with_stub(account_id, user.id)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      refute_enqueued(worker: MonicaPhotoSyncWorker)
    end

    test "enqueues MonicaMiscDataWorker with the plan from crawl summary",
         %{user: user, account_id: account_id} do
      # Boundary regression: the misc_data_plan key produced by
      # MonicaApi.crawl/5 must reach MonicaMiscDataWorker.new/1 unmodified —
      # the same wizard→crawl→worker contract that Bug C silently violated
      # for auto_merge_duplicates in the previous PR.

      stub_name = :monica_crawl_misc_stub

      Application.put_env(
        :kith,
        :monica_req_options,
        plug: {Req.Test, stub_name},
        retry: false
      )

      on_exit(fn -> Application.delete_env(:kith, :monica_req_options) end)

      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"calls" => true, "pets" => false}
        })

      contacts =
        Kith.MonicaApiFixtures.contacts_page_json(
          [
            Kith.MonicaApiFixtures.contact_json(
              id: 7,
              first_name: "Plan",
              last_name: "Test",
              statistics: %{"number_of_calls" => 2}
            )
          ],
          1,
          1,
          1
        )

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, contacts)
      end)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      assert [job] = all_enqueued(worker: Kith.Workers.MonicaMiscDataWorker)
      assert job.args["import_id"] == import_job.id
      assert job.args["credential_url"] == "https://monica.test"
      assert [%{"source_id" => "7", "endpoints" => endpoints}] = job.args["plan"]
      assert "calls" in endpoints
      assert_no_credential_in_args(job)

      assert Imports.get_import!(import_job.id).api_key_encrypted == "test-key"
      assert_enqueued(worker: MonicaApiKeyReleaseWorker, args: %{"import_id" => import_job.id})
    end

    test "enqueues MonicaDocumentImportWorker per contact with documents, without the key",
         %{user: user, account_id: account_id} do
      stub_monica(:monica_crawl_documents_stub)

      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"documents" => true, "extra_notes" => false}
        })

      contacts =
        Kith.MonicaApiFixtures.contacts_page_json(
          [
            Kith.MonicaApiFixtures.contact_json(id: 7, first_name: "Has", last_name: "Docs"),
            Kith.MonicaApiFixtures.contact_json(id: 8, first_name: "No", last_name: "Docs")
          ],
          1,
          1,
          2
        )

      doc = %{
        "id" => 501,
        "original_filename" => "contract.pdf",
        "download_url" => "https://monica.test/storage/contract.pdf"
      }

      Req.Test.stub(:monica_crawl_documents_stub, fn conn ->
        case conn.request_path do
          "/api/contacts" -> Req.Test.json(conn, contacts)
          "/api/contacts/7/documents" -> Req.Test.json(conn, %{"data" => [doc]})
          _ -> Req.Test.json(conn, %{"data" => []})
        end
      end)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      assert [job] = all_enqueued(worker: MonicaDocumentImportWorker)
      assert job.args["import_id"] == import_job.id
      assert job.args["account_id"] == account_id
      assert job.args["credential_url"] == "https://monica.test"
      assert job.args["documents"] == [doc]
      assert_no_credential_in_args(job)

      # Document jobs were enqueued during the crawl, so the key must survive
      # the crawl and be released later.
      assert Imports.get_import!(import_job.id).api_key_encrypted == "test-key"
      assert_enqueued(worker: MonicaApiKeyReleaseWorker, args: %{"import_id" => import_job.id})
    end

    test "wipes the key immediately when no follow-up job was enqueued",
         %{user: user, account_id: account_id} do
      import_job = api_import_fixture_with_stub(account_id, user.id)

      assert :ok = perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id})

      assert is_nil(Imports.get_import!(import_job.id).api_key_encrypted)
      refute_enqueued(worker: MonicaApiKeyReleaseWorker)
    end
  end

  describe "failure and retry" do
    test "a non-final failed attempt keeps the key; the final one wipes it",
         %{user: user, account_id: account_id} do
      import_job = api_import_fixture_with_stub(account_id, user.id)

      assert {:error, :boom} =
               MonicaApiCrawlWorker.fail_attempt(import_job, attempt_job(1), :boom)

      failed = Imports.get_import!(import_job.id)
      assert failed.status == "failed"
      assert failed.api_key_encrypted == "test-key"

      assert {:error, :boom} = MonicaApiCrawlWorker.fail_attempt(failed, attempt_job(3), :boom)
      assert is_nil(Imports.get_import!(import_job.id).api_key_encrypted)
    end

    test "regression: fail -> retry -> success completes and keeps the key for follow-ups",
         %{user: user, account_id: account_id} do
      # Previously attempt 1's failure wiped the key, and the successful
      # retry then raised FunctionClauseError after marking the import
      # completed — leaving the key in the DB and re-running the crawl.
      import_job =
        import_fixture(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key",
          api_options: %{"photos" => true}
        })

      MonicaApiCrawlWorker.fail_attempt(import_job, attempt_job(1), :transient)

      assert :ok =
               perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id},
                 attempt: 2,
                 max_attempts: 3
               )

      completed = Imports.get_import!(import_job.id)
      assert completed.status == "completed"

      # The retry had a key to crawl with, and the photo job still needs it.
      assert completed.api_key_encrypted == "test-key"
      assert [photo_job] = all_enqueued(worker: MonicaPhotoSyncWorker)
      assert_no_credential_in_args(photo_job)
      assert_enqueued(worker: MonicaApiKeyReleaseWorker, args: %{"import_id" => import_job.id})
    end

    test "a retry whose key is already wiped cancels without crawling",
         %{user: user, account_id: account_id} do
      stub_monica(:monica_crawl_no_key_stub)
      pid = self()

      Req.Test.stub(:monica_crawl_no_key_stub, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      import_job = api_import_fixture_with_stub(account_id, user.id)
      {:ok, _} = Imports.wipe_api_key(import_job)

      assert {:cancel, :api_key_missing} =
               perform_job(MonicaApiCrawlWorker, %{import_id: import_job.id}, attempt: 2)

      refute_received {:request, _}

      updated = Imports.get_import!(import_job.id)
      assert updated.status == "failed"
      assert updated.summary["error"] =~ "API key is no longer available"
    end
  end

  defp attempt_job(attempt), do: %Oban.Job{attempt: attempt, max_attempts: 3}

  defp stub_monica(stub_name) do
    Application.put_env(:kith, :monica_req_options, plug: {Req.Test, stub_name}, retry: false)
    on_exit(fn -> Application.delete_env(:kith, :monica_req_options) end)
  end

  defp assert_no_credential_in_args(%Oban.Job{args: args}) do
    for key <- Map.keys(args) do
      refute key =~ ~r/api_key|secret|token|credential_(?!url)/,
             "unexpected credential-like key #{inspect(key)} in job args"
    end

    refute inspect(args) =~ "test-key"
  end
end
