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
end
