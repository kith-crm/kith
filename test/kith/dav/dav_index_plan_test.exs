defmodule Kith.DAV.IndexPlanTest do
  @moduledoc """
  Plan guards for the lookups DAV writes run per row (Task 8 perf cliffs): the
  queries must be answerable from an index, otherwise a bulk import or a card
  with many RELATED lines is quadratic in the account size.
  """
  use Kith.DataCase, async: true

  # A tiny test table always prefers a sequential scan, so forbid it: the plan
  # then shows which index the query *can* use.
  defp plan(sql, params_fun) do
    account_id = seed_contacts()
    plan_sql(sql, params_fun.(account_id))
  end

  defp plan_sql(sql, params) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")
    "EXPLAIN " |> Kernel.<>(sql) |> Repo.query!(params) |> Map.fetch!(:rows) |> Enum.join("\n")
  end

  # Enough rows of one account, UIDs set on every row, that statistics favour
  # an index on (account_id, dav_uid) over the account-only ones.
  defp seed_contacts do
    %{rows: [[account_id]]} =
      Repo.query!(
        "INSERT INTO accounts (name, inserted_at, updated_at) VALUES ('plan', now(), now()) RETURNING id"
      )

    Repo.query!(
      """
      INSERT INTO contacts (account_id, first_name, display_name, aliases, immich_status,
        birthdate_year_unknown, deceased, favorite, first_met_reminder, first_met_year_unknown,
        is_archived, dav_vcard, dav_uid, inserted_at, updated_at)
      SELECT $1, 'x' || g, 'x' || g, '{}', 'unlinked', false, false, false, false, false,
        false, '{}', 'urn:uuid:' || gen_random_uuid(), now(), now()
      FROM generate_series(1, 2000) g
      """,
      [account_id]
    )

    Repo.query!("ANALYZE contacts")
    account_id
  end

  describe "contacts BEFORE INSERT trigger" do
    test "CDV-104: the default-UID shadow check is answered from an index on dav_uid" do
      # The EXISTS in contacts_avoid_shadowed_default_name(), for a contact with
      # no stored dav_uid (every UI/API/import insert).
      plan =
        plan(
          "SELECT 1 FROM contacts WHERE account_id = $1 AND dav_uid IN ($2, $3)",
          &[&1, "kith-contact-5", "urn:uuid:kith-contact-5"]
        )

      assert plan =~ ~r/Index Cond:[^\n]*dav_uid/, plan
    end
  end

  describe "RELATED resolution" do
    test "CDV-105: both the UUID and the text-UID lookup are answered from an index" do
      account_id = seed_contacts()

      for uid <- ["urn:uuid:7a6c5a7e-0000-4000-8000-000000000001", "kith-text-uid"] do
        {sql, params} =
          account_id |> Kith.Contacts.related_contact_query(uid) |> then(&Repo.to_sql(:all, &1))

        plan = plan_sql(sql, params)
        assert plan =~ ~r/Index Cond:[^\n]*regexp_replace/, plan
      end
    end
  end
end
