defmodule Kith.Workers.PhoneRenormalizeWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts.ContactField
  alias Kith.Repo
  alias Kith.Workers.PhoneRenormalizeWorker

  setup do
    seed_reference_data!()

    # Default account locale is "en" — see Account schema, which maps to "US"
    # via PhoneFormatter.region_for_locale/1.
    user = user_fixture()
    account_id = user.account_id

    phone_type =
      Repo.one!(
        from t in "contact_field_types",
          where: t.protocol == "tel:",
          select: %{id: t.id},
          limit: 1
      )

    email_type =
      Repo.one!(
        from t in "contact_field_types",
          where: t.protocol == "mailto:",
          select: %{id: t.id},
          limit: 1
      )

    %{
      account_id: account_id,
      phone_type_id: phone_type.id,
      email_type_id: email_type.id
    }
  end

  defp insert_phone_raw(account_id, contact_id, phone_type_id, value) do
    # Bypass changeset normalization so we can stash heuristic-era values that
    # the new PhoneFormatter.normalize/2 would reject going forward.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "contact_fields",
        [
          %{
            account_id: account_id,
            contact_id: contact_id,
            contact_field_type_id: phone_type_id,
            value: value,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id
  end

  describe "perform/1" do
    test "rewrites bare US phones to E.164 using account locale",
         %{account_id: account_id, phone_type_id: phone_type_id} do
      contact = contact_fixture(account_id)
      id = insert_phone_raw(account_id, contact.id, phone_type_id, "2025550100")

      assert :ok = perform_job(PhoneRenormalizeWorker, %{account_id: account_id})

      assert Repo.get!(ContactField, id).value == "+12025550100"
    end

    test "leaves valid E.164 values untouched (idempotence)",
         %{account_id: account_id, phone_type_id: phone_type_id} do
      contact = contact_fixture(account_id)
      id = insert_phone_raw(account_id, contact.id, phone_type_id, "+12025550100")

      assert :ok = perform_job(PhoneRenormalizeWorker, %{account_id: account_id})
      assert Repo.get!(ContactField, id).value == "+12025550100"

      # Re-run — should be a no-op.
      assert :ok = perform_job(PhoneRenormalizeWorker, %{account_id: account_id})
      assert Repo.get!(ContactField, id).value == "+12025550100"
    end

    test "leaves unparseable values alone instead of clobbering",
         %{account_id: account_id, phone_type_id: phone_type_id} do
      contact = contact_fixture(account_id)
      id = insert_phone_raw(account_id, contact.id, phone_type_id, "+")

      assert :ok = perform_job(PhoneRenormalizeWorker, %{account_id: account_id})

      # "+" is unparseable; PhoneFormatter.normalize returns it trimmed-as-is.
      assert Repo.get!(ContactField, id).value == "+"
    end

    test "does not touch email values",
         %{account_id: account_id, email_type_id: email_type_id} do
      contact = contact_fixture(account_id)
      field = contact_field_fixture(contact, email_type_id, %{"value" => "user@example.com"})

      assert :ok = perform_job(PhoneRenormalizeWorker, %{account_id: account_id})
      assert Repo.get!(ContactField, field.id).value == "user@example.com"
    end
  end

  describe "perform/1 all-accounts mode" do
    test "iterates every account when no account_id arg supplied",
         %{phone_type_id: phone_type_id} do
      # Each user_fixture creates its own account. Insert one bare number per
      # account; both should get rewritten to E.164.
      user1 = user_fixture()
      user2 = user_fixture()

      c1 = contact_fixture(user1.account_id)
      c2 = contact_fixture(user2.account_id)

      id1 = insert_phone_raw(user1.account_id, c1.id, phone_type_id, "2025550100")
      id2 = insert_phone_raw(user2.account_id, c2.id, phone_type_id, "2025550101")

      assert :ok = perform_job(PhoneRenormalizeWorker, %{})

      assert Repo.get!(ContactField, id1).value == "+12025550100"
      assert Repo.get!(ContactField, id2).value == "+12025550101"
    end
  end
end
