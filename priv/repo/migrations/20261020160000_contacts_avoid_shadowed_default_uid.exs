defmodule Kith.Repo.Migrations.ContactsAvoidShadowedDefaultUid do
  use Ecto.Migration

  # R20 / CDV-38: a client card may already hold `kith-contact-<id>` (or
  # `urn:uuid:kith-contact-<id>`) as its UID before contact <id> exists. That
  # contact must not then emit the same default UID: at insert it gets the
  # stored UID `kith-contact-<id>-k` (`-k1`, … if taken). The candidate is
  # checked against every contact of the account, trashed and archived
  # included, so it can never hit the visible-UID unique index.
  def up do
    execute """
    CREATE OR REPLACE FUNCTION contacts_avoid_shadowed_default_name() RETURNS trigger AS $$
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

      n := 0;

      IF NEW.dav_uid IS NULL AND EXISTS (
        SELECT 1 FROM contacts
        WHERE account_id = NEW.account_id
          AND dav_uid IN ('kith-contact-' || NEW.id, 'urn:uuid:kith-contact-' || NEW.id)
      ) THEN
        candidate := 'kith-contact-' || NEW.id || '-k';

        WHILE EXISTS (
          SELECT 1 FROM contacts
          WHERE account_id = NEW.account_id
            AND dav_uid IN (candidate, 'urn:uuid:' || candidate)
        ) LOOP
          n := n + 1;
          candidate := 'kith-contact-' || NEW.id || '-k' || n;
        END LOOP;

        NEW.dav_uid := candidate;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    # Contacts inserted before this migration whose default UID a client card
    # already holds: give them the same alternative UID (not reverted by down).
    execute """
    UPDATE contacts c SET dav_uid = 'kith-contact-' || c.id || '-k'
    WHERE c.dav_uid IS NULL
      AND EXISTS (
        SELECT 1 FROM contacts h
        WHERE h.account_id = c.account_id AND h.id <> c.id
          AND h.dav_uid IN ('kith-contact-' || c.id, 'urn:uuid:kith-contact-' || c.id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM contacts o
        WHERE o.account_id = c.account_id
          AND o.dav_uid IN ('kith-contact-' || c.id || '-k', 'urn:uuid:kith-contact-' || c.id || '-k')
      )
    """
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION contacts_avoid_shadowed_default_name() RETURNS trigger AS $$
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
  end
end
