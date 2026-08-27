defmodule Kith.Contacts.MergeInvariantsTest do
  @moduledoc """
  Structural guards on the merge engine. These do not exercise a merge — they
  assert that the engine's static registries still match the schema, so adding
  a table or a pointer to a contact fails here rather than silently orphaning
  rows at merge time.
  """
  use Kith.DataCase, async: true

  alias Kith.Repo

  # Every table with a contact_id column must be handled by the engine: either
  # in @owned_schemas (blanket move), or by a dedicated step. Findings 2 and 3
  # were both "the engine does not know about this pointer".
  @handled_by_dedicated_step ~w(
    contacts
    contact_tags
    activity_contacts
    photos
    immich_candidates
    relationships
    duplicate_candidates
    import_records
    audit_logs
  )

  test "every table with a contact_id is handled by the merge engine" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE column_name = 'contact_id'
        AND table_schema = 'public'
      ORDER BY table_name
      """)

    tables = List.flatten(rows)

    owned_tables =
      Kith.Contacts.Merge.__owned_schemas__()
      |> Enum.map(& &1.__schema__(:source))

    unhandled = tables -- (owned_tables ++ @handled_by_dedicated_step)

    assert unhandled == [],
           """
           These tables have a contact_id the merge engine does not repoint:
           #{inspect(unhandled)}

           Add each to @owned_schemas in lib/kith/contacts/merge.ex, or give it
           a dedicated Multi step and list it in @handled_by_dedicated_step here.
           """
  end

  # Finding 3's class: a pointer to a contact that is not named contact_id.
  test "every foreign key referencing contacts is repointed or intentionally not" do
    %{rows: rows} =
      Repo.query!("""
      SELECT tc.table_name, kcu.column_name
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
      JOIN information_schema.constraint_column_usage ccu
        ON tc.constraint_name = ccu.constraint_name
      WHERE tc.constraint_type = 'FOREIGN KEY'
        AND ccu.table_name = 'contacts'
        AND kcu.column_name != 'contact_id'
      ORDER BY tc.table_name, kcu.column_name
      """)

    # Each entry is {table, column} the engine knowingly handles.
    known = [
      # remap_me_contact_step/4 — Task 3
      ["users", "me_contact_id"],
      # remap_inbound_first_met_step/4
      ["contacts", "first_met_through_id"],
      # remap_relationships/4 (raw SQL) — the table is `relationships`, not
      # `contact_relationships` as originally assumed; verified against
      # lib/kith/contacts/relationship.ex's `schema "relationships"`.
      ["relationships", "related_contact_id"],
      # resolve_after_merge/4 in DuplicateDetection — the schema's second FK
      # to contacts is `duplicate_contact_id`, not `contact_a_id`/
      # `contact_b_id` as originally assumed; the first FK is `contact_id`,
      # already excluded above. Verified both loser ids are repointed to the
      # survivor in DuplicateDetection.resolve_after_merge/4.
      ["duplicate_candidates", "duplicate_contact_id"]
    ]

    assert rows -- known == [],
           """
           These columns point at contacts and the merge engine does not
           repoint them: #{inspect(rows -- known)}
           """
  end
end
