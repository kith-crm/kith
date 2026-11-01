defmodule Kith.Contacts.ActivityStream do
  @moduledoc """
  Unified activity stream for a contact, merging all entry types
  (notes, calls, life events, activities, tasks, gifts, conversations, photos)
  into a single chronological timeline.
  """

  alias Kith.Activities
  alias Kith.Contacts
  alias Kith.Conversations
  alias Kith.Gifts
  alias Kith.Tasks

  @type entry_type ::
          :note | :call | :life_event | :activity | :task | :gift | :conversation | :photo

  @all_types ~w(note call life_event activity task gift conversation photo)a

  @doc """
  Lists activity entries for a contact, merged into a single chronological stream.

  ## Options

    * `:types` - list of entry types to include (default: all types)
    * `:limit` - max entries to return (default: 20)
    * `:current_user_id` - required, used for privacy filtering on notes

  Returns a list of maps with normalized shape:

      %{
        id: integer,
        type: atom,
        title: string,
        body: string | nil,
        occurred_at: DateTime.t(),
        record: struct  # the original schema struct
      }
  """
  @spec list_activity(integer(), integer(), keyword()) :: [map()]
  def list_activity(account_id, contact_id, opts \\ []) do
    types = Keyword.get(opts, :types, @all_types)
    limit = Keyword.get(opts, :limit, 20)
    current_user_id = Keyword.fetch!(opts, :current_user_id)

    types
    |> Enum.flat_map(&fetch_entries(&1, account_id, contact_id, current_user_id))
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Returns all supported entry types.
  """
  def all_types, do: @all_types

  # --- Private fetchers per type ---

  defp fetch_entries(:note, _account_id, contact_id, current_user_id) do
    contact_id
    |> Contacts.list_notes(current_user_id)
    |> Enum.map(&normalize_note/1)
  end

  defp fetch_entries(:call, _account_id, contact_id, _current_user_id) do
    contact_id
    |> Activities.list_calls()
    |> Enum.map(&normalize_call/1)
  end

  defp fetch_entries(:life_event, _account_id, contact_id, _current_user_id) do
    contact_id
    |> Activities.list_life_events()
    |> Enum.map(&normalize_life_event/1)
  end

  defp fetch_entries(:activity, _account_id, contact_id, _current_user_id) do
    contact_id
    |> Activities.list_activities_for_contact()
    |> Enum.map(&normalize_activity/1)
  end

  defp fetch_entries(:task, account_id, contact_id, _current_user_id) do
    account_id
    |> Tasks.list_tasks(contact_id: contact_id)
    |> Enum.map(&normalize_task/1)
  end

  defp fetch_entries(:gift, account_id, contact_id, _current_user_id) do
    account_id
    |> Gifts.list_gifts(contact_id)
    |> Enum.map(&normalize_gift/1)
  end

  defp fetch_entries(:conversation, account_id, contact_id, _current_user_id) do
    account_id
    |> Conversations.list_conversations(contact_id)
    |> Enum.map(&normalize_conversation/1)
  end

  defp fetch_entries(:photo, _account_id, contact_id, _current_user_id) do
    contact_id
    |> Contacts.list_photos()
    |> Enum.map(&normalize_photo/1)
  end

  # --- Normalizers ---

  defp normalize_note(note) do
    %{
      id: note.id,
      type: :note,
      title: truncate(strip_html(note.body), 80),
      body: note.body,
      occurred_at: note.inserted_at,
      record: note
    }
  end

  defp normalize_call(call) do
    direction = if call.call_direction, do: call.call_direction.name, else: nil

    title =
      [direction, duration_text(call.duration_mins)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" \u00b7 ")
      |> then(fn
        "" -> "Call"
        text -> text
      end)

    %{
      id: call.id,
      type: :call,
      title: title,
      body: call.notes,
      occurred_at: call.occurred_at,
      record: call
    }
  end

  defp normalize_life_event(event) do
    type_name = if event.life_event_type, do: event.life_event_type.name, else: nil

    %{
      id: event.id,
      type: :life_event,
      title: type_name || "Life event",
      body: event.note,
      occurred_at: date_to_datetime(event.occurred_on),
      record: event
    }
  end

  defp normalize_activity(activity) do
    %{
      id: activity.id,
      type: :activity,
      title: activity.title || "Activity",
      body: activity.description,
      occurred_at: activity.occurred_at,
      record: activity
    }
  end

  defp normalize_task(task) do
    %{
      id: task.id,
      type: :task,
      title: task.title,
      body: task.description,
      occurred_at: task.inserted_at,
      record: task
    }
  end

  defp normalize_gift(gift) do
    %{
      id: gift.id,
      type: :gift,
      title: gift.name || "Gift",
      body: gift.description,
      occurred_at: gift.inserted_at,
      record: gift
    }
  end

  defp normalize_conversation(conversation) do
    message_count = length(conversation.messages)
    last_message = List.first(conversation.messages)
    body_preview = if last_message, do: "#{message_count} messages", else: nil

    %{
      id: conversation.id,
      type: :conversation,
      title: conversation.subject || conversation.platform || "Conversation",
      body: body_preview,
      occurred_at: conversation.updated_at,
      record: conversation
    }
  end

  defp normalize_photo(photo) do
    %{
      id: photo.id,
      type: :photo,
      title: "Photo",
      body: nil,
      occurred_at: photo.inserted_at,
      record: photo
    }
  end

  # --- Helpers ---

  defp date_to_datetime(%Date{} = date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp date_to_datetime(nil), do: DateTime.from_unix!(0)

  defp duration_text(nil), do: nil
  defp duration_text(mins) when mins < 60, do: "#{mins} min"
  defp duration_text(mins), do: "#{div(mins, 60)}h #{rem(mins, 60)}m"

  defp strip_html(nil), do: ""

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length) <> "..."
  end
end
