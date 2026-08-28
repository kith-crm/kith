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
        "input[phx-click='toggle-value'][phx-value-type='contact_fields'][phx-value-id='#{loser_field.id}']"
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
      |> element("input[phx-click='toggle-value'][phx-value-type='aliases'][phx-value-id='007']")
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
               "input[phx-click='toggle-value'][phx-value-type='contact_fields'][phx-value-id='#{field.id}']"
             )
             |> render_click() =~ "changed since you opened"
    end

    test "a viewer cannot open the screen", ctx do
      viewer = AccountsFixtures.user_fixture(%{role: "viewer"})

      assert {:error, {:live_redirect, %{to: "/contacts"}}} =
               live(log_in_user(build_conn(), viewer), cluster_path(ctx.a, ctx.b))
    end
  end

  describe "immich" do
    setup ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [
          immich_person_id: "person-a",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-01-01 00:00:00Z]
        ]
      )

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [
          immich_person_id: "person-b",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-02-01 00:00:00Z]
        ]
      )

      ctx
    end

    test "renders one row naming each linked member, not four id rows", ctx do
      {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert html =~ "Photo library"
      refute html =~ "person-a"
      refute html =~ "immich_person_id"
    end

    test "offers an unlink option and one option per linked member", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='#{ctx.a.id}']")
      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='#{ctx.b.id}']")
      assert has_element?(live, "button[phx-click='choose-immich'][phx-value-id='none']")
    end

    test "choosing a member adopts that member's whole group", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      survivor = Kith.Repo.get!(Kith.Contacts.Contact, survivor_id)

      assert survivor.immich_person_id == "person-b"
      assert survivor.immich_status == "linked"
    end

    # Controller ruling S7: `immich_status` is `null: false` with a check
    # constraint, so "Not linked" must set it to the string "unlinked" (as
    # `MergeResolution.resolve_immich/3` already does when no member is
    # linked), not `:clear` — which the engine maps to `nil` and would raise
    # a `Postgrex.Error` at the database. This must MERGE, not just render,
    # to actually reach that constraint.
    test "choosing not linked persists immich_status unlinked, not a crash", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='none']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      survivor = Kith.Repo.get!(Kith.Contacts.Contact, survivor_id)

      assert survivor.immich_status == "unlinked"
      assert is_nil(survivor.immich_person_id)
    end

    # `:__immich__` is UI bookkeeping and must never reach `merge_cluster/4`
    # as a field. `Merge.validate_fields/2` reduces over every entry in
    # `fields` and dispatches non-`:clear`, non-computed values to
    # `held_by_member?/3`, whose first act is `Map.fetch!(member, field)` on
    # a `Contact` struct — `:__immich__` holds an integer id or `:none`, so
    # leaving it in would raise an unhandled `KeyError`, not silently drop.
    # Only a successful merge after choosing an Immich source proves it was
    # stripped cleanly.
    test "choosing an immich source still allows the merge to submit", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.a.id}']")
      |> render_click()

      assert {:error, {:redirect, %{to: _path}}} =
               live |> element("button[phx-click='merge']") |> render_click()
    end

    # Adopting all four columns together, checked on every field including
    # `immich_person_url` (never set by the fixtures above) and
    # `immich_last_synced_at` (never read back above) — asserting only
    # `immich_person_id`/`immich_status` would leave half the unit-move
    # guarantee unverified.
    test "choosing a member adopts all four immich columns, not just two", ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [immich_person_url: "https://immich.example/person/person-b"]
      )

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      survivor = Kith.Repo.get!(Kith.Contacts.Contact, survivor_id)

      assert survivor.immich_person_id == "person-b"
      assert survivor.immich_person_url == "https://immich.example/person/person-b"
      assert survivor.immich_status == "linked"
      assert survivor.immich_last_synced_at == ~U[2026-02-01 00:00:00Z]
    end

    # Unreachable through the rendered UI (the row only offers buttons for
    # selected linked members) but not unreachable through a crafted
    # `phx-click` payload — and if it were adopted, it would sail through
    # `validate_fields/2` unchallenged, since slice 1 exempts the Immich
    # group from `held_by_member?/3`. The handler must re-check membership
    # against the selection, not `socket.assigns.members`. A three-member
    # cluster is needed here: deselecting down to one member disables the
    # merge button, and re-selecting a member resets `overrides` wholesale
    # (see `handle_event("toggle-member", ...)`), erasing the evidence — so
    # the deselected member must stay deselected while two others remain
    # selected and mergeable.
    test "choosing a deselected member's id does not adopt their immich group", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          company: "Deselected Co"
        })

      candidate!(ctx.account_id, ctx.a, c)

      Kith.Repo.update_all(from(ct in Kith.Contacts.Contact, where: ct.id == ^c.id),
        set: [
          immich_person_id: "person-c",
          immich_status: "linked",
          immich_last_synced_at: ~U[2026-03-01 00:00:00Z]
        ]
      )

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("input[phx-click='toggle-member'][phx-value-id='#{c.id}']")
      |> render_click()

      render_click(live, "choose-immich", %{"id" => to_string(c.id)})

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      survivor = Kith.Repo.get!(Kith.Contacts.Contact, survivor_id)

      assert survivor.immich_person_id != "person-c"
    end

    test "the row is hidden when no member is linked", ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [immich_person_id: nil, immich_status: "unlinked", immich_last_synced_at: nil]
      )

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [immich_person_id: nil, immich_status: "unlinked", immich_last_synced_at: nil]
      )

      {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      refute html =~ "Photo library"
    end

    test "not linked shows selected after being clicked, and can switch back to a member", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='none']")
      |> render_click()

      assert live
             |> element("button[phx-click='choose-immich'][phx-value-id='none']")
             |> render() =~ "border-[var(--color-accent)]"

      live
      |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.a.id}']")
      |> render_click()

      refute live
             |> element("button[phx-click='choose-immich'][phx-value-id='none']")
             |> render() =~ "border-[var(--color-accent)]"

      assert live
             |> element("button[phx-click='choose-immich'][phx-value-id='#{ctx.a.id}']")
             |> render() =~ "border-[var(--color-accent)]"
    end
  end

  # Spec B6: "Resolved rows show the value plus attribution and are
  # click-to-change, opening in place as a segmented control including 'Leave
  # empty'." The section header tells the user every value is clickable, so the
  # non-conflict branch has to render controls rather than inert spans.
  describe "resolved rows are editable (B6/B7)" do
    test "a resolved row exposes its candidates as a segmented control", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # middle_name is held by b alone, so it resolves without a conflict.
      assert has_element?(live, "button[phx-value-field='middle_name'][phx-value-index='0']")

      assert live
             |> element("button[phx-value-field='middle_name'][phx-value-index='0']")
             |> render() =~ "Jiyoung"
    end

    test "a resolved clearable row offers Leave empty and clears through to the merge", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(
               live,
               "button[phx-value-field='middle_name'][phx-value-index='clear']"
             )

      live
      |> element("button[phx-value-field='middle_name'][phx-value-index='clear']")
      |> render_click()

      assert {:error, {:redirect, %{to: path}}} =
               live |> element("button[phx-click='merge']") |> render_click()

      survivor_id = path |> String.split("/") |> List.last() |> String.to_integer()
      assert Kith.Repo.get!(Kith.Contacts.Contact, survivor_id).middle_name == nil
    end

    # B7's actual scenario: first_name is normally *resolved*, so this is the
    # rule the existing contested-first_name test only covers as a carve-out.
    test "the resolved first_name row offers candidates but no Leave empty", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert has_element?(live, "button[phx-value-field='first_name'][phx-value-index='0']")
      refute has_element?(live, "button[phx-value-field='first_name'][phx-value-index='clear']")
    end
  end

  # Spec B1: every mergeable scalar is on screen. The Immich group moves as one
  # unit and has its own control, and a coupled year-unknown flag is derived
  # from whichever member supplied its date — neither is a row of its own.
  describe "field coverage (B1)" do
    test "every mergeable field outside the Immich and coupled groups has a row", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      shown =
        Kith.Contacts.MergeFields.all() --
          (Kith.Contacts.MergeFields.immich_fields() ++ Kith.Contacts.MergeFields.coupled_flags())

      for field <- shown do
        assert has_element?(live, "[data-field='#{field}']"),
               "no row rendered for mergeable field #{field}"
      end
    end

    test "a coupled year-unknown flag gets no row of its own", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Picking the flag independently of its date is what produces a contact
      # claiming the placeholder year 1900 is a known birth year.
      for flag <- Kith.Contacts.MergeFields.coupled_flags() do
        refute has_element?(live, "[data-field='#{flag}']"),
               "coupled flag #{flag} rendered as an independent control"
      end
    end

    test "the policy flags state the resolved value, not a control", ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [is_archived: true, favorite: true]
      )

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # "the most engaged interpretation wins": favorite if any, archived only
      # if every member is archived.
      assert live |> element("[data-field='favorite']") |> render() =~ "Yes"
      assert live |> element("[data-field='is_archived']") |> render() =~ "No"

      refute has_element?(live, "[data-field='favorite'] button")
      refute has_element?(live, "[data-field='is_archived'] button")
    end
  end

  describe "association rows (§3)" do
    setup ctx do
      woman =
        Kith.Repo.insert!(%Kith.Contacts.Gender{name: "Woman", account_id: ctx.account_id})

      man = Kith.Repo.insert!(%Kith.Contacts.Gender{name: "Man", account_id: ctx.account_id})

      Map.merge(ctx, %{woman: woman, man: man})
    end

    test "a contested gender renders the gender's name, not its id", ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [gender_id: ctx.woman.id]
      )

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [gender_id: ctx.man.id]
      )

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      rendered =
        live |> element("button[phx-value-field='gender_id'][phx-value-index='0']") |> render()

      assert rendered =~ "Woman" or rendered =~ "Man"
      refute rendered =~ to_string(ctx.woman.id)
      refute rendered =~ to_string(ctx.man.id)
    end

    # The engine's `clear_member_self_reference/2` coerces a member id to
    # `:clear`, so offering one is offering a value that silently disappears.
    test "a member id is never offered as a first-met-through candidate", ctx do
      outsider =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Mutual",
          last_name: "Friend"
        })

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [first_met_through_id: ctx.b.id]
      )

      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
        set: [first_met_through_id: outsider.id]
      )

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Exactly one candidate survives the filter — the non-member — and it
      # renders as that contact's name.
      assert live
             |> element("button[phx-value-field='first_met_through_id'][phx-value-index='0']")
             |> render() =~ "Mutual Friend"

      refute has_element?(
               live,
               "button[phx-value-field='first_met_through_id'][phx-value-index='1']"
             )
    end

    test "a row whose only candidate was a member renders cleared with the reason", ctx do
      Kith.Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
        set: [first_met_through_id: ctx.b.id]
      )

      {:ok, live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      refute has_element?(
               live,
               "button[phx-value-field='first_met_through_id'][phx-value-index='0']"
             )

      assert html =~ "a contact cannot be met through a record it just absorbed"
    end
  end

  describe "section state" do
    # Contact details starts folded and is the only place value pruning
    # happens; a `<details>` with an id and no `open` attribute loses a
    # user-set `open` on every LiveView patch, so pruning N values would cost
    # 2N clicks.
    test "an opened section stays open across an unrelated re-render", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      refute has_element?(live, "details#section-contact-details[open]")

      live
      |> element("summary[phx-value-section='contact_details']")
      |> render_click()

      assert has_element?(live, "details#section-contact-details[open]")

      live
      |> element("button[phx-click='set-primary'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

      assert has_element?(live, "details#section-contact-details[open]")
    end
  end

  describe "drop payload keys" do
    # `drop_key/1` must not match the literal display labels the template
    # supplies ("Fields"/"Addresses"/"Tags"). If it did, a copy edit or an i18n
    # pass would make it return nil for everything, `build_drop/1` return `%{}`,
    # and every unchecked value silently come back on the survivor.
    test "value rows are keyed on section identifiers, not display copy", ctx do
      email_type =
        Kith.Repo.one!(
          from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
        )

      ContactsFixtures.contact_field_fixture(ctx.a, email_type.id, %{"value" => "x@y.com"})
      {:ok, _} = Kith.Contacts.update_contact(ctx.b, %{"aliases" => ["Sass"]})

      {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # The rows that exist are keyed on the section identifier…
      assert html =~ ~s(phx-value-type="contact_fields")
      assert html =~ ~s(phx-value-type="aliases")

      # …and every section, populated or not, is identified the same way.
      for {key, label} <- [
            {"contact_fields", "Fields"},
            {"addresses", "Addresses"},
            {"tags", "Tags"},
            {"aliases", "Aliases"}
          ] do
        assert html =~ ~s(data-field="#{key}")
        refute html =~ ~s(phx-value-type="#{label}")
        # The label is still displayed — it is just not the key.
        assert html =~ ">#{label}</p>"
      end
    end
  end

  # Spec G2 is "open **or** submit". A viewer cannot mount, so reaching the
  # submit needs a role downgrade against an already-open screen (or a reused
  # socket) — driven here by handing the handler that exact socket.
  describe "permissions on submit (G2)" do
    setup ctx do
      viewer_scope = Kith.Accounts.Scope.for_user(%{ctx.user | role: "viewer"})
      members = [ctx.a, ctx.b]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: viewer_scope,
          members: members,
          selected_ids: MapSet.new([ctx.a.id, ctx.b.id]),
          primary_id: ctx.a.id,
          overrides: %{},
          dropped: MapSet.new(),
          resolution: Kith.Contacts.MergeResolution.resolve(members, ctx.a.id),
          error: nil
        }
      }

      Map.put(ctx, :socket, socket)
    end

    test "a viewer submitting a merge is refused, not merged", ctx do
      assert {:noreply, socket} =
               KithWeb.ContactLive.ClusterMerge.handle_event("merge", %{}, ctx.socket)

      assert {:live, :redirect, %{to: "/contacts"}} = socket.redirected
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.b.id).deleted_at == nil
      assert Kith.Repo.get!(Kith.Contacts.Contact, ctx.a.id).deleted_at == nil
    end

    test "a viewer submitting not duplicates is refused, not dismissed", ctx do
      assert {:noreply, socket} =
               KithWeb.ContactLive.ClusterMerge.handle_event("not-duplicates", %{}, ctx.socket)

      assert {:live, :redirect, %{to: "/contacts"}} = socket.redirected

      assert Kith.Repo.all(from(d in Kith.Contacts.DuplicateCandidate, select: d.status)) == [
               "pending"
             ]
    end
  end

  describe "not-null columns are never offered as clearable" do
    # `:clear` becomes `nil` at the database, so a `NOT NULL` column raises a
    # 23502 outside the engine's `{:error, reason}` contract. The year-unknown
    # flags are coupled fields and render no control at all, so the guard that
    # has to hold on this screen is over the choice fields.
    test "no non-clearable choice field renders a Leave empty button", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      non_clearable =
        Enum.filter(
          Kith.Contacts.MergeFields.choice_fields(),
          &Kith.Contacts.MergeFields.non_clearable?/1
        )

      # Guards the assertion below against silently becoming vacuous.
      assert non_clearable != []

      for field <- non_clearable do
        assert has_element?(live, "[data-field='#{field}']")

        refute has_element?(
                 live,
                 "button[phx-value-field='#{field}'][phx-value-index='clear']"
               ),
               "non-clearable field #{field} offered a Leave empty button"
      end
    end

    test "coupled year-unknown flags are never reachable as a clear target", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      for flag <- Kith.Contacts.MergeFields.coupled_flags() do
        refute has_element?(live, "button[phx-value-field='#{flag}'][phx-value-index='clear']")
      end
    end
  end

  describe "manual entry" do
    test "a contact in no cluster renders alone", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, _live, html} = live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}")

      assert html =~ "Dana"
      assert html =~ "Add contact"
      refute html =~ "Sarah"
    end

    test "merge is disabled until a second member is added", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      mate = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dara"})

      {:ok, live, _html} = live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}")

      assert has_element?(live, "button[phx-click='merge'][disabled]")

      live |> form("form[phx-change='search']", %{query: "Dara"}) |> render_change()

      live
      |> element("button[phx-click='add-member'][phx-value-id='#{mate.id}']")
      |> render_click()

      assert has_element?(live, "button[phx-click='merge']")
      refute has_element?(live, "button[phx-click='merge'][disabled]")
    end

    test "the manual screen says nothing about matches or duplicates", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, _live, html} = live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}")

      refute html =~ "Matched on"
      refute html =~ "possible duplicate"
      assert html =~ "1 contact ·"
      assert html =~ "Pick the contacts to merge into one."
    end

    test "a detected cluster still says what it matched on", ctx do
      {:ok, _live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert html =~ "2 possible duplicates ·"
      assert html =~ "Matched on"
      refute html =~ "Pick the contacts to merge into one."
    end

    test "a contact id from another account is refused", ctx do
      other = AccountsFixtures.user_fixture()
      stranger = ContactsFixtures.contact_fixture(other.account_id, %{first_name: "Zed"})

      assert {:error, {:live_redirect, %{to: "/contacts"}}} =
               live(ctx.conn, "/contacts/duplicates/cluster/#{stranger.id}")
    end
  end

  describe "identity section state" do
    # Identity opens itself while a conflict is outstanding, so this only bites
    # on a fully-resolved cluster — which is exactly where B6's click-to-change
    # rows are the reason to open it at all.
    test "identity stays open across an edit on a fully resolved cluster", ctx do
      c =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Priya", last_name: "Nair"})

      d =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Priya", last_name: "Nair"})

      candidate!(ctx.account_id, c, d)

      {:ok, live, _html} = live(ctx.conn, cluster_path(c, d))

      refute has_element?(live, "details#section-identity[open]")

      live
      |> element("summary[phx-value-section='identity']")
      |> render_click()

      assert has_element?(live, "details#section-identity[open]")

      live
      |> element("button[phx-value-field='first_name'][phx-value-index='0']")
      |> render_click()

      assert has_element?(live, "details#section-identity[open]")
    end
  end

  describe "crafted event payloads" do
    # `phx-value-*` is client-controlled, so nothing stops a crafted payload
    # naming an atom that exists on the node but is not a Contact key —
    # `:page_title`, `:flash`, an assign name. Reaching `Map.fetch!/2` with one
    # kills the LiveView process, as does a non-numeric id reaching
    # `String.to_integer/1`.
    test "an unknown field name is ignored rather than crashing the view", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      for field <- ["page_title", "flash", "definitely_not_an_atom_anywhere", ""] do
        render_click(live, "choose-field", %{"field" => field, "index" => "0"})
        render_click(live, "choose-field", %{"field" => field, "index" => "clear"})
      end

      assert has_element?(live, "[data-field='first_name']")
    end

    test "a policy or coupled field cannot be driven through choose-field", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # These resolve by policy or by coupling, never by choice — accepting an
      # override for them would let the client bypass that resolution.
      for field <-
            Kith.Contacts.MergeFields.policy_fields() ++
              Kith.Contacts.MergeFields.coupled_flags() do
        render_click(live, "choose-field", %{"field" => to_string(field), "index" => "clear"})
      end

      assert has_element?(live, "[data-field='first_name']")
    end

    test "a non-numeric id is ignored by every id-carrying handler", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      for id <- ["abc", "1x", "", "-1", "9999999999999999999999"] do
        render_click(live, "toggle-member", %{"id" => id})
        render_click(live, "set-primary", %{"id" => id})
        render_click(live, "choose-immich", %{"id" => id})
      end

      assert has_element?(live, "[data-field='first_name']")
    end

    test "an unknown section name is ignored by toggle-section", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      for section <- ["page_title", "nope_not_a_section", "contact_fields", ""] do
        render_click(live, "toggle-section", %{"section" => section})
      end

      assert has_element?(live, "[data-field='first_name']")
    end
  end

  describe "add contact search" do
    test "searching excludes current members, offers a new match", ctx do
      third =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Sarah", last_name: "Kim"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = live |> form("form[phx-change='search']", %{query: "Sarah"}) |> render_change()

      assert html =~ ~s(phx-click="add-member" phx-value-id="#{third.id}")
      refute html =~ ~s(phx-click="add-member" phx-value-id="#{ctx.a.id}")
      refute html =~ ~s(phx-click="add-member" phx-value-id="#{ctx.b.id}")
    end

    test "adding a contact puts it in the strip, checked", ctx do
      dana = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live |> form("form[phx-change='search']", %{query: "Dana"}) |> render_change()

      html =
        live
        |> element("button[phx-click='add-member'][phx-value-id='#{dana.id}']")
        |> render_click()

      assert html =~ "Merge 3 contacts"
      assert has_element?(live, "input[phx-click='toggle-member'][phx-value-id='#{dana.id}']")
    end

    test "an added member creates a conflict the section flags", ctx do
      # `ctx.a` and `ctx.b` already contest `company`, so the screen opens on
      # one conflict; the added member contests `occupation` with `ctx.a` and
      # must push that count to two.
      Kith.Repo.update!(Ecto.Changeset.change(ctx.a, occupation: "Engineer"))

      third =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          occupation: "Designer"
        })

      {:ok, live, html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert html =~ "1 needs a decision"

      live |> form("form[phx-change='search']", %{query: "Sarah"}) |> render_change()

      html =
        live
        |> element("button[phx-click='add-member'][phx-value-id='#{third.id}']")
        |> render_click()

      assert html =~ "2 need a decision"
      assert html =~ "Designer"
      assert html =~ "Engineer"
    end

    test "a query shorter than the threshold returns nothing", ctx do
      dana = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # "D" would match Dana on any of the searched columns — only the
      # two-character threshold keeps it out.
      html = live |> form("form[phx-change='search']", %{query: "D"}) |> render_change()

      refute html =~ ~s(phx-click="add-member" phx-value-id="#{dana.id}")

      html = live |> form("form[phx-change='search']", %{query: "Da"}) |> render_change()

      assert html =~ ~s(phx-click="add-member" phx-value-id="#{dana.id}")
    end

    test "search never surfaces a contact from another account", ctx do
      other_user = AccountsFixtures.user_fixture()

      stranger =
        ContactsFixtures.contact_fixture(other_user.account_id, %{
          first_name: "Sarah",
          last_name: "Kim"
        })

      # A same-account match the search must offer, so the refute below is
      # about account scoping and not about there being nothing to find.
      mine =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Sarah", last_name: "Park"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = live |> form("form[phx-change='search']", %{query: "Sarah"}) |> render_change()

      assert html =~ ~s(phx-click="add-member" phx-value-id="#{mine.id}")
      refute html =~ ~s(phx-click="add-member" phx-value-id="#{stranger.id}")
    end

    test "adding the same contact twice leaves one member entry", ctx do
      dana = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live |> form("form[phx-change='search']", %{query: "Dana"}) |> render_change()

      live
      |> element("button[phx-click='add-member'][phx-value-id='#{dana.id}']")
      |> render_click()

      # The result list is cleared on add, so a repeat can only arrive as a
      # crafted event — which is exactly the case the guard is for.
      html = render_click(live, "add-member", %{"id" => to_string(dana.id)})

      assert html =~ "Merge 3 contacts"

      assert Regex.scan(~r/phx-click="toggle-member"\s+phx-value-id="#{dana.id}"/, html)
             |> length() == 1
    end

    test "a non-numeric add-member id is ignored", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = render_click(live, "add-member", %{"id" => "x"})

      assert html =~ "Merge 2 contacts"
    end
  end

  describe "merge selected (?with=)" do
    test "does not pre-select cluster members the user never picked", ctx do
      alice =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smith"
        })

      bob =
        ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Bob", last_name: "Jones"})

      # Dana is a pending duplicate of Alice, but the user did not tick her.
      dana =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smyth"
        })

      candidate!(ctx.account_id, alice, dana)

      [lead, other] = Enum.sort([alice.id, bob.id])

      {:ok, live, html} =
        live(ctx.conn, "/contacts/duplicates/cluster/#{lead}?with=#{other}")

      # Dana is visible — she may well be a duplicate — but unchecked.
      assert html =~ dana.display_name
      refute has_element?(live, "input[phx-value-id='#{dana.id}'][checked]")
      assert has_element?(live, "input[phx-value-id='#{alice.id}'][checked]")
      assert has_element?(live, "input[phx-value-id='#{bob.id}'][checked]")
    end

    test "a ?with= id that is already in the lead's detected cluster is still selected",
         ctx do
      alice =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smith"
        })

      # Dana is a pending duplicate of Alice, AND the user explicitly ticked
      # her — she must end up selected even though she's already a member
      # via the detected cluster (so absent from `extra`).
      dana =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smyth"
        })

      candidate!(ctx.account_id, alice, dana)

      {:ok, live, _html} =
        live(ctx.conn, "/contacts/duplicates/cluster/#{alice.id}?with=#{dana.id}")

      assert has_element?(live, "input[phx-value-id='#{dana.id}'][checked]")
    end

    test "a plain cluster URL still selects the whole cluster", ctx do
      alice =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smith"
        })

      dana =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Alice",
          last_name: "Smyth"
        })

      candidate!(ctx.account_id, alice, dana)

      {:ok, live, _html} = live(ctx.conn, cluster_path(alice, dana))

      assert has_element?(live, "input[phx-value-id='#{alice.id}'][checked]")
      assert has_element?(live, "input[phx-value-id='#{dana.id}'][checked]")
    end

    test "caps the ?with= list", ctx do
      lead =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Lead",
          last_name: "Contact"
        })

      others =
        for i <- 1..60,
            do:
              ContactsFixtures.contact_fixture(ctx.account_id, %{
                first_name: "Extra#{i}",
                last_name: "X"
              })

      with_param = others |> Enum.map(& &1.id) |> Enum.join(",")

      {:ok, _live, html} =
        live(ctx.conn, "/contacts/duplicates/cluster/#{lead.id}?with=#{with_param}")

      assert html =~ "51 contacts"
    end
  end

  describe "old routes" do
    test "the merge wizard route no longer exists", ctx do
      # This app's endpoint renders a 404 page for unmatched routes rather
      # than letting Phoenix.Router.NoRouteError propagate to the caller
      # (see config :kith, KithWeb.Endpoint, render_errors: ... in
      # config/config.exs), so we assert on the rendered 404 response.
      conn = get(ctx.conn, "/contacts/#{ctx.a.id}/merge")

      assert conn.status == 404
    end

    test "the contact page links to the cluster screen", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/contacts/#{ctx.a.id}")

      assert html =~ "/contacts/duplicates/cluster/#{ctx.a.id}"
      refute html =~ "/contacts/#{ctx.a.id}/merge"
    end
  end

  describe "untrusted event payloads" do
    test "add-member ignores an id that is not among the offered results", ctx do
      outsider = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Zoe"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # Never searched for, so it was never rendered as an add-member button.
      html = render_click(live, "add-member", %{"id" => to_string(outsider.id)})

      assert html =~ "Merge 2 contacts"
      refute html =~ "Zoe"
    end

    test "toggle-member ignores an id wider than the column", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = render_click(live, "toggle-member", %{"id" => "99999999999999999999"})

      assert html =~ "Merge 2 contacts"
    end

    test "set-primary survives a non-numeric id instead of crashing", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # `ctx.a` is the default primary, so only `ctx.b` is offered the button.
      html = render_click(live, "set-primary", %{"id" => "abc"})

      assert html =~ ~s(phx-click="set-primary" phx-value-id="#{ctx.b.id}")
      refute html =~ ~s(phx-click="set-primary" phx-value-id="#{ctx.a.id}")
    end

    test "choose-field refuses a negative index instead of counting from the end", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      # `Enum.at/2` reads -1 as the *last* candidate, so an unguarded handler
      # would select a value the user never clicked.
      render_click(live, "choose-field", %{"field" => "company", "index" => "-1"})

      last =
        live
        |> element(
          ~s(button[phx-click="choose-field"][phx-value-field="company"][phx-value-index="1"])
        )
        |> render()

      refute last =~ "border-[var(--color-accent)] bg-[var(--color-accent)]"
    end

    test "an oversized id in the with param is dropped, not sent to the database", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Zoe"})

      {:ok, _live, html} =
        live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}?with=99999999999999999999")

      assert html =~ "1 contact ·"
      assert html =~ "Zoe"
    end
  end

  describe "malformed event payloads" do
    test "non-binary ids are ignored rather than crashing", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      for event <- ["toggle-member", "set-primary", "add-member", "choose-immich"] do
        assert render_hook(live, event, %{"id" => 5})
        assert Process.alive?(live.pid)
      end
    end

    test "non-binary field index is ignored", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert render_hook(live, "choose-field", %{"field" => "company", "index" => 0})
      assert Process.alive?(live.pid)
    end

    test "non-binary search query is ignored", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      assert render_hook(live, "search", %{"query" => 12_345})
      assert Process.alive?(live.pid)
    end
  end
end
