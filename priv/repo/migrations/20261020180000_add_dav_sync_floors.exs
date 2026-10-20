defmodule Kith.Repo.Migrations.AddDavSyncFloors do
  use Ecto.Migration

  # R3 / CDV-48: a hard-deleted contact leaves nothing a sync token could report
  # as removed, so every hard delete (hard_delete_contact, empty_trash, the purge
  # worker, account cleanup, raw SQL) records a per-account "floor": a fresh
  # revision and the deleting transaction. A sync token issued before the floor
  # (older revision, or a snapshot that did not see the deleting transaction) is
  # refused with 403 valid-sync-token, and the client does a full resync.
  # No foreign key: the trigger also fires while an account is being deleted.
  def up do
    create table(:dav_sync_floors, primary_key: false) do
      add :account_id, :bigint, primary_key: true
      add :revision, :bigint, null: false
    end

    execute "ALTER TABLE dav_sync_floors ADD COLUMN xid xid8 NOT NULL"

    execute """
    CREATE FUNCTION contacts_record_dav_sync_floor() RETURNS trigger AS $$
    BEGIN
      INSERT INTO dav_sync_floors (account_id, revision, xid)
      SELECT account_id, nextval('contacts_dav_revision_seq'), pg_current_xact_id()
      FROM (SELECT DISTINCT account_id FROM deleted_contacts) AS accounts
      ON CONFLICT (account_id)
      DO UPDATE SET revision = EXCLUDED.revision, xid = EXCLUDED.xid;
      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER contacts_record_dav_sync_floor
    AFTER DELETE ON contacts
    REFERENCING OLD TABLE AS deleted_contacts
    FOR EACH STATEMENT EXECUTE FUNCTION contacts_record_dav_sync_floor()
    """
  end

  def down do
    execute "DROP TRIGGER contacts_record_dav_sync_floor ON contacts"
    execute "DROP FUNCTION contacts_record_dav_sync_floor()"
    drop table(:dav_sync_floors)
  end
end
