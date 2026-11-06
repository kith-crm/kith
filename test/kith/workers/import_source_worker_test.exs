defmodule Kith.Workers.ImportSourceWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Workers.ImportSourceWorker
  alias Kith.Imports

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  describe "perform/1" do
    test "processes a vcard import", %{account_id: account_id, user: user} do
      vcf_data = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nEND:VCARD\r\n"
      storage_key = "imports/test/export.vcf"
      {:ok, _} = Kith.Storage.upload_binary(vcf_data, storage_key)

      import_job =
        import_fixture(account_id, user.id, %{
          source: "vcard",
          file_name: "export.vcf",
          file_storage_key: storage_key
        })

      assert :ok = perform_job(ImportSourceWorker, %{import_id: import_job.id})

      updated = Imports.get_import!(import_job.id)
      assert updated.status == "completed"
      assert updated.summary["contacts"] >= 1
    end

    @tag :capture_log
    test "marks import as failed on file not found", %{account_id: account_id, user: user} do
      import_job =
        import_fixture(account_id, user.id, %{
          source: "vcard",
          file_name: "export.vcf",
          file_storage_key: "nonexistent/path.vcf"
        })

      assert {:error, _} = perform_job(ImportSourceWorker, %{import_id: import_job.id})

      updated = Imports.get_import!(import_job.id)
      assert updated.status == "failed"
    end
  end
end
