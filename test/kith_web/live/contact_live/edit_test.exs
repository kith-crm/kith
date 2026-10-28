defmodule KithWeb.ContactLive.EditTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    seed_reference_data!()
    contact = contact_fixture(user.account_id)
    %{contact: contact, account_id: user.account_id}
  end

  describe "edit page" do
    test "renders edit form", %{conn: conn, contact: contact} do
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}/edit")
      assert html =~ "Edit"
      assert html =~ contact.first_name
    end

    test "saves contact successfully without socket crash", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}/edit")

      view
      |> form("#contact-form", %{contact: %{first_name: "Updated"}})
      |> render_submit()

      # Should redirect to show page (not crash the socket)
      flash = assert_redirect(view, ~p"/contacts/#{contact.id}")
      assert flash["info"] =~ "updated"

      # Verify DB was updated
      updated = Kith.Contacts.get_contact!(contact.account_id, contact.id)
      assert updated.first_name == "Updated"
    end

    test "family-only contacts allow unrelated edits without requiring a given name", %{
      conn: conn,
      account_id: account_id
    } do
      contact = contact_fixture(account_id, %{first_name: "", last_name: "Family Only"})
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}/edit")
      refute has_element?(view, "input[name='contact[first_name]'][required]")

      view
      |> form("#contact-form", %{contact: %{occupation: "Updated occupation"}})
      |> render_submit()

      assert_redirect(view, ~p"/contacts/#{contact.id}")
      updated = Kith.Contacts.get_contact!(account_id, contact.id)
      assert updated.first_name == ""
      assert updated.last_name == "Family Only"
      assert updated.display_name == "Family Only"
      assert updated.occupation == "Updated occupation"
    end

    test "shows validation errors for invalid data", %{conn: conn, contact: contact} do
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}/edit")

      html =
        view
        |> form("#contact-form", %{contact: %{first_name: "", last_name: ""}})
        |> render_submit()

      # Should stay on the page with errors, not crash
      assert html =~ "contact-form"
      assert has_element?(view, "#contact-form", "can't be blank")
    end
  end
end
