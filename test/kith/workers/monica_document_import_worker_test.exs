defmodule Kith.Workers.MonicaDocumentImportWorkerTest do
  # async: false — tests set the global :monica_req_options app env.
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Workers.MonicaDocumentImportWorker

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  @stub_name :monica_document_import_stub

  setup do
    user = user_fixture()

    Application.put_env(
      :kith,
      :monica_req_options,
      plug: {Req.Test, @stub_name},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:kith, :monica_req_options) end)

    import_job =
      import_fixture(user.account_id, user.id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "test-key",
        api_options: %{"documents" => true}
      })

    %{user: user, import_job: import_job, contact: contact_fixture(user.account_id)}
  end

  defp job_args(user, import_job, contact) do
    %{
      "account_id" => user.account_id,
      "user_id" => user.id,
      "contact_id" => contact.id,
      "import_id" => import_job.id,
      "credential_url" => "https://monica.test",
      "documents" => [
        %{
          "id" => 501,
          "original_filename" => "contract.pdf",
          "download_url" => "https://monica.test/storage/contract.pdf"
        }
      ]
    }
  end

  test "downloads with the key from the Import row and stores the document",
       %{user: user, import_job: import_job, contact: contact} do
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

      conn
      |> Plug.Conn.put_resp_content_type("application/pdf")
      |> Plug.Conn.send_resp(200, "%PDF-1.4 fake")
    end)

    args = job_args(user, import_job, contact)
    refute Map.has_key?(args, "credential_api_key")

    assert :ok = perform_job(MonicaDocumentImportWorker, args)

    assert_received {:auth, ["Bearer test-key"]}
    assert [doc] = Contacts.list_documents(contact.id)
    assert doc.file_name == "contract.pdf"
    assert Imports.count_import_records_by_type(import_job.id, "document") == 1
  end

  test "cancels without downloading when the key has been wiped",
       %{user: user, import_job: import_job, contact: contact} do
    {:ok, _} = Imports.wipe_api_key(import_job)
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      send(test_pid, {:request, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:cancel, :api_key_wiped} =
             perform_job(MonicaDocumentImportWorker, job_args(user, import_job, contact))

    refute_received {:request, _}
    assert Contacts.list_documents(contact.id) == []
  end
end
