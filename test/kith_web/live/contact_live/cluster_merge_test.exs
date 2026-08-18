defmodule KithWeb.ContactLive.ClusterMergeTest do
  use KithWeb.ConnCase

  import Ecto.Query
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

  describe "interactions" do
    test "unchecking a member recomputes the result", ctx do
      {:ok, live, html0} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # "Jiyoung" (b's middle name) appears both in b's own member chip and in
      # the resolved middle_name row's value + attribution — the chip stays
      # (unchecked members are dimmed, not removed) but the resolved row must
      # drop it once b is no longer part of the selection.
      occurrences_before = html0 |> String.split("Jiyoung") |> length()

      html =
        live
        |> element("input[phx-click='toggle-member'][phx-value-id='#{ctx.b.id}']")
        |> render_click()

      occurrences_after = html |> String.split("Jiyoung") |> length()

      assert html =~ "Merge 1 contacts" or html =~ "1 selected"
      assert occurrences_after < occurrences_before
    end

    test "choosing a conflicting value marks it selected", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # candidates_for/2, sorted, ties broken by lowest member id: index 0 is
      # a's "Figma", index 1 is b's "Stripe" — so clicking index 1 must move
      # the accent styling onto the Stripe button specifically, not merely
      # cause "Figma" to still appear (it's a candidate label either way).
      live
      |> element("button[phx-value-field='company'][phx-value-index='1']")
      |> render_click()

      assert has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='1'][class*='bg-[var(--color-accent)]']"
             )

      refute has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='0'][class*='bg-[var(--color-accent)]']"
             )
    end

    test "changing the selection discards an explicit choice", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          company: "Notion"
        })

      candidate!(ctx.account_id, ctx.b, c)

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Three members, one value each (Figma/Stripe/Notion): candidates_for/2
      # sorts by lowest member id on a count tie, so index 2 is c's "Notion" —
      # an explicit choice that is nobody's computed default, so it can only
      # still be selected after the toggle below if the override survived.
      live
      |> element("button[phx-value-field='company'][phx-value-index='2']")
      |> render_click()

      live
      |> element("input[phx-click='toggle-member'][phx-value-id='#{c.id}']")
      |> render_click()

      # Back to the computed default (a's "Figma", the surviving lowest-id
      # member) rather than the discarded override.
      assert has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='0'][class*='bg-[var(--color-accent)]']"
             )
    end

    test "unchecking a value removes it from the merge", ctx do
      email_type =
        Kith.Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      field =
        ContactsFixtures.contact_field_fixture(ctx.b, email_type.id, %{"value" => "x@y.com"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(
               live,
               "input[phx-click='toggle-value'][phx-value-id='#{field.id}'][checked]"
             )

      live
      |> element("input[phx-click='toggle-value'][phx-value-id='#{field.id}']")
      |> render_click()

      refute has_element?(
               live,
               "input[phx-click='toggle-value'][phx-value-id='#{field.id}'][checked]"
             )
    end

    test "making another member primary moves the badge", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
      refute has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.a.id}']")

      live
      |> element("button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      # The badge (and its "make primary" button) moved to a, off of b.
      refute has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
      assert has_element?(live, "button[phx-click='set-primary'][phx-value-id='#{ctx.a.id}']")
    end

    test "unchecking the last selected member is refused, not stranded unchecked", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("input[phx-click='toggle-member'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      html =
        live
        |> element("input[phx-click='toggle-member'][phx-value-id='#{ctx.a.id}']")
        |> render_click()

      assert html =~ "At least one contact must stay selected"

      assert has_element?(
               live,
               "input[phx-click='toggle-member'][phx-value-id='#{ctx.a.id}'][checked]"
             )
    end

    test "a numeric-looking alias can still be dropped", ctx do
      {:ok, member} = Kith.Contacts.update_contact(ctx.a, %{"aliases" => ["007"]})

      {:ok, live, _html} = live(ctx.conn, cluster_path(member, ctx.b))

      assert has_element?(live, "input[phx-click='toggle-value'][phx-value-id='007'][checked]")

      live
      |> element("input[phx-click='toggle-value'][phx-value-id='007']")
      |> render_click()

      refute has_element?(live, "input[phx-click='toggle-value'][phx-value-id='007'][checked]")
    end

    test "choosing Leave empty on a clearable contested field records a :clear override", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html =
        live
        |> element("button[phx-value-field='company'][phx-value-index='clear']")
        |> render_click()

      # The clear button itself now reads as the selected choice for the row.
      assert html =~ ~s(phx-value-field="company")

      assert has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='clear'][class*='bg-[var(--color-accent)]']"
             )

      refute has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='0'][class*='bg-[var(--color-accent)]']"
             )

      refute has_element?(
               live,
               "button[phx-value-field='company'][phx-value-index='1'][class*='bg-[var(--color-accent)]']"
             )
    end

    test "a genuinely contested required field offers candidates but no Leave empty option",
         ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "David",
          last_name: "Kim"
        })

      d =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Priya",
          last_name: "Kim"
        })

      candidate!(ctx.account_id, c, d)

      {:ok, live, html} = live(ctx.conn, cluster_path(c, d))

      assert html =~ "David"
      assert html =~ "Priya"
      assert has_element?(live, "button[phx-value-field='first_name'][phx-value-index='0']")
      assert has_element?(live, "button[phx-value-field='first_name'][phx-value-index='1']")
      refute has_element?(live, "button[phx-value-field='first_name'][phx-value-index='clear']")
    end
  end
end
