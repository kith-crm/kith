defmodule KithWeb.ContactLive.PetsComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  test "a pet born 29 February renders its age in any year", %{user: user} do
    account_id = user.account_id
    contact = contact_fixture(account_id)

    {:ok, _pet} =
      Kith.Pets.create_pet(account_id, %{
        contact_id: contact.id,
        name: "Leapy",
        species: "dog",
        date_of_birth: ~D[2020-02-29]
      })

    today = Date.utc_today()

    # Independent of the production helper: in a common year the anniversary is 28 Feb.
    anniversary =
      Date.new!(today.year, 2, if(Calendar.ISO.leap_year?(today.year), do: 29, else: 28))

    years = today.year - 2020 - if(Date.compare(anniversary, today) == :gt, do: 1, else: 0)

    expected =
      if years > 0,
        do: "(#{years}y)",
        else: "(#{(today.year - 2020) * 12 + today.month - 2}mo)"

    html =
      render_component(KithWeb.ContactLive.PetsComponent,
        id: "pets-#{contact.id}",
        contact_id: contact.id,
        account_id: account_id,
        can_edit: false
      )

    assert html =~ "Leapy"
    assert html =~ expected
  end
end
