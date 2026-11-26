defmodule Kith.Workers.ImportApiKeySweepWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Accounts.Scope
  alias Kith.Imports
  alias Kith.Imports.Import

  alias Kith.Workers.{
    ImportApiKeySweepWorker,
    MonicaApiCrawlWorker,
    MonicaApiKeyReleaseWorker,
    MonicaDocumentImportWorker,
    MonicaMiscDataWorker,
    MonicaPhotoSyncWorker
  }

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  @grace 24 * 60 * 60

  test "scheduling a Monica import enqueues one delayed sweep with only the import ID" do
    user = user_fixture()
    attrs = %{api_url: "https://monica.test", api_key_encrypted: "test-key"}

    assert {:ok, import} = Imports.schedule_monica_import(Scope.for_user(user), attrs)

    assert {:error, :import_in_progress} =
             Imports.schedule_monica_import(Scope.for_user(user), attrs)

    args = %{"import_id" => import.id}
    assert [crawl] = all_enqueued(worker: MonicaApiCrawlWorker, args: args)
    assert [sweep] = all_enqueued(worker: ImportApiKeySweepWorker)
    assert sweep.args == args
    assert sweep.state == "scheduled"
    assert DateTime.diff(sweep.scheduled_at, crawl.scheduled_at) == @grace

    assert {:ok, _} = ImportApiKeySweepWorker.schedule(import.id, crawl.scheduled_at)
    assert [_] = all_enqueued(worker: ImportApiKeySweepWorker)
  end

  test "a file import does not get a key sweep" do
    user = user_fixture()
    import_fixture(user.account_id, user.id)
    refute_enqueued(worker: ImportApiKeySweepWorker)
  end

  test "rolling back the import rolls back both jobs" do
    user = user_fixture()
    attrs = %{api_url: "https://monica.test", api_key_encrypted: "test-key"}

    assert {:error, :rollback} =
             Repo.transact(fn ->
               assert {:ok, _} = Imports.schedule_monica_import(Scope.for_user(user), attrs)
               {:error, :rollback}
             end)

    assert Imports.get_active_import(user.account_id) == nil
    refute_enqueued(worker: MonicaApiCrawlWorker)
    refute_enqueued(worker: ImportApiKeySweepWorker)
  end

  test "snoozes for old imports with pending work from any credential consumer" do
    import = monica_import!()

    set_import_times!(import,
      completed_at: hours_ago(48),
      api_key_cleanup_eligible_at: hours_ago(1)
    )

    for {worker, state} <- [
          {MonicaApiCrawlWorker, "retryable"},
          {MonicaDocumentImportWorker, "executing"},
          {MonicaMiscDataWorker, "scheduled"},
          {MonicaPhotoSyncWorker, "available"}
        ] do
      job = insert_job!(worker, import, state)
      assert {:snooze, seconds} = sweep(import)
      assert seconds > 0
      assert Imports.get_import!(import.id).api_key_encrypted == "test-key"
      set_job_state!(job, "completed")
    end

    assert {:snooze, @grace} = sweep(import)
  end

  test "starts grace after quiescence and wipes only the requested key" do
    import = monica_import!()
    other = monica_import!()
    insert_job!(MonicaApiCrawlWorker, other, "executing")
    set_import_times!(import, updated_at: hours_ago(48))

    assert {:snooze, @grace} = sweep(import)
    assert Imports.get_import!(import.id).api_key_encrypted == "test-key"

    set_import_times!(import, api_key_cleanup_eligible_at: hours_ago(1))
    assert :ok = sweep(import)
    assert :ok = sweep(import)
    assert Imports.get_import!(import.id).api_key_encrypted == nil
    assert Imports.get_import!(other.id).api_key_encrypted == "test-key"
  end

  test "release waits for a completed import's crawl to finish enqueuing follow-ups" do
    import = monica_import!()
    {:ok, _} = Imports.update_import_status(import, "completed", %{completed_at: hours_ago(1)})
    crawl = insert_job!(MonicaApiCrawlWorker, import, "executing")
    args = %{"import_id" => import.id}

    assert {:snooze, _} = perform_job(MonicaApiKeyReleaseWorker, args)
    assert {:ok, followup} = Imports.enqueue_monica_followup(MonicaPhotoSyncWorker, args)
    set_job_state!(crawl, "completed")
    assert {:snooze, _} = perform_job(MonicaApiKeyReleaseWorker, args)

    set_job_state!(followup, "completed")
    assert :ok = perform_job(MonicaApiKeyReleaseWorker, args)
    assert Imports.get_import!(import.id).api_key_encrypted == nil
  end

  test "keeps the key after cancellation while a started worker may still be stopping" do
    import = monica_import!()
    job = insert_job!(MonicaDocumentImportWorker, import, "executing")

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [attempted_at: hours_ago(1)]
    )

    assert :ok = Oban.cancel_job(job.id)

    args = %{"import_id" => import.id}
    assert {:snooze, _} = perform_job(MonicaApiKeyReleaseWorker, args)
    assert {:snooze, _} = sweep(import)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [cancelled_at: hours_ago(1)]
    )

    assert :ok = perform_job(MonicaApiKeyReleaseWorker, args)
    assert Imports.get_import!(import.id).api_key_encrypted == nil
  end

  test "resumed work resets grace even when it finishes between sweep runs" do
    import = monica_import!()
    job = insert_job!(MonicaApiCrawlWorker, import, "completed")
    assert {:snooze, @grace} = sweep(import)
    set_import_times!(import, api_key_cleanup_eligible_at: hours_ago(1))

    assert :ok = Oban.retry_job(job.id)
    assert Imports.load_monica_import_for_job!(import.id).api_key_encrypted == "test-key"
    set_job_state!(job, "completed")

    assert {:snooze, @grace} = sweep(import)
    assert Imports.get_import!(import.id).api_key_encrypted == "test-key"
  end

  test "rejects new follow-ups once the key has been wiped" do
    import = monica_import!()
    crawl = insert_job!(MonicaApiCrawlWorker, import, "completed")
    set_import_times!(import, api_key_cleanup_eligible_at: hours_ago(1))
    assert :ok = sweep(import)

    assert {:error, :api_key_unavailable} =
             Imports.enqueue_monica_followup(MonicaPhotoSyncWorker, %{"import_id" => import.id})

    refute_enqueued(worker: MonicaPhotoSyncWorker)

    assert :ok = Oban.retry_job(crawl.id)

    assert {:cancel, :api_key_missing} =
             perform_job(MonicaApiCrawlWorker, %{import_id: import.id})
  end

  test "missing imports and legacy cron jobs are no-ops" do
    import = monica_import!()
    set_import_times!(import, completed_at: hours_ago(48))

    assert :ok = perform_job(ImportApiKeySweepWorker, %{})
    assert :ok = perform_job(ImportApiKeySweepWorker, %{"import_id" => -1})
    assert Imports.get_import!(import.id).api_key_encrypted == "test-key"
  end

  test "is absent from the Oban crontab" do
    {Oban.Plugins.Cron, opts} =
      Application.fetch_env!(:kith, Oban)
      |> Keyword.fetch!(:plugins)
      |> List.keyfind(Oban.Plugins.Cron, 0)

    refute List.keymember?(opts[:crontab], ImportApiKeySweepWorker, 1)
  end

  defp monica_import! do
    user = user_fixture()

    import_fixture(user.account_id, user.id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key"
    })
  end

  defp sweep(import), do: perform_job(ImportApiKeySweepWorker, %{"import_id" => import.id})

  defp insert_job!(worker, import, state) do
    {:ok, job} = Oban.insert(worker.new(%{import_id: import.id}))
    set_job_state!(job, state)
    job
  end

  defp set_job_state!(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end

  defp set_import_times!(import, fields) do
    Repo.update_all(from(i in Import, where: i.id == ^import.id), set: fields)
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(:second), -hours, :hour)
end
