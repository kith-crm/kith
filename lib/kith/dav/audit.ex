defmodule Kith.DAV.Audit do
  @moduledoc "Read-only account-scoped migration diagnostics; never deduplicates native data."
  import Ecto.Query
  alias Kith.Contacts.{ContactField, ContactFieldType}
  alias Kith.DAV.{ContactDav, Store}
  alias Kith.Repo

  def report(account_id) do
    %{rows: [[classified?]]} =
      Repo.query!("""
      SELECT EXISTS (SELECT 1 FROM pg_attribute
        WHERE attrelid = to_regclass('contact_field_types') AND attname = 'system_key' AND NOT attisdropped)
      """)

    if classified?, do: classified_report(account_id), else: legacy_report(account_id)
  end

  defp legacy_report(account_id) do
    %{rows: duplicates} =
      Repo.query!(
        """
        SELECT contact_id, array_agg(id) FROM contact_fields WHERE account_id = $1
        GROUP BY contact_id, contact_field_type_id, value, label HAVING count(*) > 1
        """,
        [account_id]
      )

    %{rows: candidates} =
      Repo.query!(
        """
        SELECT f.id FROM contact_fields f JOIN contact_field_types t ON t.id = f.contact_field_type_id
        WHERE f.account_id = $1 AND (t.protocol IS NOT NULL OR t.vcard_label IS NOT NULL)
        """,
        [account_id]
      )

    %{
      schema_state: :legacy,
      account_id: account_id,
      duplicate_candidates:
        Enum.map(duplicates, fn [id, ids] -> %{contact_id: id, field_ids: ids} end),
      unclassified_field_ids: List.flatten(candidates),
      recommendation:
        "Apply audited classification migration after reviewing candidates; no visibility is inferred here"
    }
  end

  defp classified_report(account_id) do
    duplicates =
      Repo.all(
        from f in ContactField,
          join: t in ContactFieldType,
          on: t.id == f.contact_field_type_id,
          where:
            f.account_id == ^account_id and is_nil(t.account_id) and
              t.system_key in ~w(email phone mobile work_phone fax website),
          group_by: [f.contact_id, f.contact_field_type_id, f.value, f.label],
          having: count(f.id) > 1,
          select: %{contact_id: f.contact_id, field_ids: fragment("array_agg(?)", f.id)}
      )

    %{
      account_id: account_id,
      duplicate_candidates: duplicates,
      untrusted_protocol_field_ids:
        Repo.all(
          from f in ContactField,
            join: t in ContactFieldType,
            on: t.id == f.contact_field_type_id,
            where:
              f.account_id == ^account_id and is_nil(t.system_key) and
                (not is_nil(t.protocol) or not is_nil(t.vcard_label)),
            select: f.id
        ),
      quarantined_extras_contact_ids:
        Repo.all(
          from d in ContactDav,
            where: d.account_id == ^account_id and fragment("cardinality(?) > 0", d.extras),
            select: d.contact_id
        ),
      pending_document_contact_ids:
        Repo.all(
          from d in ContactDav,
            where: d.account_id == ^account_id and is_nil(d.representation_fingerprint),
            select: d.contact_id
        )
    }
  end

  def backfill(account_id) do
    Store.ensure_rows(account_id)
    report(account_id)
  end
end
