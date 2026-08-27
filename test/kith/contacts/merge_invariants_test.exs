defmodule Kith.Contacts.MergeInvariantsTest do
  @moduledoc """
  Structural guards on the merge engine. These do not exercise a merge — they
  assert that the engine's static registries still match the schema, so adding
  a table or a pointer to a contact fails here rather than silently orphaning
  rows at merge time.

  ## What these tests do NOT cover

  The first test below only catches a pointer named `contact_id`; the second
  only catches a pointer backed by a foreign key constraint. A pointer that is
  BOTH unnamed `contact_id` AND has no FK escapes both queries entirely.
  `import_records.local_entity_id` is exactly that shape today — an untyped,
  deliberately FK-less bigint paired with a `local_entity_type` string (a
  polymorphic pointer; see the comment on `@owned_schemas` in
  `lib/kith/contacts/merge.ex`) — and it is pinned individually by the third
  test below. A *new* column of this same shape (untyped, no FK, not named
  `contact_id`) would stay invisible to both structural tests here; catching
  that class in general was considered and rejected as too noisy for a
  static registry check, so it is left to code review rather than automated
  here.
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

  # import_records.local_entity_id is the one known pointer neither test
  # above can see — see the moduledoc's "What these tests do NOT cover". A
  # behavioural test already covers this ("import records follow the
  # survivor" in test/kith/contacts_merge_test.exs), so this doesn't run a
  # second merge to prove the same thing; it pins the wiring structurally
  # instead, so removing `remap_import_records_step/4` or disconnecting it
  # from `build_multi/7`'s Multi chain fails here too.
  test "the untyped import_records pointer has a dedicated, wired step" do
    source =
      __ENV__.file
      |> Path.dirname()
      |> Path.join("../../../lib/kith/contacts/merge.ex")
      |> Path.expand()
      |> File.read!()

    assert source =~
             ~r/defp remap_import_records_step\(repo, loser_ids, survivor_id, account_id\)/,
           "remap_import_records_step/4 is missing from lib/kith/contacts/merge.ex"

    assert source =~ ~r/Multi\.run\(:remap_import_records,.*?remap_import_records_step\(/s,
           "remap_import_records_step/4 exists but is no longer wired into build_multi/7's Multi chain"
  end
end
