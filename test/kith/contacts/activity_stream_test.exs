defmodule Kith.Contacts.ActivityStreamTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts.ActivityStream

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    scope = user_scope_fixture(user)
    contact = contact_fixture(scope.account.id)

    %{user: user, scope: scope, contact: contact, account_id: scope.account.id}
  end

  describe "list_activity/3" do
    test "returns empty list when contact has no activity", ctx do
      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert entries == []
    end

    test "returns notes in the stream", ctx do
      note_fixture(ctx.contact, ctx.user.id, %{"body" => "<p>Hello world</p>"})

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :note, body: "<p>Hello world</p>"}] = entries
    end

    test "returns calls in the stream", ctx do
      {:ok, _call} =
        Kith.Activities.create_call(ctx.contact, %{
          "occurred_at" => DateTime.utc_now(),
          "duration_mins" => 15,
          "notes" => "Talked about plans"
        })

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :call}] = entries
    end

    test "returns life events in the stream", ctx do
      [type | _] = Kith.Repo.all(Kith.Contacts.LifeEventType)

      {:ok, _event} =
        Kith.Activities.create_life_event(ctx.contact, %{
          "occurred_on" => ~D[2025-06-15],
          "life_event_type_id" => type.id,
          "note" => "Big day"
        })

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :life_event, body: "Big day"}] = entries
    end

    test "returns tasks in the stream", ctx do
      {:ok, _task} =
        Kith.Tasks.create_task(ctx.account_id, ctx.user.id, %{
          "title" => "Buy birthday gift",
          "contact_id" => ctx.contact.id
        })

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :task, title: "Buy birthday gift"}] = entries
    end

    test "returns gifts in the stream", ctx do
      {:ok, _gift} =
        Kith.Gifts.create_gift(ctx.account_id, ctx.user.id, %{
          "name" => "A book",
          "direction" => "given",
          "contact_id" => ctx.contact.id
        })

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :gift, title: "A book"}] = entries
    end

    test "returns conversations in the stream", ctx do
      {:ok, _conv} =
        Kith.Conversations.create_conversation(ctx.account_id, ctx.user.id, %{
          "subject" => "Weekend plans",
          "platform" => "whatsapp",
          "contact_id" => ctx.contact.id
        })

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :conversation, title: "Weekend plans"}] = entries
    end

    test "returns photos in the stream", ctx do
      photo_fixture(ctx.contact, %{"file_name" => "MqkbdPlbb5ChW49ifnLKWcchWDhOSQEGwSbIfKvb.jpeg"})

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 1
      assert [%{type: :photo, title: "Photo"}] = entries
    end

    test "merges multiple types sorted by date descending", ctx do
      # Create entries with staggered timestamps
      note_fixture(ctx.contact, ctx.user.id, %{"body" => "<p>Old note</p>"})
      Process.sleep(10)

      {:ok, _call} =
        Kith.Activities.create_call(ctx.contact, %{
          "occurred_at" => DateTime.utc_now(),
          "notes" => "Recent call"
        })

      Process.sleep(10)
      note_fixture(ctx.contact, ctx.user.id, %{"body" => "<p>Newest note</p>"})

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert length(entries) == 3
      types = Enum.map(entries, & &1.type)
      # Newest first
      assert List.first(types) == :note
    end

    test "filters by type", ctx do
      note_fixture(ctx.contact, ctx.user.id)
      photo_fixture(ctx.contact)

      {:ok, _call} =
        Kith.Activities.create_call(ctx.contact, %{
          "occurred_at" => DateTime.utc_now()
        })

      notes_only =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id,
          current_user_id: ctx.user.id,
          types: [:note]
        )

      assert length(notes_only) == 1
      assert [%{type: :note}] = notes_only

      notes_and_photos =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id,
          current_user_id: ctx.user.id,
          types: [:note, :photo]
        )

      assert length(notes_and_photos) == 2
      types = Enum.map(notes_and_photos, & &1.type) |> MapSet.new()
      assert MapSet.equal?(types, MapSet.new([:note, :photo]))
    end

    test "respects limit option", ctx do
      for i <- 1..5 do
        note_fixture(ctx.contact, ctx.user.id, %{"body" => "<p>Note #{i}</p>"})
      end

      entries =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id,
          current_user_id: ctx.user.id,
          limit: 3
        )

      assert length(entries) == 3
    end

    test "each entry has required fields", ctx do
      note_fixture(ctx.contact, ctx.user.id, %{"body" => "<p>Test</p>"})

      [entry] =
        ActivityStream.list_activity(ctx.account_id, ctx.contact.id, current_user_id: ctx.user.id)

      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :type)
      assert Map.has_key?(entry, :title)
      assert Map.has_key?(entry, :body)
      assert Map.has_key?(entry, :occurred_at)
      assert Map.has_key?(entry, :record)
      assert %DateTime{} = entry.occurred_at
    end
  end

  describe "all_types/0" do
    test "returns all 8 types" do
      types = ActivityStream.all_types()
      assert length(types) == 8
      assert :note in types
      assert :call in types
      assert :life_event in types
      assert :activity in types
      assert :task in types
      assert :gift in types
      assert :conversation in types
      assert :photo in types
    end
  end
end
