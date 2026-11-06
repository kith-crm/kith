defmodule Kith.Workers.MonicaApiKeyReleaseWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports

  alias Kith.Workers.{
    MonicaApiKeyReleaseWorker,
    MonicaDocumentImportWorker,
    MonicaMiscDataWorker,
    MonicaPhotoSyncWorker
  }

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  setup do
    user = user_fixture()

    import_job =
      import_fixture(user.account_id, user.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "test-key"
      })

    %{import_job: import_job}
  end

  describe "release/1" do
    test "wipes the key immediately when no follow-up job is pending", %{import_job: import_job} do
      assert {:ok, _} = MonicaApiKeyReleaseWorker.release(import_job)

      assert key(import_job) == nil
      refute_enqueued(worker: MonicaApiKeyReleaseWorker)
    end

    test "defers the wipe to a release job while follow-ups are pending",
         %{import_job: import_job} do
      insert_followup!(MonicaPhotoSyncWorker, import_job)

      assert {:ok, %Oban.Job{}} = MonicaApiKeyReleaseWorker.release(import_job)

      assert key(import_job) == "test-key"
      assert_enqueued(worker: MonicaApiKeyReleaseWorker, args: %{"import_id" => import_job.id})
    end
  end

  describe "perform/1" do
    test "snoozes and keeps the key while any follow-up job can still run",
         %{import_job: import_job} do
      photo = insert_followup!(MonicaPhotoSyncWorker, import_job)
      insert_followup!(MonicaMiscDataWorker, import_job)
      set_state!(photo, "completed")

      assert {:snooze, _} = perform_release(import_job)
      assert key(import_job) == "test-key"
    end

    test "wipes the key once the last follow-up job completes", %{import_job: import_job} do
      photo = insert_followup!(MonicaPhotoSyncWorker, import_job)
      misc = insert_followup!(MonicaMiscDataWorker, import_job)
      doc = insert_followup!(MonicaDocumentImportWorker, import_job)

      set_state!(photo, "completed")
      set_state!(misc, "completed")
      assert {:snooze, _} = perform_release(import_job)

      set_state!(doc, "completed")
      assert :ok = perform_release(import_job)
      assert key(import_job) == nil
    end

    test "waits through a retry and wipes after the final attempt is discarded",
         %{import_job: import_job} do
      photo = insert_followup!(MonicaPhotoSyncWorker, import_job)

      set_state!(photo, "retryable")
      assert {:snooze, _} = perform_release(import_job)
      assert key(import_job) == "test-key"

      set_state!(photo, "discarded")
      assert :ok = perform_release(import_job)
      assert key(import_job) == nil
    end

    test "wipes the key when the follow-up job was cancelled", %{import_job: import_job} do
      MonicaDocumentImportWorker |> insert_followup!(import_job) |> set_state!("cancelled")

      assert :ok = perform_release(import_job)
      assert key(import_job) == nil
    end

    test "is a no-op when the key is already gone", %{import_job: import_job} do
      {:ok, _} = Imports.wipe_api_key(import_job)
      insert_followup!(MonicaPhotoSyncWorker, import_job)

      assert :ok = perform_release(import_job)
    end

    test "is a no-op when the import no longer exists" do
      assert :ok = perform_job(MonicaApiKeyReleaseWorker, %{"import_id" => -1})
    end
  end

  defp perform_release(import_job),
    do: perform_job(MonicaApiKeyReleaseWorker, %{"import_id" => import_job.id})

  defp key(import_job), do: Imports.get_import!(import_job.id).api_key_encrypted

  defp insert_followup!(worker, import_job) do
    {:ok, job} =
      %{"import_id" => import_job.id, "credential_url" => "https://monica.test"}
      |> worker.new()
      |> Oban.insert()

    job
  end

  defp set_state!(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    job
  end
end
