defmodule Kith.Repo.Migrations.CreateDavDocumentReferences do
  use Ecto.Migration

  def change do
    create table(:dav_document_references, primary_key: false) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false

      add :source_contact_id,
          references(:contact_dav, column: :contact_id, on_delete: :delete_all), null: false

      add :target_uid, :uuid, null: false
    end

    create unique_index(:dav_document_references, [:account_id, :source_contact_id, :target_uid],
             name: :dav_document_references_identity_index
           )

    create index(:dav_document_references, [:account_id, :target_uid])

    # Index both old rich maps and the compact array storage codec. This is a
    # dependency index, not a native target binding; unresolved UUIDs stay client data.
    execute """
            INSERT INTO dav_document_references (account_id, source_contact_id, target_uid)
            SELECT DISTINCT account_id, contact_id, normalized::uuid
            FROM (
              SELECT account_id, contact_id,
                lower(regexp_replace(value, '^urn:uuid:', '', 'i')) AS normalized
              FROM (
                SELECT d.account_id, d.contact_id,
                  CASE WHEN jsonb_typeof(e) = 'array' THEN e->2->>1
                    ELSE e->'property'->>'normalized_name' END AS name,
                  CASE WHEN jsonb_typeof(e) = 'array' THEN e->2->>3
                    ELSE e->'property'->>'value' END AS value
                FROM contact_dav d CROSS JOIN LATERAL
                  jsonb_array_elements(COALESCE(d.document->'properties', '[]'::jsonb)) AS e
              ) properties
              WHERE upper(name) IN ('RELATED', 'X-KITH-RELATED')
            ) identities
            WHERE normalized ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            ON CONFLICT DO NOTHING
            """,
            "SELECT 1"
  end
end
