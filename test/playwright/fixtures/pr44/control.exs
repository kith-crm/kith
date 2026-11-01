Code.require_file("boot.exs", __DIR__)

defmodule PR44Control do
  import Ecto.Query
  alias Kith.{Accounts, Contacts, Imports, Reminders, Repo}
  alias Kith.Contacts.{Contact, DuplicateCandidate, Note}
  alias Kith.Reminders.{Dispatcher, ReminderInstance}

  def run("prepare", args) do
    email = "pr44-#{System.system_time(:microsecond)}@test.local"
    {:ok, user} = Accounts.register_user(%{"email" => email, "password" => "ValidP@ssword123!"})
    {token, _} = Accounts.generate_api_token(user)
    base = %{email: email, token: token, account_id: user.account_id, user_id: user.id}

    case args["scenario"] do
      "duplicates" ->
        a = contact!(user, "Alex Colleague")
        b = contact!(user, "Incomplete Record")
        c = contact!(user, "Alex Cousin")
        pair!(user.account_id, a.id, c.id, ["name_match"])
        {:ok, import_job} = Imports.create_import(user.account_id, user.id, %{source: "vcard"})
        {:ok, _} = Imports.update_import_status(import_job, "completed")

        for {source, contact} <- [{"a", a}, {"c", c}] do
          {:ok, _} =
            Imports.record_imported_entity(import_job, "contact", source, "contact", contact.id)
        end

        Map.merge(base, %{a: a.id, b: b.id, c: c.id})

      "reminder" ->
        contact = contact!(user, "Mona Reminder", %{deceased: args["deceased"] == true})
        title = if contact.deceased, do: "Visit grave", else: "Queued reminder"

        {:ok, reminder} =
          Reminders.create_reminder(user.account_id, user.id, %{
            type: "one_time",
            title: title,
            contact_id: contact.id,
            anchor_date: Reminders.account_today(user.account_id)
          })

        Map.merge(base, %{contact_id: contact.id, reminder_id: reminder.id, title: title})

      "editor" ->
        contact = contact!(user, "Editor Security")
        Map.put(base, :contact_id, contact.id)

      "import" ->
        base
    end
  end

  def run("automerge", args) do
    pair!(args["account_id"], args["a"], args["b"], ["email_match"])
    pair!(args["account_id"], args["b"], args["c"], ["phone_match"])
    results = for _ <- 1..2, do: Kith.Imports.DuplicateAutomerge.run(args["account_id"])
    account_id = args["account_id"]

    live =
      Repo.all(
        from(c in Contact,
          where: c.account_id == ^account_id and is_nil(c.deleted_at),
          select: c.id
        )
      )

    dismissed =
      Repo.aggregate(
        from(d in DuplicateCandidate,
          where: d.account_id == ^account_id and d.status == "dismissed"
        ),
        :count
      )

    a_survivor = Imports.find_import_record(account_id, "vcard", "contact", "a").local_entity_id
    c_survivor = Imports.find_import_record(account_id, "vcard", "contact", "c").local_entity_id

    %{
      results: results,
      live_ids: live,
      dismissed: dismissed,
      a_survivor: a_survivor,
      c_survivor: c_survivor
    }
  end

  def run("drain_import", args) do
    result = Oban.drain_queue(queue: :imports, with_recursion: true, with_safety: false)
    if result.failure != 0, do: raise("Import queue failures: #{inspect(result)}")
    import_snapshot(args["account_id"])
  end

  def run("import_snapshot", args), do: import_snapshot(args["account_id"])

  def run("retry_misc", args) do
    account_id = args["account_id"]

    job =
      Repo.one!(
        from(j in Oban.Job,
          where: j.worker == "Kith.Workers.MonicaMiscDataWorker",
          where: fragment("(?->>'import_id')::bigint = ?", j.args, ^args["import_id"]),
          order_by: [desc: j.id],
          limit: 1
        )
      )

    # The release poller has not been drained, so the fixture key is still available.
    :ok = Kith.Workers.MonicaMiscDataWorker.perform(job)
    import_snapshot(account_id)
  end

  def run("dispatch", args) do
    today = Reminders.account_today(args["account_id"])
    :ok = Dispatcher.run(DateTime.new!(today, ~T[23:00:00], "Etc/UTC"))
    reminder_snapshot(args["reminder_id"])
  end

  def run("reminder_snapshot", args), do: reminder_snapshot(args["reminder_id"])

  def run("deliver", args) do
    instance =
      Repo.one!(from(i in ReminderInstance, where: i.reminder_id == ^args["reminder_id"]))

    job_ids =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Kith.Workers.ReminderEmailWorker",
          where: fragment("(?->>'instance_id')::bigint = ?", j.args, ^instance.id),
          where: j.state in ["available", "retryable", "scheduled"],
          select: j.id
        )
      )

    if job_ids == [], do: raise("No queued email jobs for instance #{instance.id}")
    Oban.drain_queue(queue: :reminders, with_recursion: true, with_safety: false)
    states = Repo.all(from(j in Oban.Job, where: j.id in ^job_ids, select: j.state))

    %{
      completed: Enum.count(states, &(&1 == "completed")),
      discarded: Enum.count(states, &(&1 == "discarded")),
      states: states,
      snapshot: reminder_snapshot(args["reminder_id"])
    }
  end

  def run("expire_snooze", args) do
    instance =
      Repo.one!(from(i in ReminderInstance, where: i.reminder_id == ^args["reminder_id"]))

    "snoozed" = instance.status

    instance
    |> Ecto.Changeset.change(snoozed_until: DateTime.add(DateTime.utc_now(:second), -60))
    |> Repo.update!()

    reminder_snapshot(args["reminder_id"])
  end

  defp contact!(user, first_name, extra \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(user.account_id, Map.merge(%{first_name: first_name}, extra))

    contact
  end

  defp pair!(account_id, a, b, reasons) do
    {low, high} = {min(a, b), max(a, b)}

    Repo.insert!(
      %DuplicateCandidate{
        account_id: account_id,
        contact_id: low,
        duplicate_contact_id: high,
        score: 1.0,
        reasons: reasons,
        status: "pending",
        detected_at: DateTime.utc_now(:second)
      },
      on_conflict: :nothing
    )
  end

  defp import_snapshot(account_id) do
    import_job =
      Repo.one(
        from(i in Imports.Import,
          where: i.account_id == ^account_id,
          order_by: [desc: i.id],
          limit: 1
        )
      )

    contacts =
      Repo.all(
        from(c in Contact,
          where: c.account_id == ^account_id and is_nil(c.deleted_at),
          select: %{id: c.id, name: c.display_name}
        )
      )

    notes =
      Repo.all(
        from(n in Note, where: n.account_id == ^account_id, order_by: n.body, select: n.body)
      )

    messages =
      Repo.all(
        from(m in Kith.Conversations.Message,
          where: m.account_id == ^account_id,
          order_by: m.direction,
          select: %{
            id: m.id,
            direction: m.direction,
            body: m.body,
            conversation_id: m.conversation_id
          }
        )
      )

    mappings =
      Repo.aggregate(from(r in Imports.ImportRecord, where: r.account_id == ^account_id), :count)

    %{
      contacts: contacts,
      notes: notes,
      messages: messages,
      mappings: mappings,
      import_id: import_job && import_job.id,
      import_status: import_job && import_job.status
    }
  end

  defp reminder_snapshot(reminder_id) do
    instance = Repo.one(from(i in ReminderInstance, where: i.reminder_id == ^reminder_id))

    jobs =
      if instance do
        Repo.aggregate(
          from(j in Oban.Job,
            where: j.worker == "Kith.Workers.ReminderEmailWorker",
            where: fragment("(?->>'instance_id')::bigint = ?", j.args, ^instance.id)
          ),
          :count
        )
      else
        0
      end

    %{
      instance_id: instance && instance.id,
      status: instance && instance.status,
      snoozed_until: instance && instance.snoozed_until,
      email_jobs: jobs
    }
  end
end

[action, payload] = System.argv()
result = PR44Control.run(action, Jason.decode!(payload))
IO.puts("PR44_RESULT=" <> Jason.encode!(result))
