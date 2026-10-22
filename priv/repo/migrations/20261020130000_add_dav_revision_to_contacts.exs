defmodule Kith.Repo.Migrations.AddDavRevisionToContacts do
  use Ecto.Migration

  # R4: the CardDAV ETag is derived from `dav_revision`, a value drawn from a
  # sequence on every INSERT and UPDATE of a contact row, whatever path wrote
  # it (Ecto, update_all, raw SQL). `updated_at` has second precision, so two
  # writes inside one second used to yield the same ETag.
  def up do
    execute "CREATE SEQUENCE contacts_dav_revision_seq"

    alter table(:contacts) do
      add :dav_revision, :bigint,
        null: false,
        default: fragment("nextval('contacts_dav_revision_seq')")
    end

    execute """
    CREATE FUNCTION contacts_bump_dav_revision() RETURNS trigger AS $$
    BEGIN
      NEW.dav_revision := nextval('contacts_dav_revision_seq');
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER contacts_bump_dav_revision
    BEFORE INSERT OR UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION contacts_bump_dav_revision()
    """
  end

  def down do
    execute "DROP TRIGGER contacts_bump_dav_revision ON contacts"
    execute "DROP FUNCTION contacts_bump_dav_revision()"

    alter table(:contacts) do
      remove :dav_revision
    end

    execute "DROP SEQUENCE contacts_dav_revision_seq"
  end
end
