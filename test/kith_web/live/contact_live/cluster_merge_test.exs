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

  describe "submitting" do
    test "merging redirects to the survivor and trashes the rest", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      loser_id = if survivor_id == ctx.a.id, do: ctx.b.id, else: ctx.a.id

      assert Kith.Repo.get!(Kith.Contacts.Contact, loser_id).deleted_at != nil
      assert Kith.Repo.get!(Kith.Contacts.Contact, survivor_id).deleted_at == nil
    end

    test "merging with a member unchecked dismisses that pair", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Sarah", last_name: "Kim"})

      candidate!(ctx.account_id, ctx.b, c)

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("input[phx-click='toggle-member'][phx-value-id='#{c.id}']")
      |> render_click()

      assert {:error, {:redirect, _}} =
               live |> element("button[phx-click='merge']") |> render_click()

      # The pair the user rejected is dismissed. Its `b` endpoint is a loser, so
      # `resolve_after_merge/4` also repoints the row onto the survivor — assert
      # on every surviving pair that touches `c` rather than on `(b, c)`, which
      # no longer exists by that key.
      statuses =
        Kith.Repo.all(
          from(d in Kith.Contacts.DuplicateCandidate,
            where: d.contact_id == ^c.id or d.duplicate_contact_id == ^c.id,
            select: d.status
          )
        )

      assert statuses == ["dismissed"]

      # An unchecked member is not a loser — it must still be an active contact.
      assert Kith.Repo.get!(Kith.Contacts.Contact, c.id).deleted_at == nil
    end

    # Ruling S5: the engine dedupes the survivor's own rows *before* it applies
    # `drop`, so naming only the row the user clicked is not enough. Here the
    # loser's row is the lower id (the one the screen renders as checkable) and
    # the survivor holds the equivalent higher-id row: dropping only the clicked
    # id would leave the survivor's row untouched and the excluded value would
    # come back on the merged contact.
    test "unchecking a value shared by two members drops every row backing it", ctx do
      email_type =
        Kith.Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      # Inserted on the loser first, so its row id is below the survivor's.
      loser_field =
        ContactsFixtures.contact_field_fixture(ctx.b, email_type.id, %{
          "value" => "sarah@example.com"
        })

      survivor_field =
        ContactsFixtures.contact_field_fixture(ctx.a, email_type.id, %{
          "value" => "sarah@example.com"
        })

      assert loser_field.id < survivor_field.id

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Only the first row of an equal-value group is checkable; the later one
      # renders disabled as "duplicate · dropped".
      live
      |> element(
        "input[phx-click='toggle-value'][phx-value-type='Fields'][phx-value-id='#{loser_field.id}']"
      )
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      assert path == "/contacts/#{ctx.a.id}"

      values =
        Kith.Repo.all(
          from(f in Kith.Contacts.ContactField,
            where: f.contact_id == ^ctx.a.id,
            select: f.value
          )
        )

      refute "sarah@example.com" in values
    end

    # Aliases are a whole-array field carried in `fields`, never in `drop`, so
    # this is the only path that proves the subtraction reaches the database.
    # "007" is deliberately numeric-looking: it also pins
    # `cast_entry_id("Aliases", id)` end to end, which a render-only test can't.
    test "unchecking an alias keeps it off the merged contact", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          aliases: ["007", "Bond"]
        })

      candidate!(ctx.account_id, ctx.a, c)

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("input[phx-click='toggle-value'][phx-value-type='Aliases'][phx-value-id='007']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      assert path == "/contacts/#{ctx.a.id}"

      # Asserted against the persisted array, not the payload: the subtraction
      # reads `:aliases` off the already-override-merged map, so it is only
      # correct because it runs after that merge.
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.a.id).aliases == ["Bond"]
    end

    test "not duplicates dismisses the cluster and returns to the list", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert {:error, {:redirect, %{to: "/contacts/duplicates"}}} =
               live |> element("button[phx-click='not-duplicates']") |> render_click()

      assert Kith.DuplicateDetection.list_clusters(ctx.account_id) == []
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.b.id).deleted_at == nil
    end

    test "a member merged elsewhere produces an inline error, not a partial merge", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Another session trashes a member behind our back.
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      html = live |> element("button[phx-click='merge']") |> render_click()

      assert html =~ "changed since you opened"
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.a.id).deleted_at == nil

      # The screen stays usable after a failed merge.
      assert has_element?(live, "button[phx-click='merge']")
    end

    test "changing the resolution clears a stale merge error", ctx do
      email_type =
        Kith.Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      field =
        ContactsFixtures.contact_field_fixture(ctx.a, email_type.id, %{
          "value" => "sarah@example.com"
        })

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      assert live |> element("button[phx-click='merge']") |> render_click() =~
               "changed since you opened"

      refute live
             |> element("button[phx-value-field='company'][phx-value-index='0']")
             |> render_click() =~ "changed since you opened"

      assert live |> element("button[phx-click='merge']") |> render_click() =~
               "changed since you opened"

      refute live
             |> element(
               "input[phx-click='toggle-value'][phx-value-type='Fields'][phx-value-id='#{field.id}']"
             )
             |> render_click() =~ "changed since you opened"
    end

    test "a viewer cannot open the screen", ctx do
      viewer = AccountsFixtures.user_fixture(%{role: "viewer"})

      assert {:error, {:live_redirect, %{to: "/contacts"}}} =
               live(log_in_user(build_conn(), viewer), cluster_path(ctx.a, ctx.b))
    end
  end
end
