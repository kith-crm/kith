defmodule Kith.Repo.Migrations.AddDavXidToContacts do
  use Ecto.Migration

  # R3 / CDV-46: a CardDAV sync token is a position `(revision, snapshot)`:
  # the last `contacts_dav_revision_seq` value and the Postgres snapshot taken
  # when the token was issued. A contact changed since the token is one whose
  # `dav_revision` is newer, or whose last writing transaction (`dav_xid`) was
  # not yet visible in that snapshot (it was in flight, so its revision may be
  # older). That is exact to the transaction, unlike the old wall-clock seconds.
  def up do
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
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION contacts_bump_dav_revision() RETURNS trigger AS $$
    BEGIN
      NEW.dav_revision := nextval('contacts_dav_revision_seq');
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute "ALTER TABLE contacts DROP COLUMN dav_xid"
  end
end
