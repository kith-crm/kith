defmodule Kith.Repo.Migrations.CarddavDataBoundary do
  use Ecto.Migration

  # Snapshot historical seed definitions here. Do not use the application's
  # current registry to decide which legacy rows receive trusted classification.
  @field_definitions [
    ["email", "Email", "mailto:", "mail", "EMAIL", 0],
    ["phone", "Phone", "tel:", "phone", "TEL", 1],
    ["mobile", "Mobile", "tel:", "smartphone", "TEL;TYPE=CELL", 2],
    ["work_phone", "Work phone", "tel:", "phone", "TEL;TYPE=WORK", 3],
    ["fax", "Fax", "tel:", "printer", "TEL;TYPE=FAX", 4],
    ["website", "Website", "https://", "globe", "URL", 5]
  ]
  @relationship_definitions [
    ["partner", "Partner", "Partner", true, 0],
    ["spouse", "Spouse", "Spouse", true, 1],
    ["friend", "Friend", "Friend", true, 2],
    ["best_friend", "Best friend", "Best friend", true, 3],
    ["parent", "Parent", "Child", false, 4],
    ["child", "Child", "Parent", false, 5],
    ["sibling", "Sibling", "Sibling", true, 6],
    ["grandparent", "Grandparent", "Grandchild", false, 7],
    ["grandchild", "Grandchild", "Grandparent", false, 8],
    ["uncle_aunt", "Uncle/Aunt", "Nephew/Niece", false, 9],
    ["nephew_niece", "Nephew/Niece", "Uncle/Aunt", false, 10],
    ["cousin", "Cousin", "Cousin", true, 11],
    ["colleague", "Colleague", "Colleague", true, 12],
    ["boss", "Boss", "Subordinate", false, 13],
    ["subordinate", "Subordinate", "Boss", false, 14],
    ["mentor", "Mentor", "Mentee", false, 15],
    ["mentee", "Mentee", "Mentor", false, 16],
    ["neighbor", "Neighbor", "Neighbor", true, 17],
    ["roommate", "Roommate", "Roommate", true, 18],
    ["ex_partner", "Ex-partner", "Ex-partner", true, 19],
    ["contact", "Contact", "Contact", true, 20]
  ]

  def up do
    fields = audit_fields!()
    relationships = audit_relationships!()

    alter table(:contact_field_types), do: add(:system_key, :text)
    alter table(:relationship_types), do: add(:system_key, :text)

    alter table(:contact_dav) do
      add :document, :map, null: false, default: %{}

      add :representation_modified_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")

      add :representation_fingerprint, :text
      add :requires_precondition, :boolean, null: false, default: false
    end

    flush()
    Enum.each(fields, &classify_field!/1)
    Enum.each(relationships, &classify_relationship!/1)

    create unique_index(:contact_field_types, [:system_key],
             where: "system_key IS NOT NULL",
             name: :contact_field_types_system_key_index
           )

    create unique_index(:relationship_types, [:system_key],
             where: "system_key IS NOT NULL",
             name: :relationship_types_system_key_index
           )

    create constraint(:contact_field_types, :contact_field_types_system_key_global,
             check: "system_key IS NULL OR account_id IS NULL"
           )

    create constraint(:relationship_types, :relationship_types_system_key_global,
             check: "system_key IS NULL OR account_id IS NULL"
           )

    # Existing clients can hold cards produced by the old private-data policy.
    # Reserve their identities, invalidate validators, and reject unconditional
    # replacement until a new-policy representation validator is provided.
    # Legacy extras remain quarantined in their existing column for review;
    # they are deliberately not copied into the new client document.
    execute """
    UPDATE contact_dav
    SET requires_precondition = true,
        revision = nextval('contact_dav_revision_seq')
    """
  end

  def down do
    # Downgrading loses DAV-only metadata; operators must retain a backup and
    # disable DAV rather than serve private data through the old serializer.
    execute "UPDATE contact_dav SET revision = nextval('contact_dav_revision_seq')"
    drop constraint(:relationship_types, :relationship_types_system_key_global)
    drop constraint(:contact_field_types, :contact_field_types_system_key_global)
    drop index(:relationship_types, [:system_key], name: :relationship_types_system_key_index)
    drop index(:contact_field_types, [:system_key], name: :contact_field_types_system_key_index)
    alter table(:contact_field_types), do: remove(:system_key)
    alter table(:relationship_types), do: remove(:system_key)

    alter table(:contact_dav) do
      remove :requires_precondition
      remove :representation_fingerprint
      remove :representation_modified_at
      remove :document
    end
  end

  defp audit_fields! do
    Enum.map(@field_definitions, fn [key, name, protocol, icon, label, position] = definition ->
      rows =
        repo().query!(
          "SELECT id, protocol, icon, vcard_label, position FROM contact_field_types WHERE account_id IS NULL AND name = $1",
          [name]
        ).rows

      id = audited_id!("contact field", key, rows, [protocol, icon, label, position])
      {id, definition}
    end)
  end

  defp audit_relationships! do
    Enum.map(@relationship_definitions, fn [key, name, reverse, bidirectional, position] =
                                             definition ->
      rows =
        repo().query!(
          "SELECT id, reverse_name, is_bidirectional, position FROM relationship_types WHERE account_id IS NULL AND name = $1",
          [name]
        ).rows

      id = audited_id!("relationship", key, rows, [reverse, bidirectional, position])
      {id, definition}
    end)
  end

  defp audited_id!(_kind, _key, [], _expected), do: nil
  defp audited_id!(_kind, _key, [[id | expected]], expected), do: id

  defp audited_id!(kind, key, rows, _expected) do
    raise "Cannot classify DAV #{kind} #{key}: ambiguous or altered global seed rows #{inspect(rows)}; review the mapping before retrying"
  end

  defp classify_field!({nil, [key, name, protocol, icon, label, position]}) do
    repo().query!(
      "INSERT INTO contact_field_types (system_key, name, protocol, icon, vcard_label, position, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, timezone('UTC', now()), timezone('UTC', now()))",
      [key, name, protocol, icon, label, position]
    )
  end

  defp classify_field!({id, [key | _]}) do
    repo().query!("UPDATE contact_field_types SET system_key = $1 WHERE id = $2", [key, id])
  end

  defp classify_relationship!({nil, [key, name, reverse, bidirectional, position]}) do
    repo().query!(
      "INSERT INTO relationship_types (system_key, name, reverse_name, is_bidirectional, position, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, timezone('UTC', now()), timezone('UTC', now()))",
      [key, name, reverse, bidirectional, position]
    )
  end

  defp classify_relationship!({id, [key | _]}) do
    repo().query!("UPDATE relationship_types SET system_key = $1 WHERE id = $2", [key, id])
  end
end
