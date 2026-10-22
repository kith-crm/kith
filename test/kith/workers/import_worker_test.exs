defmodule Kith.Workers.ImportWorkerTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Workers.ImportWorker

  def mixed_file do
    card = fn name ->
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};Async;;;\r\nFN:Async #{name}\r\nEND:VCARD\r\n"
    end

    card.("First") <>
      card.(<<"Bad", 0xEB>>) <>
      Enum.map_join(3..101, &card.("Contact #{&1}"))
  end

  test "shared API and LiveView enqueue transport retains malformed card bytes and indexing" do
    user = user_fixture()
    data = mixed_file()
    Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{user.account_id}")

    assert {:ok, _} = ImportWorker.enqueue_file(user.account_id, user.id, data)
    assert [job] = all_enqueued(worker: ImportWorker)
    assert Jason.encode!(job.args)
    assert Base.decode64!(job.args["file_data_base64"]) == data
    assert :ok = perform_job(ImportWorker, job.args)
    assert_receive {:import_complete, %{imported: 100, skipped: 1, errors: [error]}}
    assert error =~ "Entry 2"
    assert error =~ "UTF-8"
    assert Kith.Contacts.count_contacts(user.account_id) == 100
  end

  test "invalid base64 returns a worker error" do
    user = user_fixture()

    assert {:error, _} =
             perform_job(ImportWorker, %{
               account_id: user.account_id,
               user_id: user.id,
               file_data_base64: "!invalid"
             })
  end

  test "existing UTF-8 file_data jobs still run" do
    user = user_fixture()

    assert :ok =
             perform_job(ImportWorker, %{
               account_id: user.account_id,
               user_id: user.id,
               file_data: "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Existing;Job;;;\r\nEND:VCARD\r\n"
             })

    assert Kith.Contacts.count_contacts(user.account_id) == 1
  end
end
