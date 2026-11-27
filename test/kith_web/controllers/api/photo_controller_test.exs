defmodule KithWeb.API.PhotoControllerTest do
  use KithWeb.ConnCase, async: false

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Accounts, AvatarFixtures, Contacts, Storage}

  @tag :tmp_dir
  test "repeated multipart uploads return the original photo", %{conn: conn, tmp_dir: root} do
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    user = user_fixture()
    {token, _} = Accounts.generate_api_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    contact = contact_fixture(user.account_id)
    endpoint = ~p"/api/contacts/#{contact.id}/photos"
    bytes = AvatarFixtures.image_binary()

    path = Path.join(root, "upload.png")
    File.write!(path, bytes)

    upload = %Plug.Upload{path: path, filename: "first.png", content_type: "image/png"}
    first = conn |> post(endpoint, %{"file" => upload}) |> json_response(201)
    assert [original] = Contacts.list_photos(contact.id)

    assert %{
             "data" => %{
               "id" => original.id,
               "contact_id" => contact.id,
               "file_name" => "first.png",
               "inserted_at" => DateTime.to_iso8601(original.inserted_at)
             }
           } == first

    second =
      conn
      |> post(endpoint, %{"file" => %{upload | filename: "second.png"}})
      |> json_response(201)

    assert second == first
    assert [stored] = Contacts.list_photos(contact.id)
    assert stored.id == original.id
    assert {:ok, ^bytes} = Storage.read(stored.storage_key)
  end
end
