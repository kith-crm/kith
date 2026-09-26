defmodule Kith.Reminders do
  @moduledoc """
  The Reminders context — manages reminders, reminder rules, and reminder instances.

  All reminder mutations use `Ecto.Multi` to transactionally manage both the
  reminder record and associated Oban jobs. The standard cancellation pattern
  cancels existing jobs FIRST (via `Oban.cancel_job/1`), then performs the DB
  mutation. This ordering is intentional: a cancelled-but-orphaned job is harmless,
  while an un-cancelled job firing on stale data would be worse.
  """

  import Ecto.Query, warn: false
  import Kith.Scope

  alias Ecto.Multi
  alias Kith.Repo
  alias Kith.TimeHelper

  alias Kith.Accounts
  alias Kith.Workers.ReminderNotificationWorker

  alias Kith.Reminders.{
    Reminder,
    ReminderInstance,
    ReminderRule
  }

  # ── Reminders CRUD ──────────────────────────────────────────────────────

  @doc """
  Lists active reminders for a contact, scoped to account.
  """
  def list_reminders(account_id, contact_id) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id and r.active == true)
    |> order_by([r], asc: r.next_reminder_date)
    |> Repo.all()
  end

  @doc """
  Fetches a reminder by ID, scoped to account. Raises if not found.
  """
  def get_reminder!(account_id, id) do
    Reminder
    |> scope_to_account(account_id)
    |> Repo.get!(id)
  end

  @doc """
  Fetches a reminder by ID, scoped to account. Returns `nil` if not found.
  """
  def get_reminder(account_id, id) do
    Reminder
    |> scope_to_account(account_id)
    |> Repo.get(id)
  end

  @doc """
  Creates a reminder with transactional Oban job enqueue.
  """
  def create_reminder(account_id, creator_id, attrs) do
    account = Accounts.get_account!(account_id)

    Multi.new()
    |> Multi.insert(:reminder, fn _changes ->
      %Reminder{account_id: account_id, creator_id: creator_id}
      |> Reminder.create_changeset(attrs)
    end)
    |> Multi.run(:enqueue_jobs, fn _repo, %{reminder: reminder} ->
      enqueue_jobs_for_reminder(reminder, account)
    end)
    |> Multi.run(:store_job_ids, fn repo, %{reminder: reminder, enqueue_jobs: job_ids} ->
      reminder
      |> Reminder.job_ids_changeset(job_ids)
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{store_job_ids: reminder}} -> {:ok, reminder}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Updates a reminder: cancels old Oban jobs, updates record, enqueues new jobs.
  """
  def update_reminder(%Reminder{} = reminder, attrs) do
    account = Accounts.get_account!(reminder.account_id)

    Multi.new()
    |> cancel_enqueued_jobs_step(reminder)
    |> Multi.update(:reminder, Reminder.update_changeset(reminder, attrs))
    |> Multi.run(:enqueue_jobs, fn _repo, %{reminder: updated} ->
      enqueue_jobs_for_reminder(updated, account)
    end)
    |> Multi.run(:store_job_ids, fn repo, %{reminder: updated, enqueue_jobs: job_ids} ->
      updated
      |> Reminder.job_ids_changeset(job_ids)
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{store_job_ids: reminder}} -> {:ok, reminder}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Deletes a reminder: cancels all enqueued Oban jobs first.
  """
  def delete_reminder(%Reminder{} = reminder) do
    Multi.new()
    |> cancel_enqueued_jobs_step(reminder)
    |> Multi.delete(:reminder, reminder)
    |> Repo.transaction()
    |> case do
      {:ok, %{reminder: reminder}} -> {:ok, reminder}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  # ── Birthday Reminder Auto-Creation ─────────────────────────────────────

  @doc """
  Creates a birthday reminder for a contact. Called from the Contacts context
  when a birthdate is set.
  """
  def create_birthday_reminder(
        %{id: contact_id, account_id: account_id, birthdate: birthdate},
        creator_id
      )
      when not is_nil(birthdate) do
    next_date = TimeHelper.next_birthday_date(birthdate)

    create_reminder(account_id, creator_id, %{
      type: "birthday",
      title: nil,
      frequency: nil,
      next_reminder_date: next_date,
      contact_id: contact_id
    })
  end

  @doc """
  Converts an existing reminder into `contact`'s birthday reminder in place,
  keeping its id (and any import mapping that points at it) while re-syncing
  its Oban notification jobs. Returns `{:error, changeset}` if the contact
  already has a distinct birthday reminder.
  """
  def convert_to_birthday_reminder(%Reminder{} = reminder, %{birthdate: %Date{} = birthdate}) do
    account = Accounts.get_account!(reminder.account_id)
    next_date = TimeHelper.next_birthday_date(birthdate)

    Multi.new()
    |> cancel_enqueued_jobs_step(reminder)
    |> Multi.update(:reminder, Reminder.convert_to_birthday_changeset(reminder, next_date))
    |> Multi.run(:enqueue_jobs, fn _repo, %{reminder: updated} ->
      enqueue_jobs_for_reminder(updated, account)
    end)
    |> Multi.run(:store_job_ids, fn repo, %{reminder: updated, enqueue_jobs: job_ids} ->
      updated
      |> Reminder.job_ids_changeset(job_ids)
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{store_job_ids: reminder}} -> {:ok, reminder}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Deletes the birthday reminder for a contact. Called when birthdate is removed.
  """
  def delete_birthday_reminder(contact_id, account_id) do
    case get_birthday_reminder(contact_id, account_id) do
      nil -> {:ok, :no_birthday_reminder}
      reminder -> delete_reminder(reminder)
    end
  end

  @doc """
  Returns the birthday reminder for a contact, or nil.
  """
  def get_birthday_reminder(contact_id, account_id) do
    Reminder
    |> scope_to_account(account_id)
    |> where([r], r.contact_id == ^contact_id and r.type == "birthday")
    |> Repo.one()
  end

  # ── Stay-in-Touch Resolution ────────────────────────────────────────────

  @doc """
  Resolves a pending stay-in-touch instance for a contact. Called from the
  Activities/Calls context when an interaction is logged.

  Safe to call even if no stay-in-touch reminder exists for the contact.
  """
  def resolve_stay_in_touch_instance(contact_id) do
    with %Reminder{} = reminder <- get_stay_in_touch_reminder(contact_id),
         %ReminderInstance{} = instance <- get_pending_instance(reminder.id) do
      next_date = TimeHelper.advance_by_frequency(Date.utc_today(), reminder.frequency)

      Multi.new()
      |> Multi.update(
        :instance,
        ReminderInstance.resolve_changeset(instance)
      )
      |> Multi.update(
        :reminder,
        Reminder.update_changeset(reminder, %{
          next_reminder_date: next_date,
          enqueued_oban_job_ids: []
        })
      )
      |> Repo.transaction()
      |> case do
        {:ok, _} -> {:ok, :resolved}
        {:error, _step, changeset, _} -> {:error, changeset}
      end
    else
      nil -> {:ok, :no_pending_instance}
    end
  end

  # `limit: 1` rather than a bare `Repo.one/1`: nothing in the schema enforces
  # one active stay-in-touch reminder per contact (the only partial unique
  # index on `reminders` covers birthdays), so any path that creates a second
  # one — a merge, the API, a restored contact — would otherwise turn this
  # into an `Ecto.MultipleResultsError` at the caller. `Kith.Contacts.Merge`
  # dedupes on merge; this keeps the read total regardless.
  defp get_stay_in_touch_reminder(contact_id) do
    from(r in Reminder,
      where: r.contact_id == ^contact_id and r.type == "stay_in_touch" and r.active == true,
      order_by: [asc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  # ── Contact Archival / Deletion Helpers ─────────────────────────────────

  @doc """
  Handles stay-in-touch reminders when a contact is archived.
  Cancels Oban jobs, dismisses pending instances, deactivates reminder.
  """
  def archive_contact_reminders(contact_id, account_id) do
    reminders =
      Reminder
      |> scope_to_account(account_id)
      |> where(
        [r],
        r.contact_id == ^contact_id and r.type == "stay_in_touch" and r.active == true
      )
      |> Repo.all()

    Enum.each(reminders, fn reminder ->
      cancel_jobs(reminder.enqueued_oban_job_ids)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(i in ReminderInstance,
        where: i.reminder_id == ^reminder.id and i.status == "pending"
      )
      |> Repo.update_all(set: [status: "dismissed", resolved_at: now])

      reminder
      |> Ecto.Changeset.change(%{active: false, enqueued_oban_job_ids: []})
      |> Repo.update()
    end)

    :ok
  end

  @doc """
  Cancels all active Oban jobs for all reminders belonging to a contact.
  Intended to be called from contact merge or hard-delete flows within
  an `Ecto.Multi`.
  """
  def cancel_all_for_contact(contact_id, account_id) do
    reminders =
      Reminder
      |> scope_to_account(account_id)
      |> where([r], r.contact_id == ^contact_id)
      |> select([r], r.enqueued_oban_job_ids)
      |> Repo.all()

    results =
      reminders
      |> List.flatten()
      |> Enum.map(&Oban.cancel_job/1)

    {:ok, results}
  end

  # ── Reminder Instance Management ────────────────────────────────────────

  @doc """
  Resolves a pending ReminderInstance. For stay-in-touch reminders,
  also updates next_reminder_date.
  """
  def resolve_instance(%ReminderInstance{} = instance) do
    instance = Repo.preload(instance, :reminder)

    Multi.new()
    |> Multi.update(:instance, ReminderInstance.resolve_changeset(instance))
    |> maybe_advance_stay_in_touch(:reminder, instance.reminder)
    |> Repo.transaction()
    |> case do
      {:ok, %{instance: instance}} -> {:ok, instance}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Snoozes a pending ReminderInstance for the given duration.
  Only works on instances with "pending" status.
  """
  def snooze_instance(%ReminderInstance{status: "pending"} = instance, duration) do
    instance
    |> ReminderInstance.snooze_changeset(duration)
    |> Repo.update()
  end

  def snooze_instance(%ReminderInstance{}, _duration) do
    {:error, :invalid_status}
  end

  @doc """
  Dismisses a pending ReminderInstance. Same scheduling effect as resolve.
  """
  def dismiss_instance(%ReminderInstance{} = instance) do
    instance = Repo.preload(instance, :reminder)

    Multi.new()
    |> Multi.update(:instance, ReminderInstance.dismiss_changeset(instance))
    |> maybe_advance_stay_in_touch(:reminder, instance.reminder)
    |> Repo.transaction()
    |> case do
      {:ok, %{instance: instance}} -> {:ok, instance}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  defp maybe_advance_stay_in_touch(multi, key, %Reminder{type: "stay_in_touch"} = reminder) do
    next_date = TimeHelper.advance_by_frequency(Date.utc_today(), reminder.frequency)

    Multi.update(
      multi,
      key,
      Reminder.update_changeset(reminder, %{
        next_reminder_date: next_date,
        enqueued_oban_job_ids: []
      })
    )
  end

  defp maybe_advance_stay_in_touch(multi, _key, _reminder), do: multi

  # ── Upcoming Reminders Query ────────────────────────────────────────────

  @doc """
  Returns reminders due within `window_days` for an account.
  Excludes deceased, deleted, and archived contacts.
  """
  def upcoming(account_id, window_days \\ 30) do
    today = Date.utc_today()
    cutoff = Date.add(today, window_days)

    from(r in Reminder,
      where: r.account_id == ^account_id,
      where: r.active == true,
      where: r.next_reminder_date >= ^today,
      where: r.next_reminder_date <= ^cutoff,
      join: c in assoc(r, :contact),
      where: is_nil(c.deleted_at),
      where: c.is_archived == false,
      where: c.deceased == false,
      order_by: [asc: r.next_reminder_date],
      preload: [:contact]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of upcoming reminders (30-day window) for the dashboard widget.
  """
  def upcoming_count(account_id) do
    today = Date.utc_today()
    cutoff = Date.add(today, 30)

    from(r in Reminder,
      where: r.account_id == ^account_id,
      where: r.active == true,
      where: r.next_reminder_date >= ^today,
      where: r.next_reminder_date <= ^cutoff,
      join: c in assoc(r, :contact),
      where: is_nil(c.deleted_at),
      where: c.is_archived == false,
      where: c.deceased == false
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns pending ReminderInstances for an account, preloaded with reminder and contact.
  """
  def list_pending_instances(account_id) do
    ReminderInstance
    |> scope_to_account(account_id)
    |> where([i], i.status == "pending")
    |> order_by([i], asc: i.scheduled_for)
    |> preload([:reminder, :contact])
    |> Repo.all()
  end

  # ── Reminder Rules ──────────────────────────────────────────────────────

  @doc """
  Lists all reminder rules for an account.
  """
  def list_reminder_rules(account_id) do
    ReminderRule
    |> scope_to_account(account_id)
    |> order_by([r], asc: r.days_before)
    |> Repo.all()
  end

  @doc """
  Returns active reminder rules for an account (used by scheduler).
  """
  def active_rules(account_id) do
    ReminderRule
    |> scope_to_account(account_id)
    |> where([r], r.active == true)
    |> Repo.all()
  end

  @doc """
  Toggle a reminder rule's active state. The on-day rule (days_before: 0)
  cannot be deactivated — enforced here, not at schema level.
  """
  def toggle_reminder_rule(%ReminderRule{days_before: 0, active: true}) do
    {:error, :cannot_deactivate_on_day_rule}
  end

  def toggle_reminder_rule(%ReminderRule{} = rule) do
    rule
    |> ReminderRule.toggle_changeset()
    |> Repo.update()
  end

  @doc "Gets a reminder rule by ID, scoped to account."
  def get_reminder_rule!(account_id, id) do
    ReminderRule
    |> scope_to_account(account_id)
    |> Repo.get!(id)
  end

  @doc "Creates a new reminder rule for an account."
  def create_reminder_rule(account_id, attrs) do
    %ReminderRule{account_id: account_id}
    |> ReminderRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a reminder rule. The on-day rule (days_before: 0) cannot be deactivated.
  """
  def update_reminder_rule(%ReminderRule{days_before: 0} = _rule, %{active: false}) do
    {:error, :cannot_deactivate_on_day_rule}
  end

  def update_reminder_rule(%ReminderRule{days_before: 0} = _rule, %{"active" => false}) do
    {:error, :cannot_deactivate_on_day_rule}
  end

  def update_reminder_rule(%ReminderRule{} = rule, attrs) do
    rule
    |> ReminderRule.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a reminder rule."
  def delete_reminder_rule(%ReminderRule{} = rule) do
    Repo.delete(rule)
  end

  @doc """
  Seeds default reminder rules for a new account.
  """
  def seed_default_rules(account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      ReminderRule.default_rules()
      |> Enum.map(fn rule ->
        Map.merge(rule, %{account_id: account_id, inserted_at: now, updated_at: now})
      end)

    Repo.insert_all(ReminderRule, entries, on_conflict: :nothing)
  end

  # ── Oban Job Enqueue / Cancel Helpers ───────────────────────────────────

  @doc """
  Standard cancellation pattern: cancel all Oban jobs listed in
  a reminder's `enqueued_oban_job_ids`. Idempotent — safe to call
  on already-cancelled or completed jobs.
  """
  def cancel_jobs(job_ids) when is_list(job_ids) do
    job_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&Oban.cancel_job/1)
  end

  defp cancel_enqueued_jobs_step(multi, reminder) do
    Multi.run(multi, :cancel_jobs, fn _repo, _changes ->
      cancel_jobs(reminder.enqueued_oban_job_ids)
      {:ok, :cancelled}
    end)
  end

  @doc """
  Enqueues Oban notification jobs for a reminder based on account settings
  and active reminder rules. Returns the list of Oban job IDs.
  """
  def enqueue_jobs_for_reminder(%Reminder{} = reminder, account) do
    rules = active_rules(account.id)

    on_day_at =
      TimeHelper.to_utc_scheduled_at(
        reminder.next_reminder_date,
        account.send_hour,
        account.timezone
      )

    on_day_args = %{
      reminder_id: reminder.id,
      type: "on_day",
      days_before: 0
    }

    on_day_jobs =
      if DateTime.compare(on_day_at, DateTime.utc_now()) == :gt do
        [{on_day_args, on_day_at}]
      else
        []
      end

    # Pre-notification jobs only for birthday and one_time types
    pre_jobs =
      if reminder.type in ["birthday", "one_time"] do
        rules
        |> Enum.filter(fn rule -> rule.days_before > 0 end)
        |> Enum.map(fn rule ->
          pre_date = Date.add(reminder.next_reminder_date, -rule.days_before)

          pre_at =
            TimeHelper.to_utc_scheduled_at(pre_date, account.send_hour, account.timezone)

          args = %{
            reminder_id: reminder.id,
            type: "pre_notification",
            days_before: rule.days_before
          }

          {args, pre_at}
        end)
        |> Enum.filter(fn {_args, scheduled_at} ->
          DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt
        end)
      else
        []
      end

    all_jobs = on_day_jobs ++ pre_jobs

    job_ids =
      Enum.map(all_jobs, fn {args, scheduled_at} ->
        {:ok, job} =
          args
          |> ReminderNotificationWorker.new(scheduled_at: scheduled_at)
          |> Oban.insert()

        job.id
      end)

    {:ok, job_ids}
  end

  # ── Internal Helpers ────────────────────────────────────────────────────

  @doc false
  def get_pending_instance(reminder_id) do
    from(i in ReminderInstance,
      where: i.reminder_id == ^reminder_id and i.status == "pending",
      limit: 1
    )
    |> Repo.one()
  end

  @doc false
  def has_pending_instance?(reminder_id) do
    from(i in ReminderInstance,
      where: i.reminder_id == ^reminder_id and i.status == "pending"
    )
    |> Repo.exists?()
  end
end
