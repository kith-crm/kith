defmodule Kith.Reminders do
  @moduledoc """
  The Reminders context — reminders, reminder rules, and reminder instances.

  A reminder stores its schedule (`anchor_date` + optional interval) and a
  cached `next_reminder_date`. Nothing is scheduled per reminder: the hourly
  `Kith.Reminders.Dispatcher` finds what is due and records each notice it
  sends as a `ReminderInstance`, so writing a reminder is a plain row write.
  """

  import Ecto.Query, warn: false
  import Kith.Scope

  alias Ecto.Multi
  alias Kith.Accounts
  alias Kith.Repo
  alias Kith.TimeHelper

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
  Creates a reminder. `next_reminder_date` is computed from the schedule
  using today's date in the account's timezone.
  """
  def create_reminder(account_id, creator_id, attrs) do
    %Reminder{account_id: account_id, creator_id: creator_id}
    |> Reminder.create_changeset(attrs, account_today(account_id))
    |> Repo.insert()
  end

  @doc """
  Updates a reminder's title, schedule or active flag. A schedule change
  recomputes `next_reminder_date`.
  """
  def update_reminder(%Reminder{} = reminder, attrs) do
    reminder
    |> Reminder.update_changeset(attrs, account_today(reminder.account_id))
    |> Repo.update()
  end

  @doc """
  Deletes a reminder (its instances cascade).
  """
  def delete_reminder(%Reminder{} = reminder), do: Repo.delete(reminder)

  # ── Birthday Reminders ──────────────────────────────────────────────────

  @doc """
  Makes the contact's birthday reminder match its birthdate: creates it when a
  birthdate is set, re-anchors it when the birthdate changes, deletes it when
  the birthdate is removed. The reminder belongs to the account owner (design
  spec §6). An existing reminder's `active` flag is left as it is.
  """
  def sync_birthday(%Kith.Contacts.Contact{} = contact) do
    case {contact.birthdate, get_birthday_reminder(contact.id, contact.account_id)} do
      {nil, nil} ->
        {:ok, :none}

      {nil, %Reminder{} = reminder} ->
        with {:ok, _} <- delete_reminder(reminder), do: {:ok, :none}

      {%Date{} = birthdate, nil} ->
        case account_owner_id(contact.account_id) do
          nil ->
            {:error, :no_account_owner}

          owner_id ->
            create_reminder(contact.account_id, owner_id, %{
              type: "birthday",
              title: nil,
              anchor_date: birthdate,
              interval_unit: "year",
              interval_count: 1,
              contact_id: contact.id
            })
        end

      {%Date{} = birthdate, %Reminder{} = reminder} ->
        update_reminder(reminder, %{anchor_date: birthdate})
    end
  end

  # The account's owner: its earliest admin user (today, the only user).
  defp account_owner_id(account_id) do
    from(u in Kith.Accounts.User,
      where: u.account_id == ^account_id and u.role == "admin",
      order_by: [asc: u.inserted_at, asc: u.id],
      select: u.id,
      limit: 1
    )
    |> Repo.one()
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
  Resolves a pending stay-in-touch instance for a contact and re-arms the
  reminder one interval from today.

  Safe to call even if no stay-in-touch reminder exists for the contact.
  """
  def resolve_stay_in_touch_instance(contact_id) do
    with %Reminder{} = reminder <- get_stay_in_touch_reminder(contact_id),
         %ReminderInstance{} = instance <- get_pending_instance(reminder.id) do
      Multi.new()
      |> Multi.update(:instance, ReminderInstance.resolve_changeset(instance))
      |> Multi.update(
        :reminder,
        Reminder.rearm_changeset(reminder, account_today(reminder.account_id))
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

  # ── Contact Archival ────────────────────────────────────────────────────

  @doc """
  Handles stay-in-touch reminders when a contact is archived:
  dismisses pending instances and deactivates the reminder.
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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(i in ReminderInstance,
        where: i.reminder_id == ^reminder.id and i.status == "pending"
      )
      |> Repo.update_all(set: [status: "dismissed", resolved_at: now])

      reminder
      |> Ecto.Changeset.change(%{active: false})
      |> Repo.update()
    end)

    :ok
  end

  # ── Reminder Instance Management ────────────────────────────────────────

  @doc """
  Resolves a pending ReminderInstance. For stay-in-touch reminders,
  also re-arms next_reminder_date.
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
  Snoozes a pending ReminderInstance for the given duration. The dispatcher
  sends it again once `snoozed_until` has passed.
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
    Multi.update(
      multi,
      key,
      Reminder.rearm_changeset(reminder, account_today(reminder.account_id))
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

  defp account_today(account_id) do
    account_id |> Accounts.get_account!() |> Map.get(:timezone) |> TimeHelper.local_today()
  end
end
