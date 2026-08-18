defmodule KithWeb.ContactLive.ClusterMergeTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    account_id = user.account_id

    a =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Sarah",
        last_name: "Kim",
        company: "Figma"
      })

    b =
      ContactsFixtures.contact_fixture(account_id, %{
        first_name: "Sarah",
        last_name: "Kim",
        company: "Stripe",
        middle_name: "Jiyoung"
      })

    candidate!(account_id, a, b)

    %{conn: log_in_user(conn, user), user: user, account_id: account_id, a: a, b: b}
  end

  defp candidate!(account_id, one, two) do
    {low, high} = if one.id < two.id, do: {one, two}, else: {two, one}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: account_id,
      contact_id: low.id,
      duplicate_contact_id: high.id,
      score: 0.9,
      reasons: ["email_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    })
  end

  defp cluster_path(a, b), do: "/contacts/duplicates/cluster/#{min(a.id, b.id)}"

  test "renders every member with a checkbox", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Merge 2 contacts"
    assert html =~ ~s(phx-value-id="#{ctx.a.id}")
    assert html =~ ~s(phx-value-id="#{ctx.b.id}")
  end

  test "renders an agreed field with its attribution and no choice", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "all 2 agree"
    assert html =~ "Sarah"
  end

  test "renders a gap-filled field attributed to its only source", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Jiyoung"
    assert html =~ "only"
  end

  test "renders a contested field as a choice and flags the section", ctx do
    {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert html =~ "Figma"
    assert html =~ "Stripe"
    assert html =~ "1 needs a decision"
  end

  test "a section with a conflict is open, one without is folded", ctx do
    {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert has_element?(live, "details#section-identity[open]")
    refute has_element?(live, "details#section-contact-details[open]")
  end

  test "required fields offer no Leave empty option", ctx do
    {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    refute has_element?(live, "button[phx-value-field='first_name'][phx-value-index='clear']")
  end

  test "clearable contested fields do offer a Leave empty option", ctx do
    {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

    assert has_element?(live, "button[phx-value-field='company'][phx-value-index='clear']")
  end

  test "an unknown contact id renders not found", ctx do
    assert {:error, {:live_redirect, %{to: "/contacts"}}} =
             live(ctx.conn, "/contacts/duplicates/cluster/0")
  end

  test "a non-numeric contact id redirects instead of raising", ctx do
    assert {:error, {:live_redirect, %{to: "/contacts"}}} =
             live(ctx.conn, "/contacts/duplicates/cluster/abc")
  end

  test "a resolved section says so instead of just staying folded", ctx do
    c =
      ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Priya", last_name: "Nair"})

    d =
      ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Priya", last_name: "Nair"})

    candidate!(ctx.account_id, c, d)

    {:ok, _live, html} = live(ctx.conn, cluster_path(c, d))

    assert html =~ "all resolved"
  end

  test "a viewer hitting the cluster route is redirected to /contacts", ctx do
    viewer = AccountsFixtures.user_fixture(%{role: "viewer"})
    viewer_conn = log_in_user(build_conn(), viewer)

    assert {:error, {:live_redirect, %{to: "/contacts"}}} =
             live(viewer_conn, cluster_path(ctx.a, ctx.b))
  end

  test "a member id from another account does not resolve", ctx do
    other_user = AccountsFixtures.user_fixture()

    other_contact =
      ContactsFixtures.contact_fixture(other_user.account_id, %{first_name: "Other"})

    assert {:error, {:live_redirect, %{to: "/contacts"}}} =
             live(ctx.conn, "/contacts/duplicates/cluster/#{other_contact.id}")
  end
end
