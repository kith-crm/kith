defmodule Kith.Workers.ReminderEmailWorker do
  @moduledoc """
  Sends the email for one `ReminderInstance` to the reminder's creator.

  Inserted by `Kith.Reminders.Dispatcher` in the same transaction that records
  the instance, so a retry only resends the email and never creates another
  instance. Each attempt rechecks that the instance is pending, the reminder
  is active, and the contact is neither deleted nor archived. Its `snooze_count`
  must also match the queued job, so a delayed earlier notice cannot send when
  a later snooze wakes the same instance. A deceased contact remains eligible.
  After the final attempt fails, the instance is marked `failed`;
  a stay-in-touch reminder is re-armed one interval from today in the same
  transaction, since with no pending instance nothing else would re-arm it.
  """

  use Oban.Worker, queue: :reminders, max_attempts: 3

  require Logger

  alias Kith.Accounts.User
  alias Kith.Reminders.{Reminder, ReminderInstance}
  alias Kith.{Repo, TimeHelper}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id} = args, attempt: attempt, max_attempts: max}) do
    # Jobs queued before snooze generations were added belong to the initial
    # notice. They remain deliverable until the instance is snoozed once.
    snooze_count = Map.get(args, "snooze_count", 0)

    case ReminderInstance |> Repo.get(id) |> Repo.preload(reminder: :contact) do
      nil ->
        {:discard, "instance deleted"}

      %ReminderInstance{status: status} when status != "pending" ->
        {:discard, "instance no longer pending"}

      %{reminder: nil} ->
        {:discard, "reminder deleted"}

      %{reminder: %{active: false}} ->
        {:discard, "reminder inactive"}

      %{reminder: %{contact: nil}} ->
        {:discard, "contact deleted"}

      %{reminder: %{contact: %{deleted_at: deleted_at}}} when not is_nil(deleted_at) ->
        {:discard, "contact soft-deleted"}

      %{reminder: %{contact: %{is_archived: true}}} ->
        {:discard, "contact archived"}

      instance ->
        deliver(instance, snooze_count, attempt >= max)
    end
  end

  defp deliver(%ReminderInstance{snooze_count: current}, snooze_count, _last_attempt?)
       when current != snooze_count,
       do: {:discard, "notice superseded by snooze"}

  defp deliver(instance, _snooze_count, last_attempt?) do
    reminder = instance.reminder

    case Repo.get(User, reminder.creator_id) do
      %User{} = creator -> deliver_to(creator, instance, last_attempt?)
      nil -> log_missing_creator(reminder)
    end
  end

  defp deliver_to(creator, instance, last_attempt?) do
    case Kith.Mailer.deliver(build_email(creator, instance)) do
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

  defp build_email(%User{} = creator, instance) do
    reminder = instance.reminder
    contact = reminder.contact
    name = contact.display_name || contact.first_name
    subject = subject(reminder.type, instance.kind, instance.days_before, name, reminder.title)

    Swoosh.Email.new()
    |> Swoosh.Email.to({creator.email, creator.email})
    |> Swoosh.Email.from(
      {"Kith", Application.get_env(:kith, Kith.Mailer)[:from] || "noreply@localhost"}
    )
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body(body(subject, name, reminder.description))
  end

  defp body(subject, name, nil), do: "#{subject}\n\nContact: #{name}"
  defp body(subject, name, ""), do: body(subject, name, nil)
  defp body(subject, name, description), do: "#{subject}\n\n#{description}\n\nContact: #{name}"

  defp subject("birthday", "on_day", _days, name, _title), do: "#{name}'s birthday is today"

  defp subject("birthday", "advance", days, name, _title),
    do: "#{name}'s birthday is in #{days} days"

  defp subject("first_met", _kind, _days, name, _title), do: "Anniversary of meeting #{name}"

  defp subject("stay_in_touch", _kind, _days, name, _title), do: "Time to reach out to #{name}"

  defp subject("one_time", "advance", days, _name, title),
    do: "Reminder in #{days} days: #{title}"

  defp subject(_type, _kind, _days, _name, title), do: "Reminder: #{title || "Untitled"}"

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
