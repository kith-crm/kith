defmodule Kith.Repo.Migrations.SyncTokensFromChangeLog do
  use Ecto.Migration

  # CDV-54: sync tokens move from (revision, xid snapshot) to the commit-ordered
  # change log of CDV-53 plus a database "epoch". Transaction ids are not
  # portable: pg_dump copies `dav_xid` verbatim while a new cluster's counter is
  # lower (restored rows looked in-flight forever), and a point-in-time restore
  # rewinds them. Change-log `seq` values are plain data restored together with
  # their sequence, and the epoch (cluster id, timeline, database oid) changes
  # on a restore into another cluster or database and on a PITR promotion, so
  # tokens issued before it are refused with 403 valid-sync-token.
  def up do
    execute "DROP TRIGGER contacts_record_dav_sync_floor ON contacts"
    execute "DROP FUNCTION contacts_record_dav_sync_floor()"

    execute """
    CREATE OR REPLACE FUNCTION contacts_bump_dav_revision() RETURNS trigger AS $$
    BEGIN
      NEW.dav_revision := nextval('contacts_dav_revision_seq');
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute "ALTER TABLE contacts DROP COLUMN dav_xid"

    execute """
    CREATE OR REPLACE FUNCTION contacts_log_dav_change() RETURNS trigger AS $$
    DECLARE
      account bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.account_id ELSE NEW.account_id END;
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('kith-dav-change', account));

      IF TG_OP = 'DELETE' THEN
        DELETE FROM contact_dav_changes WHERE contact_id = OLD.id;

        INSERT INTO dav_sync_floors (account_id, seq)
        VALUES (account, nextval('dav_change_seq'))
        ON CONFLICT (account_id) DO UPDATE SET seq = EXCLUDED.seq;
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

    execute "UPDATE dav_sync_floors SET seq = nextval('dav_change_seq') WHERE seq IS NULL"
    execute "ALTER TABLE dav_sync_floors DROP COLUMN revision, DROP COLUMN xid"
    execute "ALTER TABLE dav_sync_floors ALTER COLUMN seq SET NOT NULL"

    # pg_control_* needs superuser or pg_read_all_settings-like rights on some
    # hosts; without them the epoch falls back to the database oid alone.
    execute """
    CREATE FUNCTION kith_dav_sync_epoch() RETURNS text AS $$
    DECLARE
      cluster text;
    BEGIN
      BEGIN
        SELECT s.system_identifier::text || '.' || c.timeline_id::text
        INTO cluster
        FROM pg_control_system() s, pg_control_checkpoint() c;
      EXCEPTION WHEN insufficient_privilege THEN
        cluster := 'unknown';
      END;

      RETURN left(md5(cluster || '.' ||
        (SELECT oid FROM pg_database WHERE datname = current_database())::text), 12);
    END
    $$ LANGUAGE plpgsql STABLE
    """
  end

  def down do
    execute "DROP FUNCTION kith_dav_sync_epoch()"

    execute "ALTER TABLE dav_sync_floors ADD COLUMN revision bigint NOT NULL DEFAULT 0"

    execute "ALTER TABLE dav_sync_floors ADD COLUMN xid xid8 NOT NULL DEFAULT pg_current_xact_id()"

    execute "ALTER TABLE dav_sync_floors ALTER COLUMN seq DROP NOT NULL"

    execute """
    CREATE OR REPLACE FUNCTION contacts_log_dav_change() RETURNS trigger AS $$
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

    execute "ALTER TABLE contacts ADD COLUMN dav_xid xid8 NOT NULL DEFAULT pg_current_xact_id()"

    execute """
    CREATE OR REPLACE FUNCTION contacts_bump_dav_revision() RETURNS trigger AS $$
    BEGIN
      NEW.dav_revision := nextval('contacts_dav_revision_seq');
      NEW.dav_xid := pg_current_xact_id();
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION contacts_record_dav_sync_floor() RETURNS trigger AS $$
    BEGIN
      INSERT INTO dav_sync_floors (account_id, revision, xid, seq)
      SELECT account_id, nextval('contacts_dav_revision_seq'), pg_current_xact_id(), nextval('dav_change_seq')
      FROM (SELECT DISTINCT account_id FROM deleted_contacts) AS accounts
      ON CONFLICT (account_id)
      DO UPDATE SET revision = EXCLUDED.revision, xid = EXCLUDED.xid, seq = EXCLUDED.seq;
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
end
