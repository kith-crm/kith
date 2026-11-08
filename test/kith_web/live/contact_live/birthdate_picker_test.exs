defmodule KithWeb.ContactLive.BirthdatePickerTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Repo}
  alias Kith.Contacts.Contact
  alias Kith.DAV.VCardAdapter

  setup :register_and_log_in_user

  setup %{user: user} do
    seed_reference_data!()
    %{account_id: user.account_id}
  end

  test "create a yearless leap-day birthday and publish it to DAV", c do
    {:ok, view, _} = live(c.conn, ~p"/contacts/new")
    assert has_element?(view, "[phx-hook=BirthdatePicker]")

    view
    |> form("#contact-form")
    |> render_submit(%{
      contact: %{
        first_name: "Leap birthday",
        birthdate: "2000-02-29",
        birthdate_year_unknown: "true"
      }
    })

    assert_redirect(view)
    contact = Repo.get_by!(Contact, account_id: c.account_id, first_name: "Leap birthday")
    assert contact.birthdate == ~D[2000-02-29]
    assert contact.birthdate_year_unknown
    assert VCardAdapter.contact_to_vcard(contact, version: :v40) =~ "BDAY:--0229"
  end

  test "edit an imported yearless birthday, restore its year, and clear it", c do
    contact =
      contact_fixture(c.account_id, %{birthdate: ~D[2000-02-29], birthdate_year_unknown: true})

    {:ok, view, _} = live(c.conn, ~p"/contacts/#{contact.id}/edit")
    assert has_element?(view, "[data-unknown][checked]")

    view
    |> form("#contact-form")
    |> render_submit(%{contact: %{birthdate: "2000-03-04", birthdate_year_unknown: "true"}})

    assert_redirect(view)
    assert Repo.reload!(contact).birthdate_year_unknown
    assert Repo.reload!(contact).birthdate == ~D[2000-03-04]

    {:ok, view, _} = live(c.conn, ~p"/contacts/#{contact.id}/edit")

    view
    |> form("#contact-form")
    |> render_submit(%{contact: %{birthdate: "1992-03-04", birthdate_year_unknown: "false"}})

    assert_redirect(view)
    refute Repo.reload!(contact).birthdate_year_unknown
    assert Repo.reload!(contact).birthdate == ~D[1992-03-04]
    assert VCardAdapter.contact_to_vcard(Repo.reload!(contact), version: :v40) =~ "BDAY:19920304"

    {:ok, view, _} = live(c.conn, ~p"/contacts/#{contact.id}/edit")

    view
    |> form("#contact-form")
    |> render_submit(%{contact: %{birthdate: "", birthdate_year_unknown: "false"}})

    assert_redirect(view)
    assert Repo.reload!(contact).birthdate == nil
    refute VCardAdapter.contact_to_vcard(Repo.reload!(contact)) =~ "BDAY:"
  end

  test "invalid known-year leap day is rejected and unrelated edits preserve a yearless birthday",
       c do
    contact =
      contact_fixture(c.account_id, %{birthdate: ~D[2000-02-29], birthdate_year_unknown: true})

    {:ok, view, _} = live(c.conn, ~p"/contacts/#{contact.id}/edit")

    view
    |> form("#contact-form")
    |> render_submit(%{contact: %{birthdate: "2025-02-29", birthdate_year_unknown: "false"}})

    assert has_element?(view, "#contact-form", "is invalid")
    assert Repo.reload!(contact).birthdate == ~D[2000-02-29]
    assert Repo.reload!(contact).birthdate_year_unknown

    {:ok, view, _} = live(c.conn, ~p"/contacts/#{contact.id}/edit")
    view |> form("#contact-form", %{contact: %{occupation: "Updated"}}) |> render_submit()
    assert_redirect(view)
    assert Repo.reload!(contact).occupation == "Updated"
    assert Repo.reload!(contact).birthdate_year_unknown
    assert Contacts.get_contact!(c.account_id, contact.id).birthdate == ~D[2000-02-29]
  end
end
