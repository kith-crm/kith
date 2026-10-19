defmodule KithWeb.ContactLive.PhotoThumbRefreshTest do
  # Reconfigures the global S3 env mid-test.
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    Kith.TestEnv.configure_s3()
    %{contact: contact_fixture(user.account_id)}
  end

  test "refresh_url replies changed: true and re-renders the new src when the URL moves", %{
    conn: conn,
    contact: contact
  } do
    photo = photo_fixture(contact, %{"file_name" => "moved.jpg"})
    {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")

    assert html =~ "https://s3.example.com/"

    # The signed URL changes without the storage key changing (what an hour
    # rollover does): repoint the endpoint between render and event.
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.moved.example", port: 443)

    view |> with_target("#photo-#{photo.id}") |> render_hook("refresh_url", %{})

    assert_reply(view, %{changed: true})

    img = view |> element("#photo-#{photo.id} img") |> render()
    assert img =~ "https://s3.moved.example/"
    refute img =~ "s3.example.com"
  end
end
