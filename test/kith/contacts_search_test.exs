defmodule Kith.ContactsSearchTest do
  use Kith.DataCase

  alias Kith.{AccountsFixtures, Contacts, ContactsFixtures}

  setup do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()

    for n <- 1..5 do
      ContactsFixtures.contact_fixture(user.account_id, %{
        first_name: "Sam",
        last_name: "Number#{n}"
      })
    end

    %{account_id: user.account_id}
  end

  test "without options every match comes back, tags preloaded", ctx do
    results = Contacts.search_contacts(ctx.account_id, "Sam")

    assert length(results) == 5
    assert Enum.all?(results, &is_list(&1.tags))
  end

  test "the limit is applied by the database, not by the caller", ctx do
    assert length(Contacts.search_contacts(ctx.account_id, "Sam", limit: 2)) == 2
  end

  test "preload_tags: false leaves tags unloaded", ctx do
    [contact | _] = Contacts.search_contacts(ctx.account_id, "Sam", preload_tags: false)

    assert %Ecto.Association.NotLoaded{} = contact.tags
  end

  test "limit keeps the alphabetically first matches, not the oldest rows", ctx do
    # Created oldest-first, named reverse-alphabetically, so id order and
    # display_name order disagree on every row.
    for name <- ["Zoe Adams", "Yara Adams", "Xena Adams"] do
      [first, last] = String.split(name, " ")
      ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: first, last_name: last})
    end

    # Created last (highest id), sorts first by name.
    ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Aaron", last_name: "Adams"})

    results = Contacts.search_contacts(ctx.account_id, "Adams", limit: 2)

    assert Enum.map(results, & &1.display_name) == ["Aaron Adams", "Xena Adams"]
  end

  test "results are ordered by display_name when unlimited", ctx do
    # guards against the outer ORDER BY being dropped by a later refactor
    ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Zoe", last_name: "Brown"})
    ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Amy", last_name: "Brown"})

    names = ctx.account_id |> Contacts.search_contacts("Brown") |> Enum.map(& &1.display_name)

    assert names == Enum.sort(names)
  end
end
