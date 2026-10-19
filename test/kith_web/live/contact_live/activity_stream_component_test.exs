defmodule KithWeb.ContactLive.ActivityStreamComponentTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    contact = contact_fixture(user.account_id)
    %{contact: contact, account_id: user.account_id}
  end

  describe "photo timeline entries" do
    test "timeline mode renders an <img> pointing at the storage URL", %{
      conn: conn,
      contact: contact
    } do
      photo = photo_fixture(contact, %{"file_name" => "beach.jpg"})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      assert html =~ ~s(src="#{Kith.Storage.url(photo.storage_key)}")
      assert html =~ ~s(alt="beach.jpg")
      assert html =~ "size-[72px] rounded-lg object-cover"
    end

    test "photos gallery mode renders an <img> for the tile", %{conn: conn, contact: contact} do
      photo = photo_fixture(contact, %{"file_name" => "portrait.jpg"})

      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

      html =
        view
        |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
        |> render_click()

      assert html =~ "grid-cols-3"
      assert html =~ ~s(src="#{Kith.Storage.url(photo.storage_key)}")
      assert html =~ "w-full h-full object-cover"
    end

    test "each thumbnail is an isolated stateful component with the 404 fallback wired", %{
      conn: conn,
      contact: contact
    } do
      photo = photo_fixture(contact, %{"file_name" => "hike.jpg"})

      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      # Stateful LiveComponent per photo -> its own change-tracking scope.
      assert html =~ ~s(id="photo-#{photo.id}")
      # CSP-safe broken-image detection instead of an inline onerror.
      assert html =~ ~s(phx-hook="ImgFallback")
      # Distinct "unavailable" state, hidden until the <img> actually errors.
      assert html =~ "Image unavailable"
      assert html =~ "group-data-[img-failed]:hidden"
    end

    test "refresh_url re-signs and replies whether the URL changed", %{
      conn: conn,
      contact: contact
    } do
      photo = photo_fixture(contact, %{"file_name" => "retry.jpg"})

      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")

      view |> with_target("#photo-#{photo.id}") |> render_hook("refresh_url", %{})

      # Local storage: same key -> same URL -> nothing to retry.
      assert_reply(view, %{changed: false})
      assert has_element?(view, ~s(#photo-#{photo.id}[data-refreshable="true"]))
    end

    test "timeline variant pins the failed-badge classes", %{conn: conn, contact: contact} do
      photo_fixture(contact)
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      assert html =~
               ~s|class="hidden group-data-[img-failed]:flex size-[72px] rounded-lg bg-amber-50 border border-amber-200 flex-col items-center justify-center text-amber-600 gap-0.5"|

      assert html =~ ~s|class="text-[9px] font-medium leading-tight text-center"|
    end

    test "tile variant pins the failed-badge classes", %{conn: conn, contact: contact} do
      photo_fixture(contact)
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      html = open_gallery(view)

      assert html =~
               ~s|class="hidden group-data-[img-failed]:flex w-full h-full bg-amber-50 border border-amber-200 flex-col items-center justify-center text-amber-600 gap-1"|

      assert html =~ ~s|class="text-[10px] font-medium"|
    end

    test "timeline variant pins the syncing classes", %{conn: conn, contact: contact} do
      photo_fixture(contact, %{"storage_key" => "pending_sync:immich-t1"})
      {:ok, _view, html} = live(conn, ~p"/contacts/#{contact.id}")

      assert html =~
               ~s|class="size-[72px] rounded-lg bg-gradient-to-br from-stone-100 to-stone-200 flex-col items-center justify-center text-[var(--color-text-tertiary)] inline-flex gap-0.5"|
    end

    test "tile variant pins the syncing classes", %{conn: conn, contact: contact} do
      photo_fixture(contact, %{"storage_key" => "pending_sync:immich-t2"})
      {:ok, view, _html} = live(conn, ~p"/contacts/#{contact.id}")
      html = open_gallery(view)

      assert html =~
               ~s|class="w-full h-full bg-gradient-to-br from-stone-100 to-stone-200 flex-col items-center justify-center text-[var(--color-text-tertiary)] flex gap-1"|
    end

    test "pending-sync photo keeps the placeholder and renders no image for it", %{
      conn: conn,
      contact: contact
    } do
      photo_fixture(contact, %{"storage_key" => "pending_sync:immich-abc123"})

      {:ok, view, html} = live(conn, ~p"/contacts/#{contact.id}")

      refute html =~ ~s(src="#{Kith.Storage.url("pending_sync:immich-abc123")}")
      assert html =~ "Syncing"
      assert html =~ "from-stone-100"

      # Also placeholder-only in gallery mode.
      gallery_html =
        view
        |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
        |> render_click()

      refute gallery_html =~ ~s(src="#{Kith.Storage.url("pending_sync:immich-abc123")}")
      assert gallery_html =~ "Syncing"
    end
  end

  defp open_gallery(view) do
    view
    |> element(~s|button[phx-click="filter-toggle"][phx-value-type="photo"]|)
    |> render_click()
  end

  describe "edit modal prefill" do
    defp click_edit(view, type, id) do
      view
      |> element(
        ~s|button[phx-click="edit-entry"][phx-value-type="#{type}"][phx-value-id="#{id}"]|
      )
      |> render_click()
    end

    test "note", %{conn: conn, contact: contact, user: user} do
      note =
        note_fixture(contact, user.id, %{"body" => "Met at the conference", "is_private" => true})

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")

      html = click_edit(view, "note", note.id)

      assert html =~ "Edit Note"
      assert has_element?(view, ~s|textarea[name="entry[body]"]|, "Met at the conference")
      assert has_element?(view, ~s|input[name="entry[is_private]"][checked]|)
    end

    test "private note can be made public via edit", %{conn: conn, contact: contact, user: user} do
      note = note_fixture(contact, user.id, %{"body" => "Secret", "is_private" => true})
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "note", note.id)

      assert has_element?(
               view,
               ~s|input[type="hidden"][name="entry[is_private]"][value="false"]|
             )

      view
      |> form("#entry-modal form", %{})
      |> render_submit(%{"entry" => %{"body" => "Secret", "is_private" => "false"}})

      refute Kith.Repo.get!(Kith.Contacts.Note, note.id).is_private
    end

    test "call", %{conn: conn, contact: contact, account_id: account_id} do
      call = call_for(contact, account_id)
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")

      click_edit(view, "call", call.id)

      assert has_element?(view, ~s|input[name="entry[occurred_at]"][value="2023-04-05T06:07"]|)
      assert has_element?(view, ~s|input[name="entry[duration_mins]"][value="42"]|)
      assert has_element?(view, ~s|textarea[name="entry[notes]"]|, "Talked about trip")
    end

    test "task", %{conn: conn, contact: contact, user: user, account_id: account_id} do
      {:ok, task} =
        Kith.Tasks.create_task(account_id, user.id, %{
          "title" => "Send photos",
          "description" => "From the trip",
          "due_date" => "2025-01-02",
          "contact_id" => contact.id
        })

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "task", task.id)

      assert has_element?(view, ~s|input[name="entry[title]"][value="Send photos"]|)
      assert has_element?(view, ~s|input[name="entry[due_date]"][value="2025-01-02"]|)
      assert has_element?(view, ~s|textarea[name="entry[description]"]|, "From the trip")
    end

    test "gift", %{conn: conn, contact: contact, user: user, account_id: account_id} do
      {:ok, gift} =
        Kith.Gifts.create_gift(account_id, user.id, %{
          "name" => "Book",
          "direction" => "received",
          "description" => "Signed copy",
          "contact_id" => contact.id
        })

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "gift", gift.id)

      assert has_element?(view, ~s|input[name="entry[name]"][value="Book"]|)

      assert has_element?(
               view,
               ~s|select[name="entry[direction]"] option[value="received"][selected]|
             )

      assert has_element?(view, ~s|textarea[name="entry[description]"]|, "Signed copy")
    end

    test "save without changes keeps the call unchanged", %{
      conn: conn,
      contact: contact,
      account_id: account_id
    } do
      call = call_for(contact, account_id)
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "call", call.id)

      view
      |> form("#entry-modal form", %{})
      |> render_submit(%{
        "entry" => %{
          "occurred_at" => "2023-04-05T06:07",
          "duration_mins" => "42",
          "notes" => "Talked about trip"
        }
      })

      assert Kith.Activities.get_call!(account_id, call.id).occurred_at ==
               ~U[2023-04-05 06:07:00Z]
    end

    test "new note after editing opens empty", %{conn: conn, contact: contact, user: user} do
      note = note_fixture(contact, user.id, %{"body" => "Met at the conference"})
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "note", note.id)

      view |> element(~s|button[phx-click="close-modal"]|, "Cancel") |> render_click()

      html =
        view
        |> element(~s|button[phx-click="open-entry-modal"][phx-value-type="note"]|)
        |> render_click()

      assert html =~ "New Note"
      refute has_element?(view, ~s|textarea[name="entry[body]"]|, "Met at the conference")
    end

    test "life event prefills and saves", %{conn: conn, contact: contact, account_id: account_id} do
      type = Kith.Repo.all(Kith.Contacts.LifeEventType) |> hd()

      {:ok, le} =
        Kith.Activities.create_life_event(contact, %{
          "life_event_type_id" => type.id,
          "occurred_on" => "2020-08-09",
          "note" => "Graduated"
        })

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "life_event", le.id)

      assert has_element?(view, ~s|input[name="entry[occurred_on]"][value="2020-08-09"]|)

      assert has_element?(
               view,
               ~s|select[name="entry[life_event_type_id]"] option[value="#{type.id}"][selected]|
             )

      assert has_element?(view, ~s|textarea[name="entry[note]"]|, "Graduated")

      html =
        view
        |> form("#entry-modal form", %{})
        |> render_submit(%{
          "entry" => %{
            "life_event_type_id" => to_string(type.id),
            "occurred_on" => "2020-08-09",
            "note" => "Graduated with honors"
          }
        })

      refute html =~ "text-red"
      assert Kith.Activities.get_life_event!(account_id, le.id).note == "Graduated with honors"
    end

    test "conversation prefills and saves", %{
      conn: conn,
      contact: contact,
      user: user,
      account_id: account_id
    } do
      {:ok, conv} =
        Kith.Conversations.create_conversation(account_id, user.id, %{
          "subject" => "Catch-up",
          "platform" => "signal",
          "contact_id" => contact.id
        })

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "conversation", conv.id)

      assert has_element?(view, ~s|input[name="entry[subject]"][value="Catch-up"]|)

      assert has_element?(
               view,
               ~s|select[name="entry[platform]"] option[value="signal"][selected]|
             )

      view
      |> form("#entry-modal form", %{})
      |> render_submit(%{"entry" => %{"subject" => "Catch-up 2", "platform" => "signal"}})

      assert Kith.Conversations.get_conversation!(account_id, conv.id).subject == "Catch-up 2"
    end

    test "activity prefills and saves, keeping contacts", %{
      conn: conn,
      contact: contact,
      account_id: account_id
    } do
      {:ok, act} =
        Kith.Activities.create_activity(
          account_id,
          %{
            "title" => "Hike",
            "occurred_at" => ~U[2022-02-02 02:02:00Z],
            "description" => "Up the hill"
          },
          [contact.id]
        )

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      click_edit(view, "activity", act.id)

      assert has_element?(view, ~s|input[name="entry[title]"][value="Hike"]|)
      assert has_element?(view, ~s|input[name="entry[occurred_at]"][value="2022-02-02T02:02"]|)
      assert has_element?(view, ~s|textarea[name="entry[description]"]|, "Up the hill")

      view
      |> form("#entry-modal form", %{})
      |> render_submit(%{
        "entry" => %{
          "title" => "Long hike",
          "occurred_at" => "2022-02-02T02:02",
          "description" => "Up the hill"
        }
      })

      updated = Kith.Activities.get_activity!(account_id, act.id)
      assert updated.title == "Long hike"
      assert contact.id in Enum.map(updated.contacts, & &1.id)
    end

    test "photo entries have no Edit action", %{conn: conn, contact: contact} do
      photo = photo_fixture(contact, %{"file_name" => "beach.jpg"})
      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")

      refute has_element?(view, ~s|button[phx-click="edit-entry"][phx-value-type="photo"]|)

      assert has_element?(
               view,
               ~s|button[phx-click="delete-entry"][phx-value-type="photo"][phx-value-id="#{photo.id}"]|
             )
    end

    defp call_for(contact, _account_id) do
      {:ok, call} =
        Kith.Activities.create_call(contact, %{
          "occurred_at" => ~U[2023-04-05 06:07:00Z],
          "duration_mins" => 42,
          "notes" => "Talked about trip"
        })

      call
    end
  end
end
