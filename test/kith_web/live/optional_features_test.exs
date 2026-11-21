defmodule KithWeb.OptionalFeaturesTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  alias Kith.Accounts

  setup :register_and_log_in_user

  test "admin switches start off and refresh Journal navigation in an open tab", %{conn: conn} do
    {:ok, settings, _} = live(conn, ~p"/settings/account")
    {:ok, dashboard, _} = live(conn, ~p"/dashboard")

    assert Enum.count(
             LazyHTML.query(
               LazyHTML.from_fragment(render(settings)),
               "#optional-features [aria-checked=false]"
             )
           ) == 7

    refute has_element?(dashboard, "a[href='/journal']")
    assert {:error, {:redirect, %{to: unavailable}}} = live(conn, ~p"/journal")
    {:ok, explanation, _} = live(conn, unavailable)
    assert has_element?(explanation, "a[href='/settings/account#optional-features']")
    assert render(explanation) =~ "Journal is unavailable"

    settings |> element("#optional-feature-journal") |> render_click()
    assert has_element?(settings, "#optional-feature-journal[aria-checked=true]")
    assert has_element?(dashboard, "a[href='/journal']")

    {:ok, journal, _} = live(conn, ~p"/journal")
    journal |> element("button[phx-click='show-form']", "New Entry") |> render_click()
    assert has_element?(journal, "form[phx-submit='save-entry']")

    settings |> element("#optional-feature-journal") |> render_click()
    assert_redirect(journal, unavailable)
    refute has_element?(dashboard, "a[href='/journal']")
  end

  test "a stale Journal submit checks persisted flags before writing", %{conn: conn, user: user} do
    {:ok, enabled} = Accounts.set_optional_feature(user, "journal", true)
    {:ok, journal, _} = live(conn, ~p"/journal")

    # Simulate a submit arriving before the socket processes a change notification.
    {:ok, _} = Accounts.update_account(enabled, %{feature_flags: %{"journal" => false}})

    assert {:error, {:live_redirect, %{to: "/features/journal/unavailable"}}} =
             render_submit(journal, "save-entry", %{"entry" => %{"content" => "Stale draft"}})

    assert Kith.Journal.list_entries(user.account_id, author_id: user.id) == []
  end

  test "disabling Calls clears its filter and closes its open form", %{conn: conn, user: user} do
    {:ok, _} = Accounts.set_optional_feature(user, "calls", true)
    contact = contact_fixture(user.account_id)
    {:ok, _} = Kith.Activities.create_call(contact, %{occurred_at: DateTime.utc_now(:second)})
    note_fixture(contact, user.id, %{"body" => "Visible note"})

    {:ok, timeline, _} = live(conn, ~p"/contacts/#{contact.id}")
    timeline |> element("[phx-click='filter-toggle'][phx-value-type='call']") |> render_click()
    timeline |> element("[phx-click='open-entry-modal'][phx-value-type='call']") |> render_click()
    assert has_element?(timeline, "#entry-modal")

    {:ok, _} = Accounts.set_optional_feature(user, "calls", false)
    refute has_element?(timeline, "#entry-modal")
    refute has_element?(timeline, "[phx-value-type='call']")
    assert render(timeline) =~ "Call was turned off for this workspace."
    assert render(timeline) =~ "Visible note"

    {:ok, _} = Accounts.set_optional_feature(user, "calls", true)
    assert has_element?(timeline, "[id^='activity-call-']")
  end

  test "dashboard fills the feed with visible entries when newer calls are disabled", %{
    conn: conn,
    user: user
  } do
    contact = contact_fixture(user.account_id)

    for number <- 1..10 do
      note_fixture(contact, user.id, %{"body" => "Visible feed note #{number}"})

      {:ok, call} =
        Kith.Activities.create_call(contact, %{occurred_at: DateTime.utc_now(:second)})

      call |> Ecto.Changeset.change(inserted_at: ~U[2030-01-01 00:00:00Z]) |> Kith.Repo.update!()
    end

    {:ok, _} = Accounts.set_optional_feature(user, "calls", true)
    {:ok, dashboard, html} = live(conn, ~p"/dashboard")
    refute html =~ "Visible feed note"

    {:ok, _} = Accounts.set_optional_feature(user, "calls", false)
    html = render(dashboard)

    for number <- 1..10, do: assert(html =~ "Visible feed note #{number}")
  end

  test "Life Event Types and saved timeline entries return together", %{conn: conn, user: user} do
    contact = contact_fixture(user.account_id)
    {:ok, type} = Kith.Contacts.create_life_event_type(user.account_id, %{name: "Graduation"})

    {:ok, event} =
      Kith.Activities.create_life_event(contact, %{
        life_event_type_id: type.id,
        occurred_on: ~D[2024-01-01],
        note: "Graduated"
      })

    {:ok, timeline, _} = live(conn, ~p"/contacts/#{contact.id}")
    refute has_element?(timeline, "#activity-life_event-#{event.id}")

    assert {:error, {:redirect, %{to: "/features/life_events/unavailable"}}} =
             live(conn, ~p"/settings/life-event-types")

    {:ok, _} = Accounts.set_optional_feature(user, "life_events", true)
    {:ok, types, _} = live(conn, ~p"/settings/life-event-types")
    assert render(types) =~ "Graduation"
    assert has_element?(timeline, "#activity-life_event-#{event.id}")
  end

  for {type, feature} <- [{"task", "tasks"}, {"gift", "gifts"}, {"conversation", "conversations"}] do
    @type_key type
    @feature feature

    test "a stale #{type} submission is refused while the other history types stay available", %{
      conn: conn,
      user: user
    } do
      account =
        Kith.AccountsFixtures.enable_optional_features(user, Accounts.OptionalFeatures.keys())

      contact = contact_fixture(user.account_id)
      {:ok, timeline, _} = live(conn, ~p"/contacts/#{contact.id}")

      selector = "[phx-click='open-entry-modal'][phx-value-type='#{@type_key}']"
      timeline |> element(selector) |> render_click()
      assert has_element?(timeline, "#entry-modal")

      flags = Map.put(account.feature_flags, @feature, false)
      {:ok, _} = Accounts.update_account(account, %{feature_flags: flags})

      timeline
      |> with_target("#activity-stream")
      |> render_submit("save-entry", %{"entry" => %{}})

      refute has_element?(timeline, "#entry-modal")
      refute has_element?(timeline, selector)
      assert has_element?(timeline, "[phx-click='open-entry-modal'][phx-value-type='call']")
      assert has_element?(timeline, "[role='status']", "turned off")
    end
  end

  test "import history reports a checkpointed skip before its worker slice completes", %{
    conn: conn,
    user: user
  } do
    import =
      Kith.ImportsFixtures.import_fixture(user.account_id, user.id, %{source: "monica_api"})

    {:ok, _} =
      Kith.Imports.update_import_status(import, "completed", %{
        summary: %{"misc_progress" => %{"42" => %{"calls" => %{"calls_feature_disabled" => 1}}}}
      })

    {:ok, history, _} = live(conn, ~p"/settings/imports/#{import.id}")

    assert has_element?(
             history,
             "p",
             ~r/Calls skipped for 1 contact\s+because the feature was disabled/
           )
  end
end
