defmodule KithWeb.API.ContactImportBoundaryTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures

  test "JSON file paths cannot impersonate server-owned multipart uploads", %{conn: conn} do
    user = user_fixture()
    {token, _} = Kith.Accounts.generate_api_token(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/contacts/import", %{"file" => %{"path" => "/etc/passwd"}})

    assert %{"status" => 422, "detail" => "Expected a multipart file upload."} =
             json_response(conn, 422)

    assert Kith.Contacts.count_contacts(user.account_id) == 0
  end
end
