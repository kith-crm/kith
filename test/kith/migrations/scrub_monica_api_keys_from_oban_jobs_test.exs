defmodule Kith.Migrations.ScrubMonicaApiKeysFromObanJobsTest do
  use Kith.DataCase, async: false

  alias Kith.Workers.{
    ImportWorker,
    MonicaDocumentImportWorker,
    MonicaMiscDataWorker,
    MonicaPhotoSyncWorker
  }

  @migration_path "priv/repo/migrations/20260925120000_scrub_monica_api_keys_from_oban_jobs.exs"

  # Ecto.Migrator deadlocks under the shared sandbox, so run the migration's
  # exact statement directly; the sandbox rolls it back.
  setup_all do
    [{migration, _}] = Code.require_file(@migration_path)
    %{migration: migration}
  end

  test "strips credential_api_key from Monica follow-up jobs in every state",
       %{migration: migration} do
    monica_jobs =
      for {worker, state} <- [
            {MonicaPhotoSyncWorker, "available"},
            {MonicaMiscDataWorker, "retryable"},
            {MonicaDocumentImportWorker, "scheduled"},
            {MonicaPhotoSyncWorker, "completed"},
            {MonicaMiscDataWorker, "discarded"},
            {MonicaDocumentImportWorker, "cancelled"}
          ] do
        insert_job!(worker, state, %{
          "import_id" => 42,
          "credential_url" => "https://monica.test",
          "credential_api_key" => "plaintext-key"
        })
      end

    other_job =
      insert_job!(ImportWorker, "available", %{"account_id" => 1, "credential_api_key" => "keep"})

    assert %{num_rows: 6} = Repo.query!(migration.scrub_sql())

    for job <- monica_jobs do
      args = Repo.get!(Oban.Job, job.id).args
      refute Map.has_key?(args, "credential_api_key")
      assert args["import_id"] == 42
      assert args["credential_url"] == "https://monica.test"
    end

    assert Repo.get!(Oban.Job, other_job.id).args["credential_api_key"] == "keep"
  end

  defp insert_job!(worker, state, args) do
    {:ok, job} = args |> worker.new() |> Oban.insert()
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    job
  end
end
