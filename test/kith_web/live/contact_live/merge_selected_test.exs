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

  test "repeated ids in the with param yield exactly one member entry", ctx do
    {:ok, _live, html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{ctx.b.id},#{ctx.b.id}")

    assert html =~ "Merge 2 contacts"

    assert Regex.scan(
             ~r/phx-click="toggle-member"\s+phx-value-id="#{ctx.b.id}"/,
             html
           )
           |> length() == 1
  end

  test "the primary is re-derived over every member of the with param", ctx do
    # `merge_selected_path/1` leads with the lowest id, which carries no user
    # intent — the richest record has to win regardless of URL position.
    ContactsFixtures.note_fixture(ctx.b, ctx.user.id)
    ContactsFixtures.note_fixture(ctx.b, ctx.user.id)

    {:ok, live, _html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{ctx.b.id}")

    # "make primary" is offered for every selected member except the primary.
    assert has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.a.id}']")
    refute has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
  end

  test "a crafted merge with one member selected is refused", ctx do
    {:ok, live, _html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{ctx.b.id}")

    live
    |> element("input[phx-click='toggle-member'][phx-value-id='#{ctx.b.id}']")
    |> render_click()

    html = render_click(live, "merge", %{})

    assert html =~ "Pick at least two contacts to merge."
    assert Kith.Contacts.get_contact(ctx.account_id, ctx.b.id)
  end

  test "the reload link after a failed merge keeps every added member", ctx do
    {:ok, live, _html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{ctx.b.id},#{ctx.c.id}")

    # Trash a member behind the screen's back so the merge fails the way the
    # Reload link exists for.
    {:ok, _} = Kith.Contacts.soft_delete_contact(ctx.c)

    html = live |> element("button", "Merge 3 contacts") |> render_click()

    assert html =~ "changed since you opened this page"

    assert [[_, reload]] = Regex.scan(~r|href="(/contacts/duplicates/cluster/[^"]*)"|, html)

    reload = reload |> String.replace("&amp;", "&") |> URI.decode()

    assert reload =~ "with="

    for id <- [ctx.a.id, ctx.b.id, ctx.c.id] do
      assert reload =~ to_string(id)
    end
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
