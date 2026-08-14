defmodule Kith.Workers.MonicaMiscDataWorker do
  @moduledoc """
  Oban worker that imports the per-contact "miscellaneous" data types
  (pets, calls, activities, gifts, debts, tasks, reminders, conversations)
  for an already-completed Monica API crawl.

  Enqueued by `Kith.Workers.MonicaApiCrawlWorker` on successful completion,
  carrying:

    * `"import_id"` — the Import row this job belongs to.
    * `"credential_url"`, `"credential_api_key"` — the credential needed to
      keep calling Monica after the main crawl wipes `api_key_encrypted`.
      Same pattern as `MonicaPhotoSyncWorker`.
    * `"plan"` — list of `%{"source_id", "local_id", "endpoints"}` maps
      pre-filtered during the main crawl using Monica's `statistics.*`
      fields, so we only fire the endpoints with data.

  Throttled through `Kith.Imports.Sources.MonicaApi.RateLimiter` (same
  per-host bucket as the main crawler).

  Exits early if the import has been cancelled. Contacts that were
  soft-deleted between main-crawl completion and this job's dispatch are
  silently skipped.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi.RateLimiter
  alias Kith.Repo

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    import_job = Imports.get_import!(args["import_id"])

    if import_job.status in ["cancelled", "failed"] do
      :ok
    else
      credential = build_credential(args)
      plan = args["plan"] || []

      counts = process_plan(plan, credential, import_job)

      summary = Map.put(import_job.summary || %{}, "misc", counts)

      Imports.update_import_status(import_job, import_job.status, %{summary: summary})

      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_misc_complete, counts})

      :ok
    end
  end

  defp build_credential(args) do
    %{
      url: args["credential_url"],
      api_key: args["credential_api_key"],
      req_options: Application.get_env(:kith, :monica_req_options, [])
    }
  end

  defp process_plan(plan, credential, import_job) do
    initial = %{
      "pets" => 0,
      "calls" => 0,
      "activities" => 0,
      "gifts" => 0,
      "debts" => 0,
      "tasks" => 0,
      "reminders" => 0,
      "conversations" => 0
    }

    user_id = import_job.user_id

    Enum.reduce(plan, initial, fn entry, counts ->
      process_entry(entry, credential, user_id, import_job, counts)
    end)
  end

  defp process_entry(entry, credential, user_id, import_job, counts) do
    contact = Contacts.get_contact_for_misc(entry["local_id"])

    if contact == nil or not is_nil(contact.deleted_at) do
      counts
    else
      Enum.reduce(entry["endpoints"] || [], counts, fn endpoint, counts ->
        n = fire_endpoint(endpoint, credential, user_id, contact, entry["source_id"], import_job)
        Map.update(counts, endpoint, n, &(&1 + n))
      end)
    end
  end

  defp fire_endpoint("pets", c, _u, contact, src, ij),
    do: import_contact_pets(c, contact, src, ij)

  defp fire_endpoint("calls", c, _u, contact, src, ij),
    do: import_contact_calls(c, contact, src, ij)

  defp fire_endpoint("activities", c, _u, contact, src, ij),
    do: import_contact_activities(c, contact, src, ij)

  defp fire_endpoint("gifts", c, u, contact, src, ij),
    do: import_contact_gifts(c, u, contact, src, ij)

  defp fire_endpoint("debts", c, u, contact, src, ij),
    do: import_contact_debts(c, u, contact, src, ij)

  defp fire_endpoint("tasks", c, u, contact, src, ij),
    do: import_contact_tasks(c, u, contact, src, ij)

  defp fire_endpoint("reminders", c, u, contact, src, ij),
    do: import_contact_reminders(c, u, contact, src, ij)

  defp fire_endpoint("conversations", c, u, contact, src, ij),
    do: import_contact_conversations(c, u, contact, src, ij)

  defp fire_endpoint(other, _, _, _, _, _) do
    Logger.warning("[MonicaMiscData] unknown endpoint #{inspect(other)}; skipping")
    0
  end

  # ── HTTP wrapper ──────────────────────────────────────────────────────

  defp api_get_json(credential, url, params) do
    RateLimiter.wait!(credential.url)

    headers = [
      {"Authorization", "Bearer #{credential.api_key}"},
      {"Accept", "application/json"}
    ]

    options =
      [
        headers: headers,
        params: params,
        max_retries: 5,
        retry_log_level: :warn
      ] ++ Map.get(credential, :req_options, [])

    case Req.get(url, options) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Per-contact endpoint helpers ─────────────────────────────────────
  #
  # Each top-level helper returns the count of items successfully imported
  # for the per-endpoint summary aggregate. Per-item helpers return either
  # `:ok` (success) or `{:error, _}` (skipped/failed).

  defp import_contact_pets(credential, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/pets"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => pets}} when is_list(pets) ->
        Enum.count(pets, fn pet ->
          match?(:ok, import_single_pet(contact.account_id, contact, pet, import_job))
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch pets for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_pet(account_id, contact, pet_data, import_job) do
    name = pet_data["name"]
    species = normalize_pet_species(pet_data["pet_category"] || pet_data["species"])

    if pet_duplicate?(contact.id, name, species) do
      {:error, :duplicate}
    else
      attrs = %{
        "contact_id" => contact.id,
        "name" => name || "Unknown",
        "species" => species,
        "breed" => non_empty_string(pet_data["breed"]),
        "notes" => non_empty_string(pet_data["notes"])
      }

      case Kith.Pets.create_pet(account_id, attrs) do
        {:ok, pet} ->
          maybe_record_entity(import_job, "pet", pet_data["id"], "pet", pet.id)
          :ok

        {:error, reason} ->
          Logger.warning("[MonicaMiscData] pet error: #{inspect_errors(reason)}")
          {:error, reason}
      end
    end
  end

  defp import_contact_calls(credential, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/calls"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => calls}} when is_list(calls) ->
        Enum.count(calls, fn call ->
          match?(:ok, import_single_call(contact.account_id, contact, call, import_job))
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch calls for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_call(account_id, contact, call_data, import_job) do
    occurred_at = parse_datetime(call_data["called_at"])

    if is_nil(occurred_at) do
      {:error, :no_timestamp}
    else
      attrs = %{
        "occurred_at" => occurred_at,
        "notes" => non_empty_string(call_data["content"]),
        "duration_mins" => call_data["duration"]
      }

      case Kith.Activities.create_call(%{account_id: account_id, id: contact.id}, attrs) do
        {:ok, call} ->
          maybe_record_entity(import_job, "call", call_data["id"], "call", call.id)
          :ok

        {:error, reason} ->
          Logger.warning("[MonicaMiscData] call error: #{inspect_errors(reason)}")
          {:error, reason}
      end
    end
  end

  defp import_contact_activities(credential, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/activities"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => activities}} when is_list(activities) ->
        Enum.count(activities, fn activity ->
          match?(:ok, import_single_activity(contact.account_id, contact, activity, import_job))
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch activities for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_activity(account_id, contact, activity_data, import_job) do
    occurred_at =
      parse_datetime(activity_data["happened_at"] || activity_data["date_it_happened"])

    attrs = %{
      "title" => activity_data["summary"] || activity_data["title"] || "Imported activity",
      "description" => non_empty_string(activity_data["description"]),
      "occurred_at" => occurred_at || DateTime.utc_now()
    }

    case Kith.Activities.create_activity(account_id, attrs, [contact.id]) do
      {:ok, activity} ->
        maybe_record_entity(import_job, "activity", activity_data["id"], "activity", activity.id)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] activity error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_contact_gifts(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/gifts"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => gifts}} when is_list(gifts) ->
        Enum.count(gifts, fn gift ->
          match?(
            :ok,
            import_single_gift(contact.account_id, user_id, contact, gift, import_job)
          )
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch gifts for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_gift(account_id, user_id, contact, gift_data, import_job) do
    direction =
      case gift_data["is_for"] do
        "contact" -> "given"
        _ -> "received"
      end

    attrs = %{
      "contact_id" => contact.id,
      "name" => gift_data["name"] || "Imported gift",
      "description" => non_empty_string(gift_data["comment"]),
      "direction" => direction,
      "status" =>
        cond do
          gift_data["has_been_offered"] -> "given"
          gift_data["has_been_received"] -> "received"
          true -> "idea"
        end,
      "amount" => gift_data["amount"],
      "date" => parse_date_string(gift_data["date"])
    }

    case Kith.Gifts.create_gift(account_id, user_id, attrs) do
      {:ok, gift} ->
        maybe_record_entity(import_job, "gift", gift_data["id"], "gift", gift.id)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] gift error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_contact_debts(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/debts"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => debts}} when is_list(debts) ->
        Enum.count(debts, fn debt ->
          match?(
            :ok,
            import_single_debt(contact.account_id, user_id, contact, debt, import_job)
          )
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch debts for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_debt(account_id, user_id, contact, debt_data, import_job) do
    direction =
      case debt_data["in_debt"] do
        "yes" -> "owed_by_me"
        _ -> "owed_to_me"
      end

    attrs = %{
      "contact_id" => contact.id,
      "title" => debt_data["reason"] || "Imported debt",
      "amount" => debt_data["amount"] || "0",
      "direction" => direction,
      "status" => if(debt_data["status"] == "complete", do: "settled", else: "active")
    }

    case Kith.Debts.create_debt(account_id, user_id, attrs) do
      {:ok, debt} ->
        maybe_record_entity(import_job, "debt", debt_data["id"], "debt", debt.id)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] debt error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_contact_tasks(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/tasks"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => tasks}} when is_list(tasks) ->
        Enum.count(tasks, fn task ->
          match?(
            :ok,
            import_single_task(contact.account_id, user_id, contact, task, import_job)
          )
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch tasks for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_task(account_id, user_id, contact, task_data, import_job) do
    status = if task_data["completed"], do: "completed", else: "pending"

    attrs = %{
      "contact_id" => contact.id,
      "title" => task_data["title"] || "Imported task",
      "description" => non_empty_string(task_data["description"]),
      "status" => status
    }

    case Kith.Tasks.create_task(account_id, user_id, attrs) do
      {:ok, task} ->
        maybe_record_entity(import_job, "task", task_data["id"], "task", task.id)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] task error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_contact_reminders(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/reminders"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => reminders}} when is_list(reminders) ->
        Enum.count(reminders, fn reminder ->
          match?(
            :ok,
            import_single_reminder(contact.account_id, user_id, contact, reminder, import_job)
          )
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch reminders for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp import_single_reminder(account_id, user_id, contact, reminder_data, import_job) do
    {type, frequency} = map_monica_reminder_frequency(reminder_data["frequency_type"])

    next_date =
      parse_date_string(reminder_data["next_expected_date"]) ||
        Date.utc_today()

    attrs = %{
      "contact_id" => contact.id,
      "type" => type,
      "title" => reminder_data["title"] || "Imported reminder",
      "frequency" => frequency,
      "next_reminder_date" => next_date
    }

    case Kith.Reminders.create_reminder(account_id, user_id, attrs) do
      {:ok, reminder} ->
        maybe_record_entity(import_job, "reminder", reminder_data["id"], "reminder", reminder.id)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] reminder error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_contact_conversations(credential, user_id, contact, source_id, import_job) do
    url = "#{credential.url}/api/contacts/#{source_id}/conversations"

    case api_get_json(credential, url, []) do
      {:ok, %{"data" => convos}} when is_list(convos) ->
        Enum.count(convos, fn convo ->
          match?(
            :ok,
            import_single_conversation(
              contact.account_id,
              user_id,
              contact,
              convo,
              import_job
            )
          )
        end)

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch conversations for contact #{source_id}: " <>
            inspect(reason)
        )

        0
    end
  end

  defp import_single_conversation(account_id, user_id, contact, convo_data, import_job) do
    platform =
      case convo_data["contact_field_type"] do
        %{"name" => name} -> normalize_conversation_platform(name)
        _ -> "other"
      end

    attrs = %{
      "contact_id" => contact.id,
      "platform" => platform,
      "subject" => non_empty_string(convo_data["subject"])
    }

    case Kith.Conversations.create_conversation(account_id, user_id, attrs) do
      {:ok, conversation} ->
        maybe_record_entity(
          import_job,
          "conversation",
          convo_data["id"],
          "conversation",
          conversation.id
        )

        import_conversation_messages(conversation, convo_data, import_job)
        :ok

      {:error, reason} ->
        Logger.warning("[MonicaMiscData] conversation error: #{inspect_errors(reason)}")
        {:error, reason}
    end
  end

  defp import_conversation_messages(conversation, convo_data, import_job) do
    messages = convo_data["messages"] || []

    Enum.each(messages, fn msg ->
      attrs = %{
        "body" => msg["content"] || msg["written_by_me_body"] || "",
        "direction" => if(msg["written_by_me"], do: "sent", else: "received"),
        "sent_at" => parse_datetime(msg["written_at"]) || DateTime.utc_now()
      }

      case Kith.Conversations.add_message(conversation, attrs) do
        {:ok, message} ->
          maybe_record_entity(import_job, "message", msg["id"], "message", message.id)

        {:error, reason} ->
          Logger.warning("[MonicaMiscData] message error: #{inspect_errors(reason)}")
      end
    end)
  end

  # ── Local helpers (copied from MonicaApi) ────────────────────────────

  defp normalize_pet_species(nil), do: "other"

  defp normalize_pet_species(species) when is_map(species),
    do: normalize_pet_species(species["name"])

  defp normalize_pet_species(species) when is_binary(species) do
    normalized = String.downcase(species)

    if normalized in ~w(dog cat bird fish reptile rabbit hamster) do
      normalized
    else
      "other"
    end
  end

  defp normalize_pet_species(_), do: "other"

  defp pet_duplicate?(contact_id, name, species) do
    Repo.exists?(
      from p in Kith.Contacts.Pet,
        where:
          p.contact_id == ^contact_id and
            fragment("lower(coalesce(?, ''))", p.name) ==
              fragment("lower(coalesce(?, ''))", ^(name || "")) and
            p.species == ^species
    )
  end

  defp map_monica_reminder_frequency("one_time"), do: {"one_time", nil}
  defp map_monica_reminder_frequency("week"), do: {"recurring", "weekly"}
  defp map_monica_reminder_frequency("month"), do: {"recurring", "monthly"}
  defp map_monica_reminder_frequency("year"), do: {"recurring", "annually"}
  defp map_monica_reminder_frequency(_), do: {"one_time", nil}

  @platform_keywords [
    {"sms", "sms"},
    {"text", "sms"},
    {"whatsapp", "whatsapp"},
    {"telegram", "telegram"},
    {"email", "email"},
    {"instagram", "instagram"},
    {"messenger", "messenger"},
    {"facebook", "messenger"},
    {"signal", "signal"}
  ]

  defp normalize_conversation_platform(name) when is_binary(name) do
    normalized = String.downcase(name)

    Enum.find_value(@platform_keywords, "other", fn {keyword, platform} ->
      if String.contains?(normalized, keyword), do: platform
    end)
  end

  defp normalize_conversation_platform(_), do: "other"

  defp non_empty_string(nil), do: nil
  defp non_empty_string(""), do: nil
  defp non_empty_string(s) when is_binary(s), do: s
  defp non_empty_string(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_date_string(nil), do: nil

  defp parse_date_string(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        date

      {:error, _} ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> DateTime.to_date(dt)
          _ -> nil
        end
    end
  end

  defp parse_date_string(_), do: nil

  defp inspect_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  defp inspect_errors(other), do: inspect(other)

  defp maybe_record_entity(nil, _type, _id, _local_type, _local_id), do: :ok
  defp maybe_record_entity(_import, _type, nil, _local_type, _local_id), do: :ok

  defp maybe_record_entity(import_job, type, source_id, local_type, local_id) do
    Imports.record_imported_entity(import_job, type, to_string(source_id), local_type, local_id)
  end
end
