defmodule Kith.Repo.Migrations.CreateContactDav do
  use Ecto.Migration

  def up do
    execute "CREATE SEQUENCE contact_dav_revision_seq"

    create table(:contact_dav, primary_key: false) do
      add :contact_id, references(:contacts, on_delete: :delete_all), primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :uid, :text, null: false
      add :resource_name, :text, null: false

      add :revision, :bigint,
        null: false,
        default: fragment("nextval('contact_dav_revision_seq')")

      add :extras, {:array, :text}, null: false, default: []
    end

    create unique_index(:contact_dav, [:account_id, :uid])
    create unique_index(:contact_dav, [:account_id, :resource_name])
    create index(:contact_dav, [:account_id, :revision])

    create table(:dav_sync_floors, primary_key: false) do
      add :account_id, references(:accounts, on_delete: :delete_all), primary_key: true
      add :revision, :bigint, null: false
    end

    execute """
    INSERT INTO contact_dav (contact_id, account_id, uid, resource_name, revision)
    SELECT id, account_id, uid, uid || '.vcf',
           nextval('contact_dav_revision_seq')
    FROM (SELECT id, account_id, gen_random_uuid()::text AS uid FROM contacts OFFSET 0) identities
    ORDER BY id
    """
  end

  def down do
    drop table(:dav_sync_floors)
    drop table(:contact_dav)
    execute "DROP SEQUENCE contact_dav_revision_seq"
  end
end
