defmodule KithWeb.API.FullExportTest do
  use KithWeb.ConnCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Accounts, Activities, Contacts, Conversations, Gifts, Journal, Repo, Tasks}
  alias Kith.Accounts.OptionalFeatures
  alias Kith.Workers.ExportWorker

  test "inline and background exports include retained history and its associations", %{
    conn: conn
  } do
    user = user_fixture()
    contact = contact_fixture(user.account_id)
    expected = create_history(user, contact)

    outsider = user_fixture()
    create_history(outsider, contact_fixture(outsider.account_id))

    coworker =
      user_fixture()
      |> Ecto.Changeset.change(account_id: user.account_id)
      |> Repo.update!()

    coworker_history = create_history(coworker, contact)
    expected = Map.merge(expected, create_call_and_life_event(contact))

    for key <- OptionalFeatures.keys() do
      assert {:ok, _} = Accounts.set_optional_feature(user_scope_fixture(user), key, false)
    end

    {token, _} = Accounts.generate_api_token(user)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    inline = conn |> get(~p"/api/export") |> json_response(200)
    assert length(inline["contacts"]) == 1

    now = DateTime.utc_now(:second)
    extra = %{account_id: user.account_id, first_name: "Extra", inserted_at: now, updated_at: now}
    assert {499, _} = Repo.insert_all(Contacts.Contact, List.duplicate(extra, 499))
    assert %{"contact_count" => 500} = conn |> get(~p"/api/export") |> json_response(202)

    args = %{"account_id" => user.account_id, "user_id" => user.id}
    assert_enqueued(worker: ExportWorker, args: args)

    pattern = Path.join(System.tmp_dir!(), "kith_export_*/export.meta")
    prior_exports = Path.wildcard(pattern)
    assert :ok = perform_job(ExportWorker, args)
    prefix = "export_#{user.account_id}_"

    meta_path =
      Enum.find(Path.wildcard(pattern) -- prior_exports, fn path ->
        %{"key" => key} = path |> File.read!() |> Jason.decode!()
        String.starts_with?(key, prefix)
      end)

    assert meta_path
    cache_dir = Path.dirname(meta_path)
    on_exit(fn -> File.rm_rf!(cache_dir) end)
    background = cache_dir |> Path.join("export.json") |> File.read!() |> Jason.decode!()

    assert length(background["contacts"]) == 500
    contact_id = contact.id

    for export <- [inline, background] do
      assert %{"calls" => [%{"id" => call_id}], "life_events" => [%{"id" => life_event_id}]} =
               Enum.find(export["contacts"], &(&1["id"] == contact_id))

      assert call_id == expected.call_id
      assert life_event_id == expected.life_event_id
      assert [%{"id" => journal_id}] = export["journal_entries"]
      assert journal_id == expected.journal_id

      assert Enum.map(export["activities"], & &1["id"]) ==
               [expected.activity_id, coworker_history.activity_id]

      assert %{"contact_ids" => [^contact_id], "emotion_ids" => [emotion_id]} =
               Enum.find(export["activities"], &(&1["id"] == expected.activity_id))

      assert emotion_id == expected.emotion_id
      assert [%{"id" => task_id, "contact_id" => nil}] = export["tasks"]
      assert task_id == expected.task_id
      assert [%{"id" => gift_id, "contact_id" => ^contact_id}] = export["gifts"]
      assert gift_id == expected.gift_id
      assert [%{"id" => conversation_id, "contact_id" => ^contact_id}] = export["conversations"]
      assert conversation_id == expected.conversation_id
      assert [%{"id" => message_id, "conversation_id" => ^conversation_id}] = export["messages"]
      assert message_id == expected.message_id
    end
  end

  defp create_history(user, contact) do
    account = user.account_id
    enable_optional_features(user, OptionalFeatures.keys())
    now = DateTime.utc_now(:second)

    {:ok, journal} =
      Journal.create_entry(account, user.id, %{content: "Journal", occurred_at: now})

    {:ok, emotion} = Contacts.create_emotion(account, %{name: "Export emotion #{user.id}"})

    {:ok, activity} =
      Activities.create_activity(
        account,
        %{title: "Activity", occurred_at: now, is_private: true},
        [contact.id],
        [emotion.id]
      )

    {:ok, task} = Tasks.create_task(account, user.id, %{title: "Workspace task"})

    {:ok, gift} =
      Gifts.create_gift(account, user.id, %{
        name: "Gift",
        direction: "given",
        contact_id: contact.id
      })

    {:ok, conversation} =
      Conversations.create_conversation(account, user.id, %{contact_id: contact.id})

    {:ok, message} =
      Conversations.add_message(conversation, %{sent_at: now, direction: "sent", body: "Hello"})

    %{
      journal_id: journal.id,
      activity_id: activity.id,
      emotion_id: emotion.id,
      task_id: task.id,
      gift_id: gift.id,
      conversation_id: conversation.id,
      message_id: message.id
    }
  end

  defp create_call_and_life_event(contact) do
    {:ok, call} = Activities.create_call(contact, %{occurred_at: DateTime.utc_now(:second)})
    {:ok, type} = Contacts.create_life_event_type(contact.account_id, %{name: "Milestone"})

    {:ok, event} =
      Activities.create_life_event(contact, %{
        occurred_on: Date.utc_today(),
        life_event_type_id: type.id
      })

    %{call_id: call.id, life_event_id: event.id}
  end
end
