defmodule KithWeb.API.ContactImportControllerTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures

  alias Kith.Accounts

  test "CDV-117: one card that is not UTF-8 is reported, the other cards import", %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)

    card = fn name ->
      "BEGIN:VCARD\r\nVERSION:3.0\r\nN:#{name};Rest;;;\r\nFN:Rest #{name}\r\nEND:VCARD\r\n"
    end

    dir = Path.join(System.tmp_dir!(), "cdv117-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "mixed.vcf")
    File.write!(path, card.("Zoë") <> card.(<<"Zo", 0xEB>>) <> card.("Ünal"))

    upload = %Plug.Upload{path: path, filename: "mixed.vcf", content_type: "text/vcard"}

    body =
      conn
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> post(~p"/api/contacts/import", %{"file" => upload})
      |> json_response(200)

    assert body["imported"] == 2
    assert body["skipped"] == 1
    assert [error] = body["errors"]
    assert error =~ "Entry 2"
    assert error =~ "UTF-8"
  end
end
