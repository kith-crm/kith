defmodule Kith.Workers.MonicaPhotoSyncWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Repo
  alias Kith.Workers.MonicaPhotoSyncWorker

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures
  import Kith.MonicaApiFixtures

  @stub_name :monica_photo_sync_stub
  @pixel_data_url "data:image/jpeg;base64,#{Base.encode64(<<0xFF, 0xD8, 0xFF, 0xE0>>)}"
  @other_pixel_data_url "data:image/png;base64,#{Base.encode64(<<0x89, 0x50, 0x4E, 0x47>>)}"

  setup do
    user = user_fixture()
    seed_reference_data!()

    Application.put_env(
      :kith,
      :monica_req_options,
      plug: {Req.Test, @stub_name},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:kith, :monica_req_options) end)

    %{user: user, account_id: user.account_id}
  end

  defp api_import_fixture(account_id, user_id) do
    import_fixture(account_id, user_id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key",
      api_options: %{"photos" => true}
    })
  end

  defp job_args(import_job),
    do: %{
      "import_id" => import_job.id,
      "credential_url" => "https://monica.test",
      "credential_api_key" => "test-key"
    }

  defp register_imported_contact!(import_job, contact, monica_id) do
    {:ok, _rec} =
      Imports.record_imported_entity(
        import_job,
        "contact",
        to_string(monica_id),
        "contact",
        contact.id
      )
  end

  describe "perform/1 — happy path" do
    test "imports photo with dataUrl, sets avatar, writes sync_summary", %{
      user: user,
      account_id: account_id
    } do
      import_job = api_import_fixture(account_id, user.id)
      contact = contact_fixture(account_id, %{first_name: "PhotoPerson"})
      register_imported_contact!(import_job, contact, 964)

      photo =
        photo_json(
          id: 35,
          data_url: @pixel_data_url,
          contact: contact_short_json(964, Ecto.UUID.generate(), "PhotoPerson", "Test")
        )

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, photos_page_json([photo]))
      end)

      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))

      assert [photo_row] = Contacts.list_photos(contact.id)
      assert photo_row.contact_id == contact.id
      assert photo_row.content_hash != nil

      reloaded_contact = Repo.get!(Contacts.Contact, contact.id)
      assert reloaded_contact.avatar == photo_row.storage_key

      updated = Imports.get_import!(import_job.id)
      assert updated.sync_summary["total"] == 1
      assert updated.sync_summary["synced"] == 1
      assert updated.sync_summary["failed"] == 0
      assert updated.sync_summary["not_found"] == 0
      assert [%{"status" => "synced", "contact_id" => cid}] = updated.sync_summary["photos"]
      assert cid == contact.id
    end
  end

  describe "perform/1 — not_found" do
    test "marks photo as not_found when contact has no import_record", %{
      user: user,
      account_id: account_id
    } do
      import_job = api_import_fixture(account_id, user.id)

      photo =
        photo_json(
          id: 100,
          data_url: @pixel_data_url,
          contact: contact_short_json(9999, Ecto.UUID.generate(), "Unknown", "Person")
        )

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, photos_page_json([photo]))
      end)

      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))

      assert Repo.aggregate(Contacts.Photo, :count, :id) == 0

      updated = Imports.get_import!(import_job.id)
      assert updated.sync_summary["not_found"] == 1
      assert updated.sync_summary["synced"] == 0
      assert [%{"status" => "not_found", "reason" => reason}] = updated.sync_summary["photos"]
      assert reason =~ "import_records"
    end
  end

  describe "perform/1 — failed" do
    test "marks photo as failed when dataUrl is missing", %{user: user, account_id: account_id} do
      import_job = api_import_fixture(account_id, user.id)
      contact = contact_fixture(account_id, %{first_name: "NoData"})
      register_imported_contact!(import_job, contact, 200)

      photo =
        photo_json(
          id: 200,
          data_url: nil,
          link: nil,
          contact: contact_short_json(200, Ecto.UUID.generate(), "NoData", "Person")
        )

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, photos_page_json([photo]))
      end)

      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))

      assert Contacts.list_photos(contact.id) == []

      updated = Imports.get_import!(import_job.id)
      assert updated.sync_summary["failed"] == 1
      assert [%{"status" => "failed", "reason" => "no_data_url"}] = updated.sync_summary["photos"]
    end
  end

  describe "perform/1 — dedup" do
    test "dedups by content_hash on second run, still counts as synced", %{
      user: user,
      account_id: account_id
    } do
      import_job = api_import_fixture(account_id, user.id)
      contact = contact_fixture(account_id, %{first_name: "Dup"})
      register_imported_contact!(import_job, contact, 300)

      photo =
        photo_json(
          id: 300,
          data_url: @pixel_data_url,
          contact: contact_short_json(300, Ecto.UUID.generate(), "Dup", "Person")
        )

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, photos_page_json([photo]))
      end)

      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))
      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))

      assert [_only_one] = Contacts.list_photos(contact.id)

      updated = Imports.get_import!(import_job.id)
      assert updated.sync_summary["synced"] == 1
      assert updated.sync_summary["total"] == 1
      [entry] = updated.sync_summary["photos"]
      assert entry["status"] == "synced"
      assert entry["reason"] == "duplicate"
    end
  end

  describe "perform/1 — incremental progress" do
    test "writes sync_summary after each page", %{user: user, account_id: account_id} do
      import_job = api_import_fixture(account_id, user.id)
      contact_a = contact_fixture(account_id, %{first_name: "PageA"})
      contact_b = contact_fixture(account_id, %{first_name: "PageB"})
      register_imported_contact!(import_job, contact_a, 401)
      register_imported_contact!(import_job, contact_b, 402)

      page1_photo =
        photo_json(
          id: 401,
          data_url: @pixel_data_url,
          contact: contact_short_json(401, Ecto.UUID.generate(), "PageA", "Test")
        )

      page2_photo =
        photo_json(
          id: 402,
          data_url: @other_pixel_data_url,
          contact: contact_short_json(402, Ecto.UUID.generate(), "PageB", "Test")
        )

      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        page = conn.query_params["page"] || "1"

        case page do
          "1" ->
            # Mid-flight snapshot: by the time we serve page 2, page 1 must have been
            # persisted to sync_summary.
            send(test_pid, :page_1_requested)
            Req.Test.json(conn, photos_page_json([page1_photo], 1, 2, 2))

          "2" ->
            updated = Imports.get_import!(import_job.id)
            send(test_pid, {:mid_flight_summary, updated.sync_summary})
            Req.Test.json(conn, photos_page_json([page2_photo], 2, 2, 2))
        end
      end)

      assert :ok = perform_job(MonicaPhotoSyncWorker, job_args(import_job))

      assert_received :page_1_requested
      assert_received {:mid_flight_summary, mid}
      # After page 1 completes, exactly one photo should be recorded.
      assert mid["total"] == 1
      assert mid["synced"] == 1

      final = Imports.get_import!(import_job.id)
      assert final.sync_summary["total"] == 2
      assert final.sync_summary["synced"] == 2
    end
  end
end
