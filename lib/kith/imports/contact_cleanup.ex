defmodule Kith.Imports.ContactCleanup do
  @moduledoc """
  Removes import mappings for a contact and the rows its permanent deletion
  cascades to. Call inside the same transaction, before deleting the contacts.

  Import records use an untyped local id rather than a foreign key. Matching
  both entity type and account prevents equal ids in unrelated tables or
  accounts from being removed. Activities survive deletion of their contact
  links, so their mappings deliberately survive too.
  """

  import Ecto.Query

  alias Kith.Imports.ImportRecord
  alias Kith.Repo

  @contact_owned [
    {"address", Kith.Contacts.Address},
    {"call", Kith.Activities.Call},
    {"contact_field", Kith.Contacts.ContactField},
    {"conversation", Kith.Conversations.Conversation},
    {"debt", Kith.Contacts.Debt},
    {"document", Kith.Contacts.Document},
    {"gift", Kith.Contacts.Gift},
    {"life_event", Kith.Activities.LifeEvent},
    {"note", Kith.Contacts.Note},
    {"pet", Kith.Contacts.Pet},
    {"photo", Kith.Contacts.Photo},
    {"reminder", Kith.Reminders.Reminder},
    {"reminder_instance", Kith.Reminders.ReminderInstance},
    {"task", Kith.Tasks.Task}
  ]

  @doc false
  def delete_for_contacts(_account_id, []), do: :ok

  def delete_for_contacts(account_id, contact_ids) do
    Enum.each(@contact_owned, fn {type, schema} ->
      ids =
        from(entity in schema,
          where: entity.account_id == ^account_id and entity.contact_id in ^contact_ids,
          select: entity.id
        )

      delete_mappings(account_id, type, ids)
    end)

    message_ids =
      from(message in Kith.Conversations.Message,
        join: conversation in Kith.Conversations.Conversation,
        on: message.conversation_id == conversation.id,
        where: conversation.account_id == ^account_id,
        where: conversation.contact_id in ^contact_ids,
        select: message.id
      )

    delete_mappings(account_id, "message", message_ids)

    payment_ids =
      from(payment in Kith.Contacts.DebtPayment,
        join: debt in Kith.Contacts.Debt,
        on: payment.debt_id == debt.id,
        where: debt.account_id == ^account_id and debt.contact_id in ^contact_ids,
        select: payment.id
      )

    delete_mappings(account_id, "debt_payment", payment_ids)

    relationship_ids =
      from(relationship in Kith.Contacts.Relationship,
        where: relationship.account_id == ^account_id,
        where:
          relationship.contact_id in ^contact_ids or
            relationship.related_contact_id in ^contact_ids,
        select: relationship.id
      )

    delete_mappings(account_id, "relationship", relationship_ids)

    from(record in ImportRecord,
      where: record.account_id == ^account_id and record.local_entity_type == "contact",
      where: record.local_entity_id in ^contact_ids
    )
    |> Repo.delete_all()

    :ok
  end

  defp delete_mappings(account_id, type, entity_ids) do
    from(record in ImportRecord,
      where: record.account_id == ^account_id and record.local_entity_type == ^type,
      where: record.local_entity_id in subquery(entity_ids)
    )
    |> Repo.delete_all()
  end
end
