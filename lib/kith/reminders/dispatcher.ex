defmodule Kith.Reminders.Dispatcher do
  @moduledoc """
  Sends every reminder notice that is due, exactly once. Called hourly by
  `Kith.Workers.ReminderDispatcher`; `run/1` takes `now` so tests control time.

  For each account whose local hour has reached `send_hour`:
  - the on-day notice when `next_reminder_date <= local today` (catch-up
    included); stay-in-touch waits while it has a pending instance;
  - at most one advance notice per birthday/one-time reminder: window
    boundaries come from all configured advance rules (active or not), via
    `advance_days_before/3`, but a notice only sends when the rule whose
    window contains today is active.
  Snoozed instances whose `snoozed_until` has passed are sent again.

  Each notice is a `ReminderInstance`; the unique index on
  (reminder_id, occurrence_date, days_before) turns retries and overlapping
  runs into no-ops. The email is a `ReminderEmailWorker` job inserted in the
  same transaction.
  """

  import Ecto.Query
  require Logger

  alias Kith.Accounts.Account
  alias Kith.Reminders.{Occurrences, Reminder, ReminderInstance, ReminderRule}
  alias Kith.{Repo, TimeHelper}
  alias Kith.Workers.ReminderEmailWorker

  @advance_types ~w(birthday one_time)
  @advancing_types ~w(birthday recurring)

  @spec run(DateTime.t()) :: :ok
  def run(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Account
    |> Repo.all()
    |> Enum.each(fn account ->
      safely("account #{account.id}", fn -> dispatch_account(account, now) end)
    end)

    wake_snoozed(now)
    :ok
  end

  @doc """
  The advance notice (`days_before`) due `today` for an occurrence on `next`,
  or nil. Each rule's window runs from `next - days_before` up to the next
  smaller rule, so only the nearest window notifies: 5 days out gets the
  7-day notice, never a stale 30-day one.
  """
  @spec advance_days_before(Date.t(), Date.t(), [pos_integer()]) :: pos_integer() | nil
  def advance_days_before(next, today, rule_days) do
    days_until = Date.diff(next, today)

    rule_days
    |> Enum.sort(:desc)
    |> Enum.chunk_every(2, 1, [0])
    |> Enum.find_value(fn [days, smaller] ->
      if days_until <= days and days_until > smaller, do: days
    end)
  end

  defp dispatch_account(%Account{} = account, now) do
    {today, hour} = TimeHelper.local_date_hour(now, account.timezone)

    if hour >= account.send_hour do
      dispatch_due_reminders(account, today, now)
    end
  end

  defp dispatch_due_reminders(account, today, now) do
    rules = advance_rules(account.id)
    rule_days = Enum.map(rules, &elem(&1, 0))
    active_days = for {d, true} <- rules, into: MapSet.new(), do: d
    horizon = Date.add(today, Enum.max(rule_days, fn -> 0 end))

    account.id
    |> due_reminders(horizon)
    |> Enum.each(fn reminder ->
      safely("reminder #{reminder.id}", fn ->
        dispatch_reminder(reminder, today, rule_days, active_days, now)
      end)
    end)
  end

  defp advance_rules(account_id) do
    from(r in ReminderRule,
      where: r.account_id == ^account_id and r.days_before > 0,
      select: {r.days_before, r.active}
    )
    |> Repo.all()
  end

  defp due_reminders(account_id, horizon) do
    from(r in Reminder,
      join: c in assoc(r, :contact),
      where: r.account_id == ^account_id and r.active == true,
      where: r.next_reminder_date <= ^horizon,
      where: is_nil(c.deleted_at) and c.is_archived == false,
      preload: [contact: c]
    )
    |> Repo.all()
  end

  defp dispatch_reminder(reminder, today, rule_days, active_days, now) do
    cond do
      Date.compare(reminder.next_reminder_date, today) != :gt ->
        send_on_day(reminder, today, now)

      reminder.type in @advance_types ->
        dispatch_advance_notice(reminder, today, rule_days, active_days, now)

      true ->
        :not_due
    end
  end

  defp dispatch_advance_notice(reminder, today, rule_days, active_days, now) do
    case advance_days_before(reminder.next_reminder_date, today, rule_days) do
      nil ->
        :not_due

      days ->
        if MapSet.member?(active_days, days),
          do: send_notice(reminder, "advance", days, today, now),
          else: :not_due
    end
  end

  defp send_on_day(%Reminder{type: "stay_in_touch"} = reminder, today, now) do
    if Kith.Reminders.has_pending_instance?(reminder.id),
      do: :waiting,
      else: send_notice(reminder, "on_day", 0, today, now)
  end

  defp send_on_day(reminder, today, now), do: send_notice(reminder, "on_day", 0, today, now)

  defp send_notice(reminder, kind, days_before, today, now) do
    deceased? = reminder.contact.deceased

    attrs = %{
      reminder_id: reminder.id,
      account_id: reminder.account_id,
      contact_id: reminder.contact_id,
      occurrence_date: reminder.next_reminder_date,
      kind: kind,
      days_before: days_before,
      status: if(deceased?, do: "dismissed", else: "pending"),
      scheduled_for: now,
      fired_at: now
    }

    Repo.transaction(fn ->
      handle_insert_result(insert_instance(attrs), reminder, today, kind, deceased?)
    end)
  end

  defp insert_instance(attrs) do
    %ReminderInstance{}
    |> ReminderInstance.create_changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:reminder_id, :occurrence_date, :days_before]
    )
  end

  defp handle_insert_result(
         {:ok, %ReminderInstance{id: nil}},
         _reminder,
         _today,
         _kind,
         _deceased?
       ),
       do: :already_sent

  defp handle_insert_result({:ok, instance}, reminder, today, kind, deceased?) do
    if kind == "on_day", do: advance(reminder, today)
    unless deceased?, do: Oban.insert!(ReminderEmailWorker.new(%{instance_id: instance.id}))
    :sent
  end

  defp handle_insert_result({:error, changeset}, _reminder, _today, _kind, _deceased?),
    do: Repo.rollback(changeset)

  # Advance past *today*, not just past the fired occurrence: after missed
  # periods this sends one notice and resumes at the next future date.
  defp advance(%Reminder{type: type} = reminder, today) when type in @advancing_types do
    next = Occurrences.advance_after(Reminder.schedule(reminder), today)
    reminder |> Reminder.advance_changeset(next) |> Repo.update!()
  end

  defp advance(_reminder, _today), do: :ok

  defp wake_snoozed(now) do
    from(i in ReminderInstance,
      join: r in assoc(i, :reminder),
      join: c in assoc(i, :contact),
      where: i.status == "snoozed" and i.snoozed_until <= ^now,
      where: r.active == true and is_nil(c.deleted_at),
      select: i.id
    )
    |> Repo.all()
    |> Enum.each(fn instance_id ->
      safely("snoozed instance #{instance_id}", fn -> wake(instance_id, now) end)
    end)
  end

  # Conditional update so two overlapping runs can't both re-send.
  defp wake(instance_id, now) do
    Repo.transaction(fn ->
      {count, _} =
        from(i in ReminderInstance, where: i.id == ^instance_id and i.status == "snoozed")
        |> Repo.update_all(set: [status: "pending", fired_at: now, snoozed_until: nil])

      if count == 1, do: Oban.insert!(ReminderEmailWorker.new(%{instance_id: instance_id}))
    end)
  end

  defp safely(label, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "[ReminderDispatcher] #{label} failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end
end
