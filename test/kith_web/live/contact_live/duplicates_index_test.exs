defmodule KithWeb.ContactLive.DuplicatesIndexTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user, account_id: user.account_id}
  end

  defp candidate!(account_id, one, two, score \\ 0.9) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: score,
      reasons: ["email_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    })
  end

  test "four duplicates render as one cluster entry", ctx do
    [a, b, c, d] =
      for name <- ~w(Ann Bea Cal Dee) do
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: name})
      end

    candidate!(ctx.account_id, a, b)
    candidate!(ctx.account_id, b, c)
    candidate!(ctx.account_id, c, d)

    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "1 possible duplicate"
    assert html =~ "4 contacts"

    for name <- ~w(Ann Bea Cal Dee), do: assert(html =~ name)
  end

  test "each cluster links to its cluster screen", ctx do
    a = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Ann"})
    b = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Bea"})
    candidate!(ctx.account_id, a, b)

    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "/contacts/duplicates/cluster/#{min(a.id, b.id)}"
  end

  test "shows the empty state when nothing is pending", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "No duplicates found"
  end
end
