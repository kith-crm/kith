defmodule Kith.Repo.Migrations.AddContactDavChanges do
  use Ecto.Migration

  # CDV-53: a commit-ordered change log for CardDAV. `dav_revision` is drawn
  # when a row is written, so a transaction that writes first but commits last
  # carries the older revision. This deferred trigger runs at COMMIT, takes a
  # per-account advisory lock (held until the commit completes) and only then
  # draws `dav_change_seq`: within an account, `seq` order is commit order.
  # Every write (Ecto, update_all, imports, raw SQL) and every hard delete of a
  # contact is logged; a hard delete moves the account's floor.
  def up do
    execute "CREATE SEQUENCE dav_change_seq"

    create table(:contact_dav_changes, primary_key: false) do
      add :contact_id, :bigint, primary_key: true
      add :account_id, :bigint, null: false
      add :seq, :bigint, null: false
    end

    create index(:contact_dav_changes, [:account_id, :seq])

    alter table(:dav_sync_floors) do
      add :seq, :bigint
    end

    execute """
    INSERT INTO contact_dav_changes (contact_id, account_id, seq)
    SELECT id, account_id, nextval('dav_change_seq') FROM contacts ORDER BY dav_revision
    """

    execute "UPDATE dav_sync_floors SET seq = nextval('dav_change_seq')"

    execute """
    CREATE FUNCTION contacts_log_dav_change() RETURNS trigger AS $$
    DECLARE
      account bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.account_id ELSE NEW.account_id END;
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('kith-dav-change', account));

      IF TG_OP = 'DELETE' THEN
        DELETE FROM contact_dav_changes WHERE contact_id = OLD.id;

        INSERT INTO dav_sync_floors (account_id, revision, xid, seq)
        VALUES (account, nextval('contacts_dav_revision_seq'), pg_current_xact_id(), nextval('dav_change_seq'))
        ON CONFLICT (account_id)
        DO UPDATE SET revision = EXCLUDED.revision, xid = EXCLUDED.xid, seq = EXCLUDED.seq;
      ELSE
        INSERT INTO contact_dav_changes (contact_id, account_id, seq)
        VALUES (NEW.id, account, nextval('dav_change_seq'))
        ON CONFLICT (contact_id)
        DO UPDATE SET account_id = EXCLUDED.account_id, seq = EXCLUDED.seq;
      END IF;

      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE CONSTRAINT TRIGGER contacts_log_dav_change
    AFTER INSERT OR UPDATE OR DELETE ON contacts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION contacts_log_dav_change()
    """
  end

  def down do
    execute "DROP TRIGGER contacts_log_dav_change ON contacts"
    execute "DROP FUNCTION contacts_log_dav_change()"

    alter table(:dav_sync_floors) do
      remove :seq
    end

    drop table(:contact_dav_changes)
    execute "DROP SEQUENCE dav_change_seq"
  end
end
