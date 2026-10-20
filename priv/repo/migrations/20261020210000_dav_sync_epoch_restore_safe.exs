defmodule Kith.Repo.Migrations.DavSyncEpochRestoreSafe do
  use Ecto.Migration

  # CDV-56: the sync epoch must also change on an in-place logical restore
  # (`pg_restore --clean` into the same database), which keeps the cluster id,
  # timeline and database oid. Such a restore drops and recreates the change
  # log and its sequence, so their oids are folded in (pg_upgrade preserves
  # relation oids, so an upgrade does not force a resync). For anything the
  # database cannot see (a PITR on a host without pg_control rights), an
  # operator rotates the epoch with `SELECT kith_dav_rotate_sync_epoch();`.
  def up do
    create table(:dav_sync_epoch_salt, primary_key: false) do
      add :salt, :text, null: false
    end

    execute "INSERT INTO dav_sync_epoch_salt (salt) VALUES (gen_random_uuid()::text)"

    execute """
    CREATE OR REPLACE FUNCTION kith_dav_sync_epoch() RETURNS text AS $$
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

      RETURN left(md5(concat_ws('.',
        cluster,
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        'contact_dav_changes'::regclass::oid,
        'dav_change_seq'::regclass::oid,
        (SELECT string_agg(salt, ',') FROM dav_sync_epoch_salt))), 12);
    END
    $$ LANGUAGE plpgsql STABLE
    """

    execute """
    CREATE FUNCTION kith_dav_rotate_sync_epoch() RETURNS void AS $$
      DELETE FROM dav_sync_epoch_salt;
      INSERT INTO dav_sync_epoch_salt (salt) VALUES (gen_random_uuid()::text);
    $$ LANGUAGE sql
    """
  end

  def down do
    execute "DROP FUNCTION kith_dav_rotate_sync_epoch()"

    execute """
    CREATE OR REPLACE FUNCTION kith_dav_sync_epoch() RETURNS text AS $$
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

    drop table(:dav_sync_epoch_salt)
  end
end
