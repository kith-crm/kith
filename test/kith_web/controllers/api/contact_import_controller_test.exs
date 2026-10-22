defmodule KithWeb.API.ContactImportControllerTest do
  use KithWeb.ConnCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures

  alias Kith.Accounts

  test "one non-UTF-8 card does not reject the rest of the import", %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)

    card = fn name ->
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};Rest;;;\r\nFN:Rest #{name}\r\nEND:VCARD\r\n"
    end

    dir = Path.join(System.tmp_dir!(), "vcard-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "mixed.vcf")
    File.write!(path, card.("Zoë") <> card.(<<"Zo", 0xEB>>) <> card.("Ünal"))

    upload = %Plug.Upload{path: path, filename: "mixed.vcf", content_type: "text/vcard"}

    body =
      conn
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> post(~p"/api/contacts/import", %{"file" => upload})
      |> json_response(200)

    assert body["imported"] == 2
    assert body["skipped"] == 1
    assert [error] = body["errors"]
    assert error =~ "Entry 2"
    assert error =~ "UTF-8"
  end

  test "large mixed-encoding uploads enqueue and import every valid card", %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)

    card = fn name ->
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};Queued;;;\r\nFN:Queued #{name}\r\nEND:VCARD\r\n"
    end

    data =
      card.("First") <> card.(<<"Bad", 0xEB>>) <> Enum.map_join(3..101, &card.("Contact #{&1}"))

    path = Path.join(System.tmp_dir!(), "async-vcard-#{System.unique_integer([:positive])}.vcf")
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "mixed.vcf", content_type: "text/vcard"}
    Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{user.account_id}")

    body =
      conn
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> post(~p"/api/contacts/import", %{"file" => upload})
      |> json_response(202)

    assert body["total"] == 101
    assert [job] = all_enqueued(worker: Kith.Workers.ImportWorker)
    assert :ok = perform_job(Kith.Workers.ImportWorker, job.args)
    assert_receive {:import_complete, %{imported: 100, skipped: 1, errors: [error]}}
    assert error =~ "Entry 2"
    assert error =~ "UTF-8"
    assert Kith.Contacts.count_contacts(user.account_id) == 100
  end
end
