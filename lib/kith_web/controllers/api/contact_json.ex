defmodule KithWeb.API.ContactJSON do
  @moduledoc """
  JSON serialization for contacts in the REST API.
  """

  alias Kith.Activities.{Activity, Call, LifeEvent}
  alias Kith.Contacts.{Address, Contact, ContactField, Document, Note, Photo, Tag}
  alias Kith.Reminders.Reminder

  @doc """
  Renders a contact for list and show endpoints.
  """
  def data(%Contact{} = contact) do
    %{
      id: contact.id,
      first_name: contact.first_name,
      last_name: contact.last_name,
      display_name: contact.display_name,
      nickname: contact.nickname,
      birthdate: format_year_unknown_date(contact.birthdate, contact.birthdate_year_unknown),
      description: contact.description,
      occupation: contact.occupation,
      company: contact.company,
      favorite: contact.favorite,
      archived: contact.is_archived,
      deceased: contact.deceased,
      last_talked_to: contact.last_talked_to,
      gender_id: contact.gender_id,
      middle_name: contact.middle_name,
      first_met_at:
        format_year_unknown_date(contact.first_met_at, contact.first_met_year_unknown),
      first_met_year_unknown: contact.first_met_year_unknown,
      first_met_where: contact.first_met_where,
      first_met_through_id: contact.first_met_through_id,
      first_met_additional_info: contact.first_met_additional_info,
      birthdate_year_unknown: contact.birthdate_year_unknown,
      inserted_at: contact.inserted_at,
      updated_at: contact.updated_at
    }
  end

  @doc """
  Renders a contact with conditional includes.
  """
  def data_with_includes(%Contact{} = contact, includes) do
    base = data(contact)

    Enum.reduce(includes, base, fn
      :tags, acc ->
        Map.put(acc, :tags, render_assoc(contact.tags, &tag/1))

      :contact_fields, acc ->
        Map.put(acc, :contact_fields, render_assoc(contact.contact_fields, &contact_field/1))

      :addresses, acc ->
        Map.put(acc, :addresses, render_assoc(contact.addresses, &address/1))

      :notes, acc ->
        Map.put(acc, :notes, render_assoc(contact.notes, &note/1))

      :life_events, acc ->
        Map.put(acc, :life_events, render_assoc(contact.life_events, &life_event/1))

      :activities, acc ->
        Map.put(acc, :activities, render_assoc(contact.activities, &activity/1))

      :calls, acc ->
        Map.put(acc, :calls, render_assoc(contact.calls, &call/1))

      :relationships, acc ->
        Map.put(acc, :relationships, render_relationships(contact))

      :reminders, acc ->
        Map.put(acc, :reminders, render_assoc(contact.reminders, &reminder/1))

      :documents, acc ->
        Map.put(acc, :documents, render_assoc(contact.documents, &document/1))

      :photos, acc ->
        Map.put(acc, :photos, render_assoc(contact.photos, &photo/1))

      :first_met_through, acc ->
        Map.put(acc, :first_met_through, render_first_met_through(contact))

      _, acc ->
        acc
    end)
  end

  defp render_assoc(%Ecto.Association.NotLoaded{}, _fun), do: nil
  defp render_assoc(items, fun) when is_list(items), do: Enum.map(items, fun)

  def tag(%Tag{} = t), do: %{id: t.id, name: t.name, inserted_at: t.inserted_at}

  def address(%Address{} = a) do
    %{
      id: a.id,
      contact_id: a.contact_id,
      label: a.label,
      line1: a.line1,
      line2: a.line2,
      city: a.city,
      province: a.province,
      postal_code: a.postal_code,
      country: a.country,
      latitude: a.latitude,
      longitude: a.longitude,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end

  def contact_field(%ContactField{} = cf) do
    %{
      id: cf.id,
      contact_id: cf.contact_id,
      contact_field_type_id: cf.contact_field_type_id,
      value: cf.value,
      inserted_at: cf.inserted_at,
      updated_at: cf.updated_at
    }
  end

  def note(%Note{} = n) do
    %{
      id: n.id,
      contact_id: n.contact_id,
      body: n.body,
      favorite: n.favorite,
      inserted_at: n.inserted_at,
      updated_at: n.updated_at
    }
  end

  def life_event(%LifeEvent{} = le) do
    %{
      id: le.id,
      contact_id: le.contact_id,
      life_event_type_id: le.life_event_type_id,
      occurred_on: le.occurred_on,
      note: le.note,
      inserted_at: le.inserted_at,
      updated_at: le.updated_at
    }
  end

  def activity(%Activity{} = a) do
    %{
      id: a.id,
      title: a.title,
      description: a.description,
      occurred_at: a.occurred_at,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end

  def call(%Call{} = c) do
    %{
      id: c.id,
      contact_id: c.contact_id,
      duration_mins: c.duration_mins,
      occurred_at: c.occurred_at,
      notes: c.notes,
      emotion_id: c.emotion_id,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  def reminder(%Reminder{} = r) do
    %{
      id: r.id,
      contact_id: r.contact_id,
      type: r.type,
      title: r.title,
      anchor_date: r.anchor_date,
      interval_unit: r.interval_unit,
      interval_count: r.interval_count,
      frequency: Reminder.frequency_preset(r),
      next_reminder_date: r.next_reminder_date,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end

  def document(%Document{} = d) do
    %{
      id: d.id,
      contact_id: d.contact_id,
      file_name: d.file_name,
      content_type: d.content_type,
      file_size: d.file_size,
      inserted_at: d.inserted_at
    }
  end

  def photo(%Photo{} = p) do
    %{
      id: p.id,
      contact_id: p.contact_id,
      file_name: p.file_name,
      inserted_at: p.inserted_at
    }
  end

  defp render_relationships(%{id: _} = contact) do
    case Map.get(contact, :relationships) do
      %Ecto.Association.NotLoaded{} -> nil
      rels when is_list(rels) -> Enum.map(rels, &relationship/1)
      _ -> nil
    end
  end

  defp relationship(rel) do
    %{
      id: rel.id,
      contact_id: rel.contact_id,
      related_contact_id: rel.related_contact_id,
      relationship_type_id: rel.relationship_type_id,
      inserted_at: rel.inserted_at
    }
  end

  defp render_first_met_through(%{first_met_through: %Ecto.Association.NotLoaded{}}), do: nil
  defp render_first_met_through(%{first_met_through: nil}), do: nil

  defp render_first_met_through(%{first_met_through: contact}) do
    %{id: contact.id, display_name: contact.display_name}
  end

  defp format_year_unknown_date(nil, _unknown), do: nil

  defp format_year_unknown_date(date, true) do
    "--" <> String.slice(Date.to_iso8601(date), 5, 5)
  end

  defp format_year_unknown_date(date, _), do: date
end
