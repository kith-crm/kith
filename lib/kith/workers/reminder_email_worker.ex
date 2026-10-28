defmodule Kith.Workers.ReminderEmailWorker do
  @moduledoc """
  Sends the email for one `ReminderInstance` to the reminder's creator.

  Inserted by `Kith.Reminders.Dispatcher` in the same transaction that records
  the instance, so a retry only resends the email and never creates another
  instance. After the final attempt fails, the instance is marked `failed`;
  a stay-in-touch reminder is re-armed one interval from today in the same
  transaction, since with no pending instance nothing else would re-arm it.
  """

  use Oban.Worker, queue: :reminders, max_attempts: 3

  require Logger

  alias Kith.Accounts.User
  alias Kith.Emails.ReminderNotification
  alias Kith.Reminders.{Reminder, ReminderInstance}
  alias Kith.{Repo, TimeHelper}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id}, attempt: attempt, max_attempts: max}) do
    case ReminderInstance |> Repo.get(id) |> Repo.preload([:account, reminder: :contact]) do
      nil -> {:discard, "instance deleted"}
      instance -> deliver(instance, attempt >= max)
    end
  end

  defp deliver(instance, last_attempt?) do
    reminder = instance.reminder

    case Repo.get(User, reminder.creator_id) do
      %User{} = creator -> deliver_to(creator, instance, last_attempt?)
      nil -> log_missing_creator(reminder)
    end
  end

  defp deliver_to(creator, instance, last_attempt?) do
    case Kith.Mailer.deliver(ReminderNotification.build(creator, instance)) do
      {:ok, _} ->
        audit(instance, nil)
        :ok

      {:error, reason} ->
        audit(instance, reason)
        if last_attempt?, do: mark_failed(instance)
        {:error, reason}
    end
  end

  defp mark_failed(instance) do
    Repo.transaction(fn ->
      instance |> ReminderInstance.fail_changeset() |> Repo.update!()
      rearm_stay_in_touch(instance.reminder)
    end)
  end

  defp rearm_stay_in_touch(%Reminder{type: "stay_in_touch"} = reminder) do
    today = Kith.Accounts.get_account!(reminder.account_id).timezone |> TimeHelper.local_today()
    reminder |> Reminder.rearm_changeset(today) |> Repo.update!()
  end

  defp rearm_stay_in_touch(_reminder), do: :ok

  defp log_missing_creator(reminder) do
    Logger.warning("[ReminderEmailWorker] reminder #{reminder.id} has no creator; not emailing")
    :ok
  end

  defp audit(instance, error) do
    reminder = instance.reminder
    metadata = %{reminder_id: reminder.id, instance_id: instance.id, type: instance.kind}
    metadata = if error, do: Map.put(metadata, :delivery_error, inspect(error)), else: metadata

    Kith.AuditLogs.create_audit_log(reminder.account_id, %{
      user_id: nil,
      user_name: "system",
      event: "reminder_fired",
      contact_id: reminder.contact_id,
      contact_name: reminder.contact.display_name,
      metadata: metadata
    })
  end
end
