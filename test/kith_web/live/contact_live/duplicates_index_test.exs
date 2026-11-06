defmodule KithWeb.ContactLive.DuplicatesIndexTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user, account_id: user.account_id}
  end

  defp candidate!(account_id, one, two, status \\ "pending", score \\ 0.9) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: score,
      reasons: ["email_match"],
      status: status,
      resolved_at: if(status != "pending", do: DateTime.utc_now(:second)),
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

  test "load_more_duplicates loads the next page of clusters", ctx do
    pairs =
      for i <- 1..21 do
        a = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "A#{i}"})
        b = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "B#{i}"})
        candidate!(ctx.account_id, a, b)
        {a, b}
      end

    {last_a, _last_b} = List.last(pairs)

    {:ok, live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "21 possible duplicates"
    assert html =~ "Load more"
    refute html =~ last_a.display_name

    html = live |> element("button", "Load more") |> render_click()

    assert html =~ last_a.display_name
    refute html =~ "Load more"
  end

  test "a dismissed pair keeps two contacts out of the same rendered cluster", ctx do
    a = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Ann"})
    b = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Bea"})
    c = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Cal"})

    # Ann and Cal were reviewed and rejected as a match; Bea links to both, so
    # the dismissal must block Bea's group from reuniting them by
    # transitivity — Cal is left as an unrendered singleton.
    candidate!(ctx.account_id, a, c, "dismissed")
    candidate!(ctx.account_id, a, b)
    candidate!(ctx.account_id, b, c)

    {:ok, _live, html} = live(ctx.conn, ~p"/contacts/duplicates")

    assert html =~ "1 possible duplicate"
    assert html =~ "2 contacts"
    assert html =~ a.display_name
    assert html =~ b.display_name
    refute html =~ c.display_name
  end
end
