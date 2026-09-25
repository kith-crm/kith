defmodule Kith.ImportsTest do
  use Kith.DataCase, async: true

  alias Kith.Imports
  alias Kith.Imports.{Import, ImportRecord}

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    user = user_fixture()
    %{user: user, account_id: user.account_id}
  end

  describe "create_import/3" do
    test "creates an import with valid attrs", %{account_id: account_id, user: user} do
      attrs = %{source: "vcard", file_name: "export.vcf", file_size: 1024}
      assert {:ok, %Import{} = import} = Imports.create_import(account_id, user.id, attrs)
      assert import.source == "vcard"
      assert import.status == "pending"
      assert import.account_id == account_id
    end

    test "rejects concurrent imports for same account", %{account_id: account_id, user: user} do
      attrs = %{source: "vcard", file_name: "export.vcf", file_size: 1024}
      {:ok, _} = Imports.create_import(account_id, user.id, attrs)
      assert {:error, :import_in_progress} = Imports.create_import(account_id, user.id, attrs)
    end
  end

  describe "resolve_source/1" do
    test "resolves monica_api" do
      assert Imports.resolve_source("monica_api") == {:ok, Kith.Imports.Sources.MonicaApi}
    end

    test "resolves vcard" do
      assert Imports.resolve_source("vcard") == {:ok, Kith.Imports.Sources.VCard}
    end

    test "rejects unknown source" do
      assert Imports.resolve_source("unknown") == {:error, :unknown_source}
    end
  end

  describe "record_imported_entity/5" do
    test "creates a new import record", %{account_id: account_id, user: user} do
      {:ok, import} = Imports.create_import(account_id, user.id, %{source: "vcard"})
      contact = contact_fixture(account_id)

      assert {:ok, %ImportRecord{}} =
               Imports.record_imported_entity(
                 import,
                 "contact",
                 "uuid-123",
                 "contact",
                 contact.id
               )
    end

    test "upserts on re-import (updates import_id)", %{account_id: account_id, user: user} do
      {:ok, import1} = Imports.create_import(account_id, user.id, %{source: "vcard"})
      contact = contact_fixture(account_id)

      {:ok, rec1} =
        Imports.record_imported_entity(import1, "contact", "uuid-123", "contact", contact.id)

      # Complete first import so we can create a second
      Imports.update_import_status(import1, "completed", %{completed_at: DateTime.utc_now()})

      {:ok, import2} = Imports.create_import(account_id, user.id, %{source: "vcard"})

      {:ok, rec2} =
        Imports.record_imported_entity(import2, "contact", "uuid-123", "contact", contact.id)

      assert rec2.id == rec1.id
      assert rec2.import_id == import2.id
    end
  end

  describe "find_import_record/4" do
    test "finds existing record", %{account_id: account_id, user: user} do
      {:ok, import} = Imports.create_import(account_id, user.id, %{source: "vcard"})
      contact = contact_fixture(account_id)
      Imports.record_imported_entity(import, "contact", "uuid-123", "contact", contact.id)

      assert %ImportRecord{} =
               Imports.find_import_record(account_id, "vcard", "contact", "uuid-123")
    end

    test "returns nil for nonexistent", %{account_id: account_id} do
      assert is_nil(Imports.find_import_record(account_id, "vcard", "contact", "missing"))
    end
  end

  describe "update_import_status/3" do
    test "updates status and optional fields", %{account_id: account_id, user: user} do
      {:ok, import} = Imports.create_import(account_id, user.id, %{source: "vcard"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} = Imports.update_import_status(import, "processing", %{started_at: now})
      assert updated.status == "processing"
      assert updated.started_at == now
    end
  end

  describe "monica_followups_pending?/1" do
    setup %{account_id: account_id, user: user} do
      {:ok, import} =
        Imports.create_import(account_id, user.id, %{
          source: "monica_api",
          api_url: "https://monica.test",
          api_key_encrypted: "test-key"
        })

      %{import: import}
    end

    test "is false when no follow-up job exists", %{import: import} do
      refute Imports.monica_followups_pending?(import.id)
    end

    for state <- ~w[available scheduled executing retryable] do
      test "is true while a follow-up job is #{state}", %{import: import} do
        insert_job!(
          Kith.Workers.MonicaPhotoSyncWorker,
          %{"import_id" => import.id},
          unquote(state)
        )

        assert Imports.monica_followups_pending?(import.id)
      end
    end

    for state <- ~w[completed discarded cancelled] do
      test "is false once every follow-up job is #{state}", %{import: import} do
        insert_job!(
          Kith.Workers.MonicaPhotoSyncWorker,
          %{"import_id" => import.id},
          unquote(state)
        )

        insert_job!(
          Kith.Workers.MonicaDocumentImportWorker,
          %{"import_id" => import.id},
          unquote(state)
        )

        refute Imports.monica_followups_pending?(import.id)
      end
    end

    test "counts misc-data and document jobs, not just photo sync", %{import: import} do
      misc = insert_job!(Kith.Workers.MonicaMiscDataWorker, %{"import_id" => import.id})
      assert Imports.monica_followups_pending?(import.id)

      set_job_state!(misc, "completed")
      insert_job!(Kith.Workers.MonicaDocumentImportWorker, %{"import_id" => import.id})
      assert Imports.monica_followups_pending?(import.id)
    end

    test "ignores other imports' jobs and non-follow-up workers", %{import: import} do
      insert_job!(Kith.Workers.MonicaPhotoSyncWorker, %{"import_id" => import.id + 1_000_000})
      insert_job!(Kith.Workers.MonicaApiCrawlWorker, %{"import_id" => import.id})

      refute Imports.monica_followups_pending?(import.id)
    end
  end

  describe "wipe_stale_api_keys/1" do
    @day 24 * 60 * 60

    test "wipes keys of imports that finished longer ago than max age",
         %{account_id: account_id, user: user} do
      import = key_import!(account_id, user.id)
      backdate!(import, completed_at: hours_ago(25))

      assert Imports.wipe_stale_api_keys(@day) == 1
      assert is_nil(Imports.get_import!(import.id).api_key_encrypted)
    end

    test "keeps keys of recently finished imports", %{account_id: account_id, user: user} do
      import = key_import!(account_id, user.id)
      backdate!(import, completed_at: hours_ago(1), updated_at: hours_ago(30))

      assert Imports.wipe_stale_api_keys(@day) == 0
      assert Imports.get_import!(import.id).api_key_encrypted == "test-key"
    end

    test "wipes imports that never finished once untouched past max age",
         %{account_id: account_id, user: user} do
      import = key_import!(account_id, user.id)
      backdate!(import, updated_at: hours_ago(25))

      assert Imports.wipe_stale_api_keys(@day) == 1
      assert is_nil(Imports.get_import!(import.id).api_key_encrypted)
    end
  end

  defp key_import!(account_id, user_id) do
    {:ok, import} =
      Imports.create_import(account_id, user_id, %{
        source: "monica_api",
        api_url: "https://monica.test",
        api_key_encrypted: "test-key"
      })

    import
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp backdate!(import, fields) do
    Repo.update_all(from(i in Import, where: i.id == ^import.id), set: fields)
  end

  defp insert_job!(worker, args, state \\ "available") do
    {:ok, job} = args |> worker.new() |> Oban.insert()
    set_job_state!(job, state)
  end

  defp set_job_state!(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    job
  end
end
