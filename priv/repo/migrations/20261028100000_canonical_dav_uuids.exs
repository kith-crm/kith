defmodule Kith.Repo.Migrations.CanonicalDavUuids do
  use Ecto.Migration

  @uuid "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  def up do
    # Audit before converting: preserve identities and hrefs rather than
    # silently assigning replacement UUIDs to incompatible legacy rows.
    invalid =
      repo().query!(
        "SELECT contact_id FROM contact_dav WHERE regexp_replace(uid, '^urn:uuid:', '', 'i') !~* $1 ORDER BY contact_id LIMIT 10",
        [@uuid]
      ).rows

    if invalid != [],
      do:
        raise(
          "Cannot canonicalize CardDAV UIDs: non-UUID identities for contact IDs #{inspect(invalid)}"
        )

    collisions =
      repo().query!("""
      SELECT account_id, lower(regexp_replace(uid, '^urn:uuid:', '', 'i'))
      FROM contact_dav
      GROUP BY account_id, lower(regexp_replace(uid, '^urn:uuid:', '', 'i'))
      HAVING count(*) > 1
      LIMIT 10
      """).rows

    if collisions != [],
      do:
        raise(
          "Cannot canonicalize CardDAV UIDs: equivalent identities collide #{inspect(collisions)}"
        )

    execute "ALTER TABLE contact_dav ALTER COLUMN uid TYPE uuid USING regexp_replace(uid, '^urn:uuid:', '', 'i')::uuid"

    # UID and legacy birthday serialization change at this deployment. Make
    # existing clients re-fetch cards rather than retaining old bytes/ETags.
    execute "UPDATE contact_dav SET revision = nextval('contact_dav_revision_seq')"
  end

  def down do
    execute "ALTER TABLE contact_dav ALTER COLUMN uid TYPE text USING uid::text"
    execute "UPDATE contact_dav SET revision = nextval('contact_dav_revision_seq')"
  end
end
