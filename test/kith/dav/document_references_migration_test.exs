defmodule Kith.DAV.DocumentReferencesMigrationTest do
  use Kith.DataCase, async: false

  alias Kith.DAV.Document

  @migration Kith.Repo.Migrations.CreateDavDocumentReferences
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261029010000_create_dav_document_references.exs",
        __DIR__
      )
    )
  end

  test "backfill indexes rich and compact UUID references without native target bindings" do
    %{rows: [[public_count]]} = Repo.query!("SELECT count(*) FROM public.dav_document_references")
    # Explicit pg_temp search-path makes the migration-created output table and
    # its FK targets session-local; the installed public schema is untouched.
    Repo.query!("CREATE TEMP TABLE accounts (id bigint PRIMARY KEY) ON COMMIT DROP")

    Repo.query!(
      "CREATE TEMP TABLE contact_dav (contact_id bigint PRIMARY KEY, account_id bigint, document jsonb) ON COMMIT DROP"
    )

    Repo.query!("SET LOCAL search_path = pg_temp, public")
    Repo.query!("INSERT INTO accounts VALUES (42), (99)")
    one = "a1000000-0000-4000-8000-000000000001"
    two = "b2000000-0000-4000-8000-000000000002"

    rich =
      document([
        {"RELATED", "URN:UUID:" <> String.upcase(one)},
        {"X-KITH-RELATED", one},
        {"RELATED", "https://external.example/person"},
        {"NOTE", two}
      ])

    compact = Document.pack(document([{"related", one}, {"X-KITH-RELATED", "urn:uuid:" <> two}]))
    foreign = document([{"RELATED", one}])
    insert(1, 42, rich)
    insert(2, 42, compact)
    insert(3, 99, foreign)
    before = Repo.query!("SELECT contact_id, document FROM contact_dav ORDER BY contact_id").rows

    run(:up)

    assert %{rows: [["t"]]} =
             Repo.query!(
               "SELECT relpersistence::text FROM pg_class WHERE oid = to_regclass('pg_temp.dav_document_references')"
             )

    assert Repo.query!(
             "SELECT account_id, source_contact_id, target_uid::text FROM dav_document_references ORDER BY account_id, source_contact_id, target_uid"
           ).rows == [
             [42, 1, one],
             [42, 2, one],
             [42, 2, two],
             [99, 3, one]
           ]

    assert Repo.query!("SELECT contact_id, document FROM contact_dav ORDER BY contact_id").rows ==
             before

    assert %{rows: [[^public_count]]} =
             Repo.query!("SELECT count(*) FROM public.dav_document_references")

    run(:down)

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regclass('pg_temp.dav_document_references')::text")

    assert %{rows: [[^public_count]]} =
             Repo.query!("SELECT count(*) FROM public.dav_document_references")
  end

  defp document(properties) do
    entries =
      Enum.map(properties, fn {name, value} ->
        %{
          "id" => Ecto.UUID.generate(),
          "binding" => nil,
          "property" => %{
            "name" => name,
            "normalized_name" => String.upcase(name),
            "group" => nil,
            "parameters" => [],
            "value" => value
          }
        }
      end)

    %{"schema_version" => 1, "source_version" => "v40", "properties" => entries}
  end

  defp insert(id, account, document),
    do:
      Repo.query!(
        "INSERT INTO contact_dav (contact_id, account_id, document) VALUES ($1, $2, $3::jsonb)",
        [id, account, document]
      )

  defp run(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_029_010_000,
      @migration,
      if(direction == :up, do: :forward, else: :backward),
      :change,
      direction,
      log: false
    )
  end
end
