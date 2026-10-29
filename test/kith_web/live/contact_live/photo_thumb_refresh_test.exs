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

  test "an unrelated parent update retains the signed URL until an explicit refresh", %{
    conn: conn,
    contact: contact
  } do
    photo = photo_fixture(contact, %{"file_name" => "cached.jpg"})
    {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
    original_img = view |> element("#photo-#{photo.id} img") |> render()
    assert original_img =~ "https://s3.example.com/"

    # If the parent update resolves the URL again, the new origin makes the
    # regression observable even when signing happens within the same hour.
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.moved.example", port: 443)

    view
    |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
    |> render_click()

    cached_img = view |> element("#photo-#{photo.id} img") |> render()
    assert cached_img =~ "https://s3.example.com/"
    refute cached_img =~ "https://s3.moved.example/"

    view |> with_target("#photo-#{photo.id}") |> render_hook("refresh_url", %{})
    assert_reply(view, %{changed: true})
    assert view |> element("#photo-#{photo.id} img") |> render() =~ "https://s3.moved.example/"
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
