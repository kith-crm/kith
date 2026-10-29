defmodule Kith.ReminderEmailFixtures do
  @moduledoc false
  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  alias Kith.Repo
  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, Reminder, ReminderInstance}

  def setup_fixture do
    user = user_fixture()

    contact =
      contact_fixture(user.account_id, %{
        first_name: "Mona",
        last_name: "Vale",
        display_name: "Mona Vale"
      })

    {:ok, reminder} =
      Reminders.create_reminder(user.account_id, user.id, %{
        type: "one_time",
        title: "Call Mona",
        anchor_date: Reminders.account_today(user.account_id),
        contact_id: contact.id
      })

    :ok = dispatch_today(user.account_id)
    [instance] = Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))

    %{user: user, contact: contact, instance: instance}
  end

  # Runs the dispatcher at a late hour of the account-local "today", so the
  # run is never before send_hour and never straddles local midnight.
  def dispatch_today(account_id) do
    account = Kith.Accounts.get_account!(account_id)
    today = Reminders.account_today(account_id)
    Dispatcher.run(DateTime.new!(today, ~T[23:00:00], account.timezone))
  end

  def block_delivery(ctx, :inactive) do
    ctx.instance.reminder_id
    |> then(&Repo.get!(Reminder, &1))
    |> Reminders.update_reminder(%{active: false})
  end

  def block_delivery(ctx, :deleted), do: Kith.Contacts.soft_delete_contact(ctx.contact)
  def block_delivery(ctx, :archived), do: Kith.Contacts.archive_contact(ctx.contact)

  def block_delivery(ctx, status) do
    ctx.instance
    |> Ecto.Changeset.change(status: Atom.to_string(status))
    |> Repo.update!()
  end
end
