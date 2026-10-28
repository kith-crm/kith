defmodule Kith.Repo.Migrations.TouchRelationshipOwnersOnTargetChange do
  use Ecto.Migration

  # CDV-100 (R50): a relationship is served on its owner's card with the
  # target's name (3.0 X-ABRELATEDNAMES) and UID (4.0 RELATED). Renaming the
  # target in the UI changed the owner's card without moving the owner's ETag
  # or sync position. This trigger touches the owners when a column feeding
  # that name or UID changes. The touch itself changes none of those columns,
  # so mutual relationships do not ping-pong.
  @columns ~w(display_name first_name middle_name last_name nickname dav_uid)

  def up do
    execute """
    CREATE FUNCTION contacts_touch_relationship_owners() RETURNS trigger AS $$
    BEGIN
      UPDATE contacts SET updated_at = date_trunc('second', timezone('UTC', clock_timestamp()))
      WHERE id IN (
        SELECT contact_id FROM relationships
        WHERE related_contact_id = NEW.id AND contact_id <> NEW.id
      );
      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    changed = Enum.map_join(@columns, " OR ", &"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")

    execute """
    CREATE TRIGGER contacts_touch_relationship_owners
    AFTER UPDATE OF #{Enum.join(@columns, ", ")} ON contacts
    FOR EACH ROW WHEN (#{changed})
    EXECUTE FUNCTION contacts_touch_relationship_owners()
    """
  end

  def down do
    execute "DROP TRIGGER contacts_touch_relationship_owners ON contacts"
    execute "DROP FUNCTION contacts_touch_relationship_owners()"
  end
end
