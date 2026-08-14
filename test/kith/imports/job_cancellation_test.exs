defmodule Kith.Imports.JobCancellationTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports.JobCancellation
  alias Kith.Repo
  alias Kith.Workers.{DuplicateDetectionWorker, ImportWorker, MonicaPhotoSyncWorker}

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()

    target_import =
      import_fixture(target.account_id, target.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    other_import =
      import_fixture(other.account_id, other.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "k"
      })

    %{
      target_account: target.account_id,
      target_import: target_import,
      other_account: other.account_id,
      other_import: other_import
    }
  end

  test "cancels target account's import jobs; leaves other account's jobs alone", ctx do
    {:ok, target_photo_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.target_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    {:ok, other_photo_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.other_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, target_photo_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_photo_job.id).state == "available"
  end

  test "cancels DuplicateDetectionWorker jobs by account_id", ctx do
    {:ok, target_dup_job} =
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: ctx.target_account}))

    {:ok, other_dup_job} =
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: ctx.other_account}))

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, target_dup_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_dup_job.id).state == "available"
  end

  test "cancels ImportWorker jobs by account_id", ctx do
    {:ok, target_job} =
      Oban.insert(
        ImportWorker.new(%{
          "account_id" => ctx.target_account,
          "user_id" => 1,
          "file_data" => "BEGIN:VCARD\nEND:VCARD\n"
        })
      )

    {:ok, other_job} =
      Oban.insert(
        ImportWorker.new(%{
          "account_id" => ctx.other_account,
          "user_id" => 1,
          "file_data" => "BEGIN:VCARD\nEND:VCARD\n"
        })
      )

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, target_job.id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_job.id).state == "available"
  end

  test "is a no-op when account has no jobs", ctx do
    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)
  end

  test "ignores jobs already in 'completed' state", ctx do
    {:ok, completed_job} =
      Oban.insert(
        MonicaPhotoSyncWorker.new(%{
          "import_id" => ctx.target_import.id,
          "credential_url" => "x",
          "credential_api_key" => "y"
        })
      )

    # Manually mark as completed
    completed_job
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert :ok = JobCancellation.wipe_for_account(ctx.target_account)

    # Completed jobs are NOT touched
    assert Repo.get!(Oban.Job, completed_job.id).state == "completed"
  end
end
