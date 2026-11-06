defmodule Kith.DAV.AuditLegacyTest do
  use Kith.DataCase, async: false

  alias Kith.DAV.Audit

  test "legacy audit reports candidates without classifying, deleting or changing schema" do
    # Connection-local tables model the pre-classification schema. The real
    # application schema and migration bookkeeping remain untouched.
    Repo.query!(
      "CREATE TEMP TABLE contact_field_types (id bigint PRIMARY KEY, account_id bigint, name text, protocol text, vcard_label text) ON COMMIT DROP"
    )

    Repo.query!(
      "CREATE TEMP TABLE contact_fields (id bigint PRIMARY KEY, account_id bigint, contact_id bigint, contact_field_type_id bigint, value text, label text) ON COMMIT DROP"
    )

    Repo.query!(
      "INSERT INTO contact_field_types VALUES (1, NULL, 'Email', 'mailto:', 'EMAIL'), (2, 42, 'Private custom', NULL, 'EMAIL'), (3, 42, 'Private plain', NULL, NULL)"
    )

    Repo.query!(
      "INSERT INTO contact_fields VALUES (10, 42, 100, 1, 'same@example.com', NULL), (11, 42, 100, 1, 'same@example.com', NULL), (12, 42, 100, 2, 'private@example.com', NULL), (13, 42, 100, 3, 'private plain value', NULL), (14, 999, 200, 1, 'same@example.com', NULL)"
    )

    before_fields = Repo.query!("SELECT * FROM contact_fields ORDER BY id").rows
    before_types = Repo.query!("SELECT * FROM contact_field_types ORDER BY id").rows

    report = Audit.report(42)
    assert report.schema_state == :legacy
    assert report.account_id == 42
    assert [%{contact_id: 100, field_ids: ids}] = report.duplicate_candidates
    assert Enum.sort(ids) == [10, 11]
    assert Enum.sort(report.unclassified_field_ids) == [10, 11, 12]
    refute Map.has_key?(report, :untrusted_protocol_field_ids)
    assert Repo.query!("SELECT * FROM contact_fields ORDER BY id").rows == before_fields
    assert Repo.query!("SELECT * FROM contact_field_types ORDER BY id").rows == before_types

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('contact_field_types') AND attname = 'system_key' AND NOT attisdropped)"
             )
  end
end
