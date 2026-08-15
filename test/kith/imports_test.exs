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

  describe "encrypt_credential/1 and decrypt_credential/1" do
    test "round-trips a plaintext secret" do
      ciphertext = Imports.encrypt_credential("super-secret-api-key")

      assert Imports.decrypt_credential(ciphertext) == "super-secret-api-key"
    end

    test "ciphertext does not contain the plaintext secret" do
      ciphertext = Imports.encrypt_credential("super-secret-api-key")

      refute ciphertext =~ "super-secret-api-key"
    end

    test "ciphertext is a JSON-safe string suitable for Oban job args" do
      ciphertext = Imports.encrypt_credential("super-secret-api-key")

      assert is_binary(ciphertext)
      assert {:ok, _} = Jason.encode(%{"credential_api_key" => ciphertext})
    end
  end
end
