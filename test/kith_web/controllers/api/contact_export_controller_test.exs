defmodule KithWeb.API.ContactExportControllerTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Accounts
  alias Kith.VCard.Parser

  setup %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw_token}"), user: user}
  end

  test "GET /api/contacts/export.vcf exports every active contact", %{conn: conn, user: user} do
    for i <- 1..105, do: contact_fixture(user.account_id, %{first_name: "Export #{i}"})
    other = user_fixture()
    contact_fixture(other.account_id, %{first_name: "Other account"})
    deleted = contact_fixture(user.account_id, %{first_name: "Deleted"})
    Kith.Contacts.soft_delete_contact(deleted)
    conn = get(conn, ~p"/api/contacts/export.vcf")
    assert conn.status == 200
    assert {:ok, contacts} = Parser.parse(conn.resp_body)
    assert length(contacts) == 105
    refute Enum.any?(contacts, &(&1.first_name in ["Deleted", "Other account"]))
  end
end
