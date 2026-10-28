defmodule Kith.Repo.Migrations.AddContactsShadowedDefaultNameTrigger do
  use Ecto.Migration

  # R20: a CardDAV client may hold `kith-contact-<id>.vcf` as its own resource
  # name before contact <id> exists (vdirsyncer names uploads `<UID>.vcf`). When
  # contact <id> is then inserted, by any path, it gets the stored name
  # `kith-contact-<id>-k.vcf` (or `-k1`, `-k2`, … if that is taken too) so it
  # never shares an href with the client's card.
  def up do
    execute """
    CREATE FUNCTION contacts_avoid_shadowed_default_name() RETURNS trigger AS $$
    DECLARE
      candidate text;
      n integer := 0;
    BEGIN
      IF NEW.dav_resource_name IS NULL AND EXISTS (
        SELECT 1 FROM contacts
        WHERE account_id = NEW.account_id
          AND dav_resource_name = 'kith-contact-' || NEW.id || '.vcf'
      ) THEN
        candidate := 'kith-contact-' || NEW.id || '-k.vcf';

        WHILE EXISTS (
          SELECT 1 FROM contacts
          WHERE account_id = NEW.account_id AND dav_resource_name = candidate
        ) LOOP
          n := n + 1;
          candidate := 'kith-contact-' || NEW.id || '-k' || n || '.vcf';
        END LOOP;

        NEW.dav_resource_name := candidate;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER contacts_avoid_shadowed_default_name
    BEFORE INSERT ON contacts
    FOR EACH ROW EXECUTE FUNCTION contacts_avoid_shadowed_default_name()
    """
  end

  def down do
    execute "DROP TRIGGER contacts_avoid_shadowed_default_name ON contacts"
    execute "DROP FUNCTION contacts_avoid_shadowed_default_name()"
  end
end
