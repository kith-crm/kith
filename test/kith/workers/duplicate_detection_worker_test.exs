defmodule Kith.Workers.DuplicateDetectionWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.Factory
  import Kith.ContactsFixtures

  alias Kith.Contacts.DuplicateCandidate
  alias Kith.Workers.DuplicateDetectionWorker

  setup do
    seed_reference_data!()
    {account, _user} = setup_account()

    email_type =
      Repo.one!(
        from t in "contact_field_types",
          where: t.protocol == "mailto:",
          select: %{id: t.id},
          limit: 1
      )

    phone_type =
      Repo.one!(
        from t in "contact_field_types",
          where: t.protocol == "tel:",
          select: %{id: t.id},
          limit: 1
      )

    %{account: account, email_type_id: email_type.id, phone_type_id: phone_type.id}
  end

  defp run_detection(account_id) do
    perform_job(DuplicateDetectionWorker, %{account_id: account_id})
  end

  defp pending_candidates(account_id) do
    DuplicateCandidate
    |> where([d], d.account_id == ^account_id)
    |> where([d], d.status == "pending")
    |> order_by([d], desc: d.score)
    |> Repo.all()
  end

  describe "name matching" do
    test "detects contacts with similar display names", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "John Smith",
        first_name: "John",
        last_name: "Smith"
      )

      insert(:contact,
        account: account,
        display_name: "John Smithe",
        first_name: "John",
        last_name: "Smithe"
      )

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "name_match" in hd(candidates).reasons
      assert hd(candidates).score >= 0.5
    end

    test "does not match dissimilar names", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "Alice Johnson",
        first_name: "Alice",
        last_name: "Johnson"
      )

      insert(:contact,
        account: account,
        display_name: "Bob Williams",
        first_name: "Bob",
        last_name: "Williams"
      )

      assert :ok = run_detection(account.id)

      assert pending_candidates(account.id) == []
    end
  end

  describe "email matching" do
    test "detects contacts sharing the same email", %{
      account: account,
      email_type_id: email_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "email_match" in hd(candidates).reasons
      assert hd(candidates).score >= 0.8
    end

    test "email matching is case-insensitive", %{account: account, email_type_id: email_type_id} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "SHARED@Example.COM"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "email_match" in hd(candidates).reasons
    end

    test "email matching trims surrounding whitespace",
         %{account: account, email_type_id: email_type_id} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice",
          first_name: "Alice",
          last_name: ""
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob",
          first_name: "Bob",
          last_name: ""
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "  Foo@BAR.com  "})
      contact_field_fixture(c2, email_type_id, %{"value" => "foo@bar.com"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "email_match" in hd(candidates).reasons
    end

    # Note: pure whitespace-only email values are rejected by the ContactField
    # changeset's `validate_required`, so the cartesian-explosion case from
    # Bug A can't actually manifest for emails through the normal write path.
    # Coverage is provided by the "trims surrounding whitespace" case above,
    # which exercises the same TRIM-in-JOIN code path on values that survive
    # validation.

    test "email-only match scores around 0.85", %{account: account, email_type_id: email_type_id} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Completely Different",
          first_name: "Completely",
          last_name: "Different"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Totally Unique",
          first_name: "Totally",
          last_name: "Unique"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "same@email.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "same@email.com"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert hd(candidates).score == 0.85
    end
  end

  describe "phone matching" do
    test "detects contacts sharing the same phone number", %{
      account: account,
      phone_type_id: phone_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, phone_type_id, %{"value" => "+1-555-1234"})
      contact_field_fixture(c2, phone_type_id, %{"value" => "+1-555-1234"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "phone_match" in hd(candidates).reasons
      assert hd(candidates).score >= 0.7
    end

    test "phone matching is strict equality on canonical E.164 values",
         %{account: account, phone_type_id: phone_type_id} do
      # Phone normalization runs at write-time (see PhoneFormatter.normalize/2),
      # so the detection worker assumes both values are already canonical.
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, phone_type_id, %{"value" => "+12025550100"})
      contact_field_fixture(c2, phone_type_id, %{"value" => "+12025550100"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "phone_match" in hd(candidates).reasons
    end

    test "does not cartesian-explode across formatting-only phone values",
         %{account: account, phone_type_id: phone_type_id} do
      # Regression for Bug A: previously the in-query regex normalized any
      # zero-digit value to "" and matched it against every other zero-digit
      # value (C(N,2) false candidates). With strict equality on canonical
      # values plus a TRIM-non-empty filter, distinct garbage strings produce
      # no matches.
      # Use deliberately dissimilar names so pg_trgm doesn't generate
      # name-based false positives and contaminate the assertion.
      contacts_data = [
        {"Aaron Zephyr", "Aaron", "Zephyr", "+"},
        {"Quincy Bramble", "Quincy", "Bramble", "-"},
        {"Yolanda Khoury", "Yolanda", "Khoury", "()"},
        {"Vladimir Tcheng", "Vladimir", "Tcheng", "abc"},
        {"Saoirse Mwangi", "Saoirse", "Mwangi", "N/A"},
        {"Daiyu Olafsson", "Daiyu", "Olafsson", "x"}
      ]

      for {display, first, last, garbage} <- contacts_data do
        contact =
          insert(:contact,
            account: account,
            display_name: display,
            first_name: first,
            last_name: last
          )

        contact_field_fixture(contact, phone_type_id, %{"value" => garbage})
      end

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)

      assert candidates == [],
             "expected no phone matches across distinct garbage values, got #{length(candidates)}"
    end

    test "phone-only match scores 0.75", %{account: account, phone_type_id: phone_type_id} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Completely Different",
          first_name: "Completely",
          last_name: "Different"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Totally Unique",
          first_name: "Totally",
          last_name: "Unique"
        )

      contact_field_fixture(c1, phone_type_id, %{"value" => "5559876"})
      contact_field_fixture(c2, phone_type_id, %{"value" => "5559876"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert hd(candidates).score == 0.75
    end
  end

  describe "address matching" do
    test "detects contacts sharing the same address", %{account: account} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      address_fixture(c1, %{"line1" => "123 Main St", "postal_code" => "90210"})
      address_fixture(c2, %{"line1" => "123 Main St", "postal_code" => "90210"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "address_match" in hd(candidates).reasons
      assert hd(candidates).score == 0.6
    end

    test "address matching is case-insensitive and trims whitespace", %{account: account} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      address_fixture(c1, %{"line1" => "  123 Main St  ", "postal_code" => "90210"})
      address_fixture(c2, %{"line1" => "123 MAIN ST", "postal_code" => "90210"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      assert "address_match" in hd(candidates).reasons
    end

    test "does not match on postal_code alone", %{account: account} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      address_fixture(c1, %{"line1" => "123 Main St", "postal_code" => "90210"})
      address_fixture(c2, %{"line1" => "456 Oak Ave", "postal_code" => "90210"})

      assert :ok = run_detection(account.id)

      assert pending_candidates(account.id) == []
    end
  end

  describe "combined signals" do
    test "email + name match scores higher than email alone", %{
      account: account,
      email_type_id: email_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "John Smith",
          first_name: "John",
          last_name: "Smith"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "John Smithe",
          first_name: "John",
          last_name: "Smithe"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "john@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "john@example.com"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      candidate = hd(candidates)
      assert "name_match" in candidate.reasons
      assert "email_match" in candidate.reasons
      # email base (0.85) + bonus for name signal (0.05) = 0.90
      assert candidate.score > 0.85
    end

    test "email + phone match boosts score", %{
      account: account,
      email_type_id: email_type_id,
      phone_type_id: phone_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Completely Different",
          first_name: "Completely",
          last_name: "Different"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Totally Unique",
          first_name: "Totally",
          last_name: "Unique"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "same@email.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "same@email.com"})
      contact_field_fixture(c1, phone_type_id, %{"value" => "5551234"})
      contact_field_fixture(c2, phone_type_id, %{"value" => "5551234"})

      assert :ok = run_detection(account.id)

      candidates = pending_candidates(account.id)
      assert length(candidates) == 1
      candidate = hd(candidates)
      assert "email_match" in candidate.reasons
      assert "phone_match" in candidate.reasons
      # email base (0.85) + 1 bonus (0.05) = 0.90
      assert candidate.score == 0.9
    end
  end

  describe "edge cases" do
    test "skips soft-deleted contacts", %{account: account, email_type_id: email_type_id} do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams",
          deleted_at: DateTime.utc_now(:second)
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      assert :ok = run_detection(account.id)

      assert pending_candidates(account.id) == []
    end

    test "does not re-insert existing pending candidates", %{
      account: account,
      email_type_id: email_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      # First run
      assert :ok = run_detection(account.id)
      assert length(pending_candidates(account.id)) == 1

      # Second run should not create duplicates
      assert :ok = run_detection(account.id)
      assert length(pending_candidates(account.id)) == 1
    end

    test "does not re-insert dismissed candidates", %{
      account: account,
      email_type_id: email_type_id
    } do
      c1 =
        insert(:contact,
          account: account,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      # First run, then dismiss
      assert :ok = run_detection(account.id)
      [candidate] = pending_candidates(account.id)
      Kith.DuplicateDetection.dismiss_candidate(candidate)

      # Second run should not re-create dismissed candidate
      assert :ok = run_detection(account.id)
      assert pending_candidates(account.id) == []
    end

    test "account isolation — only detects within same account", %{email_type_id: email_type_id} do
      {account1, _} = setup_account()
      {account2, _} = setup_account()

      c1 =
        insert(:contact,
          account: account1,
          display_name: "Alice Johnson",
          first_name: "Alice",
          last_name: "Johnson"
        )

      c2 =
        insert(:contact,
          account: account2,
          display_name: "Bob Williams",
          first_name: "Bob",
          last_name: "Williams"
        )

      contact_field_fixture(c1, email_type_id, %{"value" => "shared@example.com"})
      contact_field_fixture(c2, email_type_id, %{"value" => "shared@example.com"})

      assert :ok = run_detection(account1.id)
      assert :ok = run_detection(account2.id)

      assert pending_candidates(account1.id) == []
      assert pending_candidates(account2.id) == []
    end

    test "handles fewer than 2 contacts gracefully", %{account: account} do
      insert(:contact,
        account: account,
        display_name: "Only Contact",
        first_name: "Only",
        last_name: "Contact"
      )

      assert :ok = run_detection(account.id)

      assert pending_candidates(account.id) == []
    end

    test "handles zero contacts gracefully", %{account: account} do
      assert :ok = run_detection(account.id)

      assert pending_candidates(account.id) == []
    end
  end

  describe "cron mode" do
    test "runs for all accounts when no account_id provided" do
      {account1, _} = setup_account()
      {account2, _} = setup_account()

      insert(:contact,
        account: account1,
        display_name: "John Smith",
        first_name: "John",
        last_name: "Smith"
      )

      insert(:contact,
        account: account1,
        display_name: "John Smithe",
        first_name: "John",
        last_name: "Smithe"
      )

      insert(:contact,
        account: account2,
        display_name: "Jane Doe",
        first_name: "Jane",
        last_name: "Doe"
      )

      insert(:contact,
        account: account2,
        display_name: "Jane Doee",
        first_name: "Jane",
        last_name: "Doee"
      )

      assert :ok = perform_job(DuplicateDetectionWorker, %{})

      assert length(pending_candidates(account1.id)) == 1
      assert length(pending_candidates(account2.id)) == 1
    end
  end
end
