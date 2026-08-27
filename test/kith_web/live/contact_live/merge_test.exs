defmodule KithWeb.ContactLive.MergeTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    seed_reference_data!()

    survivor =
      contact_fixture(user.account_id, %{
        first_name: "Alice",
        last_name: "Smith",
        company: nil,
        occupation: "Designer"
      })

    loser =
      contact_fixture(user.account_id, %{
        first_name: "Alice",
        last_name: "S.",
        company: "Acme",
        occupation: nil
      })

    %{survivor: survivor, loser: loser, account_id: user.account_id}
  end

  # Opens the wizard already on step 2 with the loser selected. The `?with=`
  # param routes through `maybe_preselect_contact/3`, which is the same path
  # the duplicate-review screen links in with — and it avoids driving the
  # step-1 search, whose results are empty until a "search" event fires.
  defp open_on_step_two(conn, survivor, loser) do
    {:ok, view, _html} = live(conn, ~p"/contacts/#{survivor.id}/merge?with=#{loser.id}")
    view
  end

  # Merges without touching a single field radio.
  defp merge_without_choosing(conn, survivor, loser) do
    view = open_on_step_two(conn, survivor, loser)

    render_click(view, "go-to-preview", %{})
    render_click(view, "execute-merge", %{})

    view
  end

  describe "merging without touching any field radio" do
    test "fills a survivor gap from the loser instead of clearing it",
         %{conn: conn, survivor: survivor, loser: loser, account_id: account_id} do
      merge_without_choosing(conn, survivor, loser)

      merged = Kith.Contacts.get_contact!(account_id, survivor.id)
      assert merged.company == "Acme"
    end

    test "still protects a value the survivor already holds",
         %{conn: conn, survivor: survivor, loser: loser, account_id: account_id} do
      merge_without_choosing(conn, survivor, loser)

      merged = Kith.Contacts.get_contact!(account_id, survivor.id)
      assert merged.occupation == "Designer"
    end
  end

  describe "field choice radios" do
    test "an untouched field with a nil survivor value highlights the loser column",
         %{conn: conn, survivor: survivor, loser: loser} do
      view = open_on_step_two(conn, survivor, loser)

      survivor_button =
        view
        |> element(~s{button[phx-value-field="company"][phx-value-source="survivor"]})
        |> render()

      loser_button =
        view
        |> element(~s{button[phx-value-field="company"][phx-value-source="non_survivor"]})
        |> render()

      # `company` is nil on the survivor and "Acme" on the loser, so the
      # loser's value is the one that survives — the highlight must be on
      # that button, not the survivor's.
      assert loser_button =~ "color-accent-subtle"
      refute survivor_button =~ "color-accent-subtle"
    end

    test "an untouched field the survivor holds keeps the highlight on the survivor",
         %{conn: conn, survivor: survivor, loser: loser} do
      view = open_on_step_two(conn, survivor, loser)

      survivor_button =
        view
        |> element(~s{button[phx-value-field="occupation"][phx-value-source="survivor"]})
        |> render()

      loser_button =
        view
        |> element(~s{button[phx-value-field="occupation"][phx-value-source="non_survivor"]})
        |> render()

      # `occupation` is "Designer" on the survivor and nil on the loser, so
      # the survivor's value stands and its button keeps the highlight.
      assert survivor_button =~ "color-accent-subtle"
      refute loser_button =~ "color-accent-subtle"
    end

    test "an explicit survivor choice still pins a nil, clearing the field",
         %{conn: conn, survivor: survivor, loser: loser, account_id: account_id} do
      view = open_on_step_two(conn, survivor, loser)

      render_click(view, "choose-field", %{"field" => "company", "source" => "survivor"})
      render_click(view, "go-to-preview", %{})
      render_click(view, "execute-merge", %{})

      merged = Kith.Contacts.get_contact!(account_id, survivor.id)
      assert merged.company == nil
    end
  end
end
