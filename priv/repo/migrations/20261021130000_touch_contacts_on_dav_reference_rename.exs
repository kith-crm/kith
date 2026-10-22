defmodule Kith.Repo.Migrations.TouchContactsOnDavReferenceRename do
  use Ecto.Migration

  # CDV-98 (R48): a vCard also shows shared records by name — CATEGORIES (tag
  # name), GENDER (gender name), TEL/EMAIL/URL/X-… (field type protocol and
  # vCard label) and the relationship label/TYPE (relationship type name).
  # Renaming one in Settings or the REST API changed every card that shows it
  # without moving their ETags or sync positions. These triggers touch the
  # contacts that reference the record, only when a column the vCard shows
  # changed. Deletes are already covered: they cascade into child rows
  # (CDV-97 triggers) or nullify `contacts.gender_id`.
  @touch "UPDATE contacts SET updated_at = date_trunc('second', timezone('UTC', clock_timestamp()))"

  @references [
    {"tags", "name", "id IN (SELECT contact_id FROM contact_tags WHERE tag_id = NEW.id)"},
    {"genders", "name", "gender_id = NEW.id"},
    {"contact_field_types", "protocol, vcard_label",
     "id IN (SELECT contact_id FROM contact_fields WHERE contact_field_type_id = NEW.id)"},
    {"relationship_types", "name",
     "id IN (SELECT contact_id FROM relationships WHERE relationship_type_id = NEW.id)"}
  ]

  def up do
    for {table, columns, where} <- @references do
      execute """
      CREATE FUNCTION #{table}_touch_dav_contacts() RETURNS trigger AS $$
      BEGIN
        #{@touch} WHERE #{where};
        RETURN NULL;
      END
      $$ LANGUAGE plpgsql
      """

      changed =
        columns
        |> String.split(", ")
        |> Enum.map_join(" OR ", &"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")

      execute """
      CREATE TRIGGER #{table}_touch_dav_contacts AFTER UPDATE OF #{columns} ON #{table}
      FOR EACH ROW WHEN (#{changed})
      EXECUTE FUNCTION #{table}_touch_dav_contacts()
      """
    end
  end

  def down do
    for {table, _columns, _where} <- @references do
      execute "DROP TRIGGER #{table}_touch_dav_contacts ON #{table}"
      execute "DROP FUNCTION #{table}_touch_dav_contacts()"
    end
  end
end
