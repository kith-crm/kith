defmodule KithWeb.ContactLive.MergeSelectedTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()

    a = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Ann"})
    b = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Bea"})
    c = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Cal"})

    %{conn: log_in_user(conn, user), user: user, account_id: user.account_id, a: a, b: b, c: c}
  end

  defp candidate!(account_id, one, two, status) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: 0.9,
      reasons: ["email_match"],
      status: status,
      detected_at: DateTime.utc_now(:second)
    })
  end

  test "selecting contacts reveals a merge action", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/contacts")

    html =
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{ctx.a.id}']")
      |> render_click()

    refute html =~ "Merge selected"

    html =
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

    assert html =~ "Merge selected"
    assert html =~ "2 selected"
  end

  test "merge selected opens the cluster screen with those members", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/contacts")

    for contact <- [ctx.a, ctx.b, ctx.c] do
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{contact.id}']")
      |> render_click()
    end

    assert {:error, {:live_redirect, %{to: path}}} =
             live |> element("a[data-role='merge-selected']") |> render_click()

    {:ok, _merge_live, html} = live(ctx.conn, path)

    assert html =~ "Merge 3 contacts"
    for name <- ~w(Ann Bea Cal), do: assert(html =~ name)
  end

  test "contacts from a URL are refused if they belong to another account", ctx do
    other = AccountsFixtures.user_fixture()
    stranger = ContactsFixtures.contact_fixture(other.account_id, %{first_name: "Zed"})

    {:ok, _live, html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{stranger.id}")

    refute html =~ "Zed"
    assert html =~ "Ann"
  end

  test "merging past a dismissal resolves the dismissed candidate to merged", ctx do
    candidate!(ctx.account_id, ctx.a, ctx.b, "dismissed")

    {:ok, live, _html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{ctx.b.id}")

    assert {:error, {:redirect, %{to: to}}} =
             live |> element("button", "Merge 2 contacts") |> render_click()

    assert to =~ "/contacts/"

    survivor_id = ctx.a.id
    loser_id = ctx.b.id

    assert Kith.Contacts.get_contact(ctx.account_id, survivor_id)
    refute Kith.Contacts.get_contact(ctx.account_id, loser_id)

    candidate =
      Kith.Repo.get_by!(Kith.Contacts.DuplicateCandidate,
        account_id: ctx.account_id,
        contact_id: min(ctx.a.id, ctx.b.id),
        duplicate_contact_id: max(ctx.a.id, ctx.b.id)
      )

    assert candidate.status == "merged"
  end
end
