defmodule Kith.Exports do
  @moduledoc """
  Functions for building export data structures.
  """

  import Ecto.Query

  alias Kith.Accounts.User
  alias Kith.Activities.Activity
  alias Kith.Contacts
  alias Kith.Conversations.{Conversation, Message}
  alias Kith.Repo

  @history_fields [
    journal_entries:
      {Kith.Journal.Entry, :author_id, ~w(title content occurred_at mood is_private author_id)a},
    tasks:
      {Kith.Tasks.Task, :creator_id,
       ~w(title description due_date priority status completed_at is_private contact_id creator_id)a},
    gifts:
      {Contacts.Gift, :creator_id,
       ~w(name description occasion date amount direction status purchase_url is_private contact_id creator_id currency_id)a},
    conversations:
      {Conversation, :creator_id, ~w(subject platform status is_private contact_id creator_id)a}
  ]

  @doc """
  Builds the workspace JSON export.

  Pass the requesting user to apply access rules to optional history. A bare
  account ID is for trusted account operations.
  """
  def build_json_export(account_id) when is_integer(account_id), do: build_export(account_id, nil)

  def build_json_export(%User{account_id: account_id, id: user_id}),
    do: build_export(account_id, user_id)

  defp build_export(account_id, user_id) do
    account = Repo.get!(Kith.Accounts.Account, account_id)
    contacts = Contacts.list_contacts_with_all(account_id)

    # Load reference data
    tags =
      Kith.Contacts.Tag
      |> where([t], t.account_id == ^account_id)
      |> Repo.all()

    genders =
      Kith.Contacts.Gender
      |> where([g], is_nil(g.account_id) or g.account_id == ^account_id)
      |> Repo.all()

    relationship_types =
      Kith.Contacts.RelationshipType
      |> where([rt], is_nil(rt.account_id) or rt.account_id == ^account_id)
      |> Repo.all()

    contact_field_types =
      Kith.Contacts.ContactFieldType
      |> where([cft], is_nil(cft.account_id) or cft.account_id == ^account_id)
      |> Repo.all()

    %{
      export_version: "1.0",
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      account: %{
        name: account.name,
        timezone: Map.get(account, :timezone, nil)
      },
      contacts: Enum.map(contacts, &serialize_contact/1),
      tags: Enum.map(tags, &serialize_tag/1),
      genders: Enum.map(genders, &serialize_gender/1),
      relationship_types: Enum.map(relationship_types, &serialize_relationship_type/1),
      contact_field_types: Enum.map(contact_field_types, &serialize_contact_field_type/1)
    }
    |> Map.merge(export_history(account_id, user_id))
  end

  defp export_history(account_id, user_id) do
    conversations = history_query(Conversation, account_id, :creator_id, user_id)

    messages =
      Message
      |> Kith.Scope.scope_to_account(account_id)
      |> where([m], m.conversation_id in subquery(select(conversations, [c], c.id)))
      |> export_rows(~w(body direction sent_at conversation_id)a)

    Map.new(@history_fields, fn {key, {schema, owner_field, fields}} ->
      {key, schema |> history_query(account_id, owner_field, user_id) |> export_rows(fields)}
    end)
    |> Map.put(:messages, messages)
    |> Map.put(:activities, export_activities(account_id))
  end

  defp history_query(schema, account_id, owner_field, user_id) do
    query = Kith.Scope.scope_to_account(schema, account_id)

    if user_id do
      where(query, [row], row.is_private == false or field(row, ^owner_field) == ^user_id)
    else
      query
    end
  end

  defp export_rows(query, fields) do
    query
    |> order_by([row], row.id)
    |> Repo.all()
    |> Enum.map(&serialize_row(&1, fields))
  end

  defp export_activities(account_id) do
    contacts = Contacts.Contact |> Kith.Scope.scope_active(account_id) |> order_by([c], c.id)

    Activity
    |> Kith.Scope.scope_to_account(account_id)
    |> order_by([activity], activity.id)
    |> preload(
      contacts: ^contacts,
      emotions:
        ^from(e in Contacts.Emotion,
          where: is_nil(e.account_id) or e.account_id == ^account_id,
          order_by: e.id
        )
    )
    |> Repo.all()
    |> Enum.map(fn activity ->
      activity
      |> serialize_row(
        ~w(title description occurred_at is_private activity_type_category_id creator_id)a
      )
      |> Map.put(:contact_ids, Enum.map(activity.contacts, & &1.id))
      |> Map.put(:emotion_ids, Enum.map(activity.emotions, & &1.id))
    end)
  end

  defp serialize_row(row, fields), do: Map.take(row, [:id, :inserted_at, :updated_at | fields])

  defp serialize_contact(contact) do
    serialize_contact_fields(contact)
    |> Map.merge(serialize_contact_associations(contact))
  end

  defp serialize_contact_fields(contact) do
    %{
      id: contact.id,
      first_name: contact.first_name,
      last_name: contact.last_name,
      display_name: contact.display_name,
      nickname: contact.nickname,
      birthdate: maybe_date(contact.birthdate),
      description: contact.description,
      occupation: contact.occupation,
      company: contact.company,
      favorite: contact.favorite,
      deceased: contact.deceased,
      deceased_at: maybe_date(contact.deceased_at),
      last_talked_to: maybe_datetime(contact.last_talked_to),
      gender_id: contact.gender_id
    }
  end

  defp serialize_contact_associations(contact) do
    %{
      notes: map_assoc(contact.notes, &serialize_note/1),
      life_events: map_assoc(contact.life_events, &serialize_life_event/1),
      calls: map_assoc(contact.calls, &serialize_call/1),
      addresses: map_assoc(contact.addresses, &serialize_address/1),
      contact_fields: map_assoc(contact.contact_fields, &serialize_contact_field/1),
      tags: map_assoc(contact.tags, fn t -> %{id: t.id, name: t.name} end),
      reminders: map_assoc(contact.reminders, &serialize_reminder/1),
      documents: map_assoc(contact.documents, &serialize_document/1),
      photos: map_assoc(contact.photos, &serialize_photo/1)
    }
  end

  defp map_assoc(nil, _fun), do: []
  defp map_assoc(list, fun), do: Enum.map(list, fun)

  defp maybe_date(nil), do: nil
  defp maybe_date(date), do: Date.to_iso8601(date)

  defp maybe_datetime(nil), do: nil
  defp maybe_datetime(dt), do: DateTime.to_iso8601(dt)

  defp serialize_document(d) do
    %{filename: d.file_name, file_size: d.file_size, content_type: d.content_type}
  end

  defp serialize_photo(p) do
    %{
      filename: p.file_name,
      file_size: p.file_size,
      content_type: p.content_type,
      is_private: p.is_private
    }
  end

  defp serialize_note(note) do
    %{
      id: note.id,
      body: note.body,
      favorite: note.favorite,
      is_private: note.is_private,
      created_at: DateTime.to_iso8601(note.inserted_at)
    }
  end

  defp serialize_life_event(le) do
    %{
      id: le.id,
      occurred_on: le.occurred_on && Date.to_iso8601(le.occurred_on),
      note: le.note,
      life_event_type_id: le.life_event_type_id
    }
  end

  defp serialize_call(call) do
    %{
      id: call.id,
      occurred_at: call.occurred_at && DateTime.to_iso8601(call.occurred_at),
      duration_mins: call.duration_mins,
      notes: call.notes,
      emotion_id: call.emotion_id,
      call_direction_id: call.call_direction_id
    }
  end

  defp serialize_address(addr) do
    %{
      id: addr.id,
      label: addr.label,
      line1: addr.line1,
      line2: addr.line2,
      city: addr.city,
      province: addr.province,
      postal_code: addr.postal_code,
      country: addr.country
    }
  end

  defp serialize_contact_field(cf) do
    %{
      id: cf.id,
      value: cf.value,
      label: cf.label,
      contact_field_type_id: cf.contact_field_type_id
    }
  end

  defp serialize_reminder(r) do
    %{
      id: r.id,
      title: Map.get(r, :title, nil),
      reminder_type: Map.get(r, :reminder_type, nil)
    }
  end

  defp serialize_tag(tag) do
    %{id: tag.id, name: tag.name, color: tag.color}
  end

  defp serialize_gender(g) do
    %{id: g.id, name: g.name}
  end

  defp serialize_relationship_type(rt) do
    %{id: rt.id, name: Map.get(rt, :name, nil)}
  end

  defp serialize_contact_field_type(cft) do
    %{id: cft.id, name: cft.name, protocol: cft.protocol, icon: cft.icon}
  end
end
