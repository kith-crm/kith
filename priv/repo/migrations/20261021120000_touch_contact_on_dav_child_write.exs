defmodule Kith.Repo.Migrations.TouchContactOnDavChildWrite do
  use Ecto.Migration

  # CDV-97 (R4, R47): a contact's vCard is built from its own row and from the
  # child rows below. Only a write to the contact row moves its ETag revision
  # (`contacts_bump_dav_revision`) and its sync position
  # (`contacts_log_dav_change`), so a phone, address, tag or relationship added
  # in the UI, the REST API or an import stayed invisible to CardDAV clients.
  # These statement-level triggers touch every parent contact a statement
  # wrote children for (old and new parent on an UPDATE that moves a child, as
  # a merge does), whatever code path ran the statement. Touching an already
  # deleted parent (cascade from a hard delete) updates nothing.
  @children ~w(contact_fields addresses contact_tags relationships)

  def up do
    execute """
    CREATE FUNCTION contacts_touch_for_dav_child() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        UPDATE contacts SET updated_at = date_trunc('second', timezone('UTC', clock_timestamp()))
        WHERE id IN (SELECT contact_id FROM new_rows);
      ELSIF TG_OP = 'UPDATE' THEN
        UPDATE contacts SET updated_at = date_trunc('second', timezone('UTC', clock_timestamp()))
        WHERE id IN (SELECT contact_id FROM new_rows UNION SELECT contact_id FROM old_rows);
      ELSE
        UPDATE contacts SET updated_at = date_trunc('second', timezone('UTC', clock_timestamp()))
        WHERE id IN (SELECT contact_id FROM old_rows);
      END IF;
      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    for table <- @children do
      execute """
      CREATE TRIGGER #{table}_touch_contact_ins AFTER INSERT ON #{table}
      REFERENCING NEW TABLE AS new_rows
      FOR EACH STATEMENT EXECUTE FUNCTION contacts_touch_for_dav_child()
      """

      execute """
      CREATE TRIGGER #{table}_touch_contact_upd AFTER UPDATE ON #{table}
      REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
      FOR EACH STATEMENT EXECUTE FUNCTION contacts_touch_for_dav_child()
      """

      execute """
      CREATE TRIGGER #{table}_touch_contact_del AFTER DELETE ON #{table}
      REFERENCING OLD TABLE AS old_rows
      FOR EACH STATEMENT EXECUTE FUNCTION contacts_touch_for_dav_child()
      """
    end
  end

  def down do
    for table <- @children, op <- ~w(ins upd del) do
      execute "DROP TRIGGER #{table}_touch_contact_#{op} ON #{table}"
    end

    execute "DROP FUNCTION contacts_touch_for_dav_child()"
  end
end
