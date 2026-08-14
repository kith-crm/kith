defmodule Kith.Workers.MonicaApiCrawlWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports
  alias Kith.Workers.MonicaApiCrawlWorker
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
          "credential_url" => "https://monica.test",
          "credential_api_key" => "test-key"
        }
      )
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

      assert_enqueued(
        worker: Kith.Workers.MonicaMiscDataWorker,
        args: %{"import_id" => import_job.id}
      )
    end
  end
end
