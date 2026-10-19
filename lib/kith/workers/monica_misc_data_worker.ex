defmodule Kith.Workers.MonicaMiscDataWorker do
  @moduledoc """
  Oban worker that imports the per-contact "miscellaneous" data types
  (pets, calls, activities, gifts, debts, tasks, reminders, conversations,
  and notes beyond the ones embedded in the contact payload)
  for an already-completed Monica API crawl.

  Enqueued by `Kith.Workers.MonicaApiCrawlWorker` on successful completion,
  carrying:

    * `"import_id"` — the Import row this job belongs to.
    * `"credential_url"` — the Monica base URL. The API key is read from
      the Import row's `api_key_encrypted`, which stays in place until the
      last follow-up job finishes (see `MonicaApiKeyReleaseWorker`).
      Cancels if the key has already been wiped.
    * `"plan"` — list of `%{"source_id", "local_id", "endpoints"}` maps
      pre-filtered during the main crawl using Monica's `statistics.*`
      fields, so we only fire the endpoints with data.

  Throttled through `Kith.Imports.Sources.MonicaApi.RateLimiter` (same
  per-host bucket as the main crawler).

  Exits early if the import has been cancelled. Contacts that were
  soft-deleted between main-crawl completion and this job's dispatch are
  silently skipped.

  ## Time budget

  A run stops taking new contacts once it has used `@default_budget_ms` (5
  minutes short of the 30-minute job timeout) and enqueues a follow-up job
  carrying the remaining plan and the counts so far (`"carried"`). A big plan
  at a low rate limit therefore finishes across several short jobs instead of
  being killed at the timeout and restarting from the top. Every run completes
  at least one contact, so each one makes progress.

  ## Logging

  Everything is logged under `[MonicaMiscData] import <id>:` — a start line
  (plan size, projected duration), a progress line every
  `@progress_every_entries` contacts or `@progress_every_ms`, warnings for slow
  requests and long rate-limit waits, and a completion line. A job that dies
  without logging (a restart or a kill) is therefore visible as a missing
  completion line, and `Oban.Plugins.Lifeline` re-runs it.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Kith.Activities.{Activity, Call}
  alias Kith.Contacts
  alias Kith.Contacts.{Debt, Gift}
  alias Kith.Conversations.{Conversation, Message}
  alias Kith.Imports
  alias Kith.Imports.Monica.ReminderMapper
  alias Kith.Imports.Sources.MonicaApi.RateLimiter
  alias Kith.Reminders
  alias Kith.Repo
  alias Kith.Tasks.Task

  @timeout_ms :timer.minutes(30)
  @default_budget_ms :timer.minutes(25)
  @progress_every_entries 25
  @progress_every_ms :timer.seconds(30)
  @slow_request_ms :timer.seconds(5)
  @slow_wait_ms :timer.seconds(10)
  @request_timeout_ms :timer.seconds(30)

  @impl Oban.Worker
  def timeout(_job), do: @timeout_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    import_job = Imports.get_import!(args["import_id"])
    Logger.metadata(import_id: import_job.id, worker: "MonicaMiscData")

    cond do
      import_job.status in ["cancelled", "failed"] ->
        :ok

      is_nil(import_job.api_key_encrypted) ->
        Logger.error(
          "[MonicaMiscData] API key already wiped for import #{import_job.id}; cancelling"
        )

        {:cancel, :api_key_wiped}

      true ->
        import_misc_data(import_job, args, job)
    end
  end

  defp import_misc_data(import_job, args, job) do
    credential = build_credential(import_job, args)
    plan = args["plan"] || []
    carried = args["carried"] || %{}

    run = start_run()
    log_start(import_job, job, plan, carried)

    {counts, remaining} = process_plan(plan, credential, import_job, run)
    total_counts = merge_counts(counts, carried)

    summary = Map.put(import_job.summary || %{}, "misc", total_counts)
    Imports.update_import_status(import_job, import_job.status, %{summary: summary})

    if remaining == [] do
      topic = "import:#{import_job.account_id}"
      Phoenix.PubSub.broadcast(Kith.PubSub, topic, {:import_misc_complete, total_counts})

      log(
        import_job,
        "complete in #{fmt_ms(elapsed_ms(run))}: #{request_stats()} | #{fmt_counts(total_counts)}"
      )
    else
      # Raise on a failed insert: the retry re-runs this slice, which is idempotent.
      {:ok, _} =
        args
        |> Map.merge(%{"plan" => remaining, "carried" => total_counts})
        |> new()
        |> Oban.insert()

      log(
        import_job,
        "time budget reached after #{fmt_ms(elapsed_ms(run))}; #{length(remaining)} contacts left, " <>
          "continuing in a follow-up job | #{request_stats()} | #{fmt_counts(total_counts)}"
      )
    end

    :ok
  end

  @doc false
  # Projects how long `plan` takes at `rate_per_minute`. `requests` is an upper
  # bound: merged-away contacts only fetch notes, and notes can need several pages.
  def estimate_plan(plan, rate_per_minute) do
    requests = plan |> Enum.map(&length(&1["endpoints"] || [])) |> Enum.sum()
    %{requests: requests, minutes: requests / rate_per_minute}
  end

  defp budget_ms, do: Application.get_env(:kith, :monica_misc_budget_ms, @default_budget_ms)

  defp merge_counts(counts, carried) do
    Map.merge(carried, counts, fn _key, before, now -> before + now end)
  end

  # ── Logging ───────────────────────────────────────────────────────────

  defp log(import_job, message),
    do: Logger.info("[MonicaMiscData] import #{import_job.id}: #{message}")

  defp log_start(import_job, job, plan, carried) do
    rate = RateLimiter.limit()
    %{requests: requests, minutes: minutes} = estimate_plan(plan, rate)
    estimate_ms = round(minutes * 60_000)

    log(
      import_job,
      "starting (attempt #{job.attempt}/#{job.max_attempts}, job #{job.id}): #{length(plan)} contacts, " <>
        "up to #{requests} requests (~#{fmt_ms(estimate_ms)} at #{rate} req/min), " <>
        "budget #{fmt_ms(budget_ms())} per run, job timeout #{fmt_ms(@timeout_ms)}"
    )

    if job.attempt > 1 do
      Logger.warning(
        "[MonicaMiscData] import #{import_job.id}: retrying after an earlier attempt " <>
          "(attempt #{job.attempt}/#{job.max_attempts}); the previous attempt died or was rescued without finishing"
      )
    end

    if carried != %{} do
      log(import_job, "continuing an earlier run; counts carried so far: #{fmt_counts(carried)}")
    end

    if estimate_ms > budget_ms() do
      Logger.warning(
        "[MonicaMiscData] import #{import_job.id}: estimated #{fmt_ms(estimate_ms)} at #{rate} req/min " <>
          "exceeds the #{fmt_ms(budget_ms())} time budget; the rest continues in follow-up jobs. " <>
          "Raise MONICA_RATE_LIMIT_PER_MINUTE (below Monica's own limit) to finish sooner."
      )
    end
  end

  defp start_run do
    Process.put(:misc_requests, 0)
    Process.put(:misc_throttled_ms, 0)
    now = System.monotonic_time(:millisecond)
    %{started_ms: now, last_logged_ms: now}
  end

  defp elapsed_ms(%{started_ms: started}), do: System.monotonic_time(:millisecond) - started

  defp request_stats do
    "#{Process.get(:misc_requests, 0)} requests, throttled #{fmt_ms(Process.get(:misc_throttled_ms, 0))}"
  end

  defp maybe_log_progress(run, import_job, done, total, counts) do
    now = System.monotonic_time(:millisecond)

    if done == total or rem(done, @progress_every_entries) == 0 or
         now - run.last_logged_ms >= @progress_every_ms do
      elapsed = elapsed_ms(run)
      eta = if done > 0, do: round(elapsed / done * (total - done)), else: 0

      log(
        import_job,
        "progress #{done}/#{total} contacts (#{div(done * 100, max(total, 1))}%) | #{request_stats()} | " <>
          "elapsed #{fmt_ms(elapsed)}, eta ~#{fmt_ms(eta)} | #{fmt_counts(counts)}"
      )

      %{run | last_logged_ms: now}
    else
      run
    end
  end

  defp fmt_counts(counts) do
    case counts |> Enum.reject(fn {_k, v} -> v == 0 end) |> Enum.sort() do
      [] -> "nothing imported yet"
      pairs -> Enum.map_join(pairs, " ", fn {k, v} -> "#{k}=#{v}" end)
    end
  end

  defp fmt_ms(ms) when ms < 1_000, do: "#{ms}ms"

  defp fmt_ms(ms) do
    s = div(ms, 1_000)

    cond do
      s < 60 -> "#{s}s"
      s < 3_600 -> "#{div(s, 60)}m#{rem(s, 60)}s"
      true -> "#{div(s, 3_600)}h#{div(rem(s, 3_600), 60)}m"
    end
  end

  # The key comes from the Import row (Cloak decrypts it on load), never
  # from job args.
  defp build_credential(import_job, args) do
    %{
      url: args["credential_url"],
      api_key: import_job.api_key_encrypted,
      req_options: Application.get_env(:kith, :monica_req_options, [])
    }
  end

  # Returns `{counts, remaining_plan}`; `remaining_plan` is non-empty only when
  # the time budget ran out. The first contact is always processed so a run
  # can't stall on a zero budget.
  defp process_plan(plan, credential, import_job, run) do
    initial = %{
      "pets" => 0,
      "calls" => 0,
      "activities" => 0,
      "gifts" => 0,
      "debts" => 0,
      "tasks" => 0,
      "reminders" => 0,
      "reminders_skipped" => 0,
      "reminders_warnings" => 0,
      "reminders_duplicate" => 0,
      "conversations" => 0,
      "notes" => 0
    }

    user_id = import_job.user_id

    total = length(plan)
    budget = budget_ms()

    plan
    |> Enum.with_index(1)
    |> Enum.reduce_while({initial, run}, fn {entry, n}, {counts, run} ->
      if n > 1 and elapsed_ms(run) >= budget do
        {:halt, {:out_of_budget, counts, Enum.drop(plan, n - 1)}}
      else
        counts = process_entry_logged(entry, n, total, credential, user_id, import_job, counts)
        {:cont, {counts, maybe_log_progress(run, import_job, n, total, counts)}}
      end
    end)
    |> case do
      {:out_of_budget, counts, remaining} -> {counts, remaining}
      {counts, _run} -> {counts, []}
    end
  end

  # Debug line per contact: what it cost, so a slow stretch can be pinned to the
  # contact (and endpoints) responsible.
  defp process_entry_logged(entry, n, total, credential, user_id, import_job, counts) do
    requests_before = Process.get(:misc_requests, 0)

    {entry_ms, counts} =
      timed(fn -> process_entry(entry, credential, user_id, import_job, counts) end)

    Logger.debug(
      "[MonicaMiscData] import #{import_job.id}: contact #{n}/#{total} (monica #{entry["source_id"]}) " <>
        "#{inspect(entry["endpoints"])} took #{fmt_ms(entry_ms)}, " <>
        "#{Process.get(:misc_requests, 0) - requests_before} requests"
    )

    counts
  end

  defp process_entry(entry, credential, user_id, import_job, counts) do
    contact = planned_or_surviving_contact(entry, import_job)

    # With no live contact at all (soft-deleted, or merged away without a
    # surviving record) only notes are attempted, and they resolve their own
    # target through the import record.
    endpoints =
      if live?(contact),
        do: entry["endpoints"] || [],
        else: Enum.filter(entry["endpoints"] || [], &(&1 == "notes"))

    Enum.reduce(endpoints, counts, fn
      "notes", counts ->
        credential
        |> import_contact_notes(user_id, entry, import_job)
        |> add_counts("notes", counts)

      endpoint, counts ->
        endpoint
        |> fire_endpoint(credential, user_id, contact, entry["source_id"], import_job)
        |> add_counts(endpoint, counts)
    end)
  end

  # Auto-merge folds duplicate contacts into a survivor and remaps each merged
  # contact's import record onto it. A planned contact that is no longer live is
  # therefore resolved through that record, so everything Monica holds for the
  # duplicate (reminders, pets, calls, ...) is merged into the survivor instead
  # of being dropped. Each importer skips what the survivor already has.
  defp planned_or_surviving_contact(entry, import_job) do
    planned = Contacts.get_contact_for_misc(entry["local_id"])

    with false <- live?(planned),
         %{local_entity_id: local_id} <-
           Imports.find_import_record(
             import_job.account_id,
             "monica_api",
             "contact",
             entry["source_id"]
           ),
         %{deleted_at: nil, account_id: account_id} = survivor
         when account_id == import_job.account_id <- Contacts.get_contact_for_misc(local_id) do
      survivor
    else
      _ -> planned
    end
  end

  defp live?(nil), do: false
  defp live?(contact), do: is_nil(contact.deleted_at)

  # An endpoint returns its imported count, or a map of count keys when it
  # reports more than that (reminders also count skips and warnings).
  defp add_counts(extra, _endpoint, counts) when is_map(extra) do
    Enum.reduce(extra, counts, fn {key, n}, acc -> Map.update(acc, key, n, &(&1 + n)) end)
  end

  defp add_counts(n, endpoint, counts), do: Map.update(counts, endpoint, n, &(&1 + n))

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
    {wait_ms, :ok} = timed(fn -> RateLimiter.wait!(credential.url) end)

    headers = [
      {"Authorization", "Bearer #{credential.api_key}"},
      {"Accept", "application/json"}
    ]

    # Bounded on purpose: each attempt gets `@request_timeout_ms`, and Req's
    # backoff between the (at most 3) retries adds a few seconds, so one request
    # can't hold the job for more than about two and a half minutes.
    options =
      [
        headers: headers,
        params: params,
        receive_timeout: @request_timeout_ms,
        max_retries: 3,
        retry_log_level: :warning
      ] ++ Map.get(credential, :req_options, [])

    # Logged before the call: if the worker hangs inside Monica, the last "->"
    # line without a matching "<-" is the request it is stuck on.
    Logger.debug(
      "[MonicaMiscData] -> GET #{URI.parse(url).path} (request ##{Process.get(:misc_requests, 0) + 1})"
    )

    {request_ms, result} = timed(fn -> Req.get(url, options) end)
    track_request(url, wait_ms, request_ms, result)

    case result do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # The counters live in the job process's dictionary: a job is one process, and
  # threading them through every per-endpoint helper would touch all of them.
  defp track_request(url, wait_ms, request_ms, result) do
    Process.put(:misc_requests, Process.get(:misc_requests, 0) + 1)
    Process.put(:misc_throttled_ms, Process.get(:misc_throttled_ms, 0) + wait_ms)

    path = URI.parse(url).path

    Logger.debug(
      "[MonicaMiscData] <- #{path} #{outcome(result)} in #{fmt_ms(request_ms)} (waited #{fmt_ms(wait_ms)} for a rate-limit slot)"
    )

    if wait_ms >= @slow_wait_ms do
      Logger.warning(
        "[MonicaMiscData] waited #{fmt_ms(wait_ms)} for a rate-limit slot before GET #{path} " <>
          "(limit #{RateLimiter.limit()} req/min)"
      )
    end

    if request_ms >= @slow_request_ms do
      Logger.warning(
        "[MonicaMiscData] slow Monica request: GET #{path} took #{fmt_ms(request_ms)} (#{outcome(result)})"
      )
    end
  end

  defp outcome({:ok, %{status: status}}), do: "HTTP #{status}"
  defp outcome({:error, reason}), do: "error: #{inspect(reason)}"

  # ── Extra notes ──────────────────────────────────────────────────────

  @notes_page_limit 100

  defp import_contact_notes(credential, user_id, entry, import_job) do
    with %{local_entity_id: local_id} <-
           Imports.find_import_record(
             import_job.account_id,
             "monica_api",
             "contact",
             entry["source_id"]
           ),
         %{deleted_at: nil} = contact <- Contacts.get_contact_for_misc(local_id) do
      fetch_notes_pages(credential, contact, user_id, entry, import_job, 1)
    else
      _ -> 0
    end
  end

  defp fetch_notes_pages(credential, contact, user_id, entry, import_job, page) do
    source_id = entry["source_id"]
    url = "#{credential.url}/api/contacts/#{source_id}/notes"

    case api_get_json(credential, url, limit: @notes_page_limit, page: page) do
      {:ok, %{"data" => notes, "meta" => meta}} when is_list(notes) ->
        # No positional skip: the notes embedded in the contact payload are the
        # newest three, while this endpoint lists oldest first, so dropping the
        # first N dropped the wrong notes. Already-imported ones are recognised
        # by uuid (or content) in import_notes_batch/4 instead.
        imported = import_notes_batch(contact, user_id, notes, import_job)

        if page < (meta["last_page"] || 1),
          do:
            imported +
              fetch_notes_pages(credential, contact, user_id, entry, import_job, page + 1),
          else: imported

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch notes for contact #{source_id}: #{inspect(reason)}"
        )

        0
    end
  end

  # A note is skipped when its uuid is already mapped (the crawl's embedded notes,
  # an earlier attempt, or a merged duplicate's copy) or when the contact already
  # has the same text. The uuid check is what covers blank bodies, which can't be
  # matched by content. Together they keep a retry from duplicating notes.
  defp import_notes_batch(contact, user_id, notes, import_job) do
    Enum.count(notes, fn note ->
      not note_already_imported?(import_job, note) and
        not note_duplicate?(contact.id, note["body"]) and
        match?({:ok, _}, create_imported_note(contact, user_id, note, import_job))
    end)
  end

  defp note_already_imported?(_import_job, %{"uuid" => nil}), do: false

  defp note_already_imported?(import_job, %{"uuid" => uuid}) do
    not is_nil(Imports.find_import_record(import_job.account_id, import_job.source, "note", uuid))
  end

  defp note_already_imported?(_import_job, _note), do: false

  defp create_imported_note(contact, user_id, note, import_job) do
    case Contacts.create_note(contact, user_id, %{"body" => note["body"]}) do
      {:ok, n} = ok ->
        maybe_record_entity(import_job, "note", note["uuid"], "note", n.id)
        ok

      {:error, reason} = error ->
        Logger.warning(
          "[MonicaMiscData] note for contact #{contact.id}: #{inspect_errors(reason)}"
        )

        error
    end
  end

  defp note_duplicate?(_contact_id, body) when body in [nil, ""], do: false

  defp note_duplicate?(contact_id, body) when is_binary(body) do
    trimmed = String.trim(body)

    Repo.exists?(
      from(n in Contacts.Note,
        where: n.contact_id == ^contact_id and fragment("trim(?)", n.body) == ^trimmed
      )
    )
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

  # An Oban retry of this import must not recreate what an earlier attempt mapped.
  defp import_single_call(account_id, contact, call_data, import_job) do
    cond do
      mapped_entity(import_job, "call", call_data["id"], Call) -> :ok
      call_duplicate?(contact.id, call_data) -> {:error, :duplicate}
      true -> create_imported_call(account_id, contact, call_data, import_job)
    end
  end

  defp create_imported_call(account_id, contact, call_data, import_job) do
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

  # An Oban retry of this import must not recreate what an earlier attempt mapped.
  defp import_single_activity(account_id, contact, activity_data, import_job) do
    cond do
      mapped_entity(import_job, "activity", activity_data["id"], Activity) -> :ok
      activity_duplicate?(contact.id, activity_data) -> {:error, :duplicate}
      true -> create_imported_activity(account_id, contact, activity_data, import_job)
    end
  end

  defp create_imported_activity(account_id, contact, activity_data, import_job) do
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

  # An Oban retry of this import must not recreate what an earlier attempt mapped.
  defp import_single_gift(account_id, user_id, contact, gift_data, import_job) do
    cond do
      mapped_entity(import_job, "gift", gift_data["id"], Gift) -> :ok
      gift_duplicate?(contact.id, gift_data) -> {:error, :duplicate}
      true -> create_imported_gift(account_id, user_id, contact, gift_data, import_job)
    end
  end

  defp create_imported_gift(account_id, user_id, contact, gift_data, import_job) do
    direction = gift_direction(gift_data)

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

  # An Oban retry of this import must not recreate what an earlier attempt mapped.
  defp import_single_debt(account_id, user_id, contact, debt_data, import_job) do
    cond do
      mapped_entity(import_job, "debt", debt_data["id"], Debt) -> :ok
      debt_duplicate?(contact.id, debt_data) -> {:error, :duplicate}
      true -> create_imported_debt(account_id, user_id, contact, debt_data, import_job)
    end
  end

  defp create_imported_debt(account_id, user_id, contact, debt_data, import_job) do
    direction = debt_direction(debt_data)

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

  # An Oban retry of this import must not recreate what an earlier attempt mapped.
  defp import_single_task(account_id, user_id, contact, task_data, import_job) do
    cond do
      mapped_entity(import_job, "task", task_data["id"], Task) -> :ok
      task_duplicate?(contact.id, task_data) -> {:error, :duplicate}
      true -> create_imported_task(account_id, user_id, contact, task_data, import_job)
    end
  end

  defp create_imported_task(account_id, user_id, contact, task_data, import_job) do
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
        today = Reminders.account_today(contact.account_id)

        # `contact` is threaded through: importing a first-met reminder updates
        # the contact, and later reminders must see that update.
        {counts, _contact} =
          Enum.reduce(reminders, {no_reminder_counts(), contact}, fn reminder, {acc, contact} ->
            {outcome, contact} =
              import_single_reminder(user_id, contact, reminder, import_job, today)

            {tally_reminder(acc, outcome), contact}
          end)

        counts

      {:ok, _} ->
        no_reminder_counts()

      {:error, reason} ->
        Logger.warning(
          "[MonicaMiscData] failed to fetch reminders for contact #{source_id}: #{inspect(reason)}"
        )

        no_reminder_counts()
    end
  end

  defp no_reminder_counts,
    do: %{
      "reminders" => 0,
      "reminders_skipped" => 0,
      "reminders_warnings" => 0,
      "reminders_duplicate" => 0
    }

  defp tally_reminder(acc, {:ok, warnings}) do
    %{
      acc
      | "reminders" => acc["reminders"] + 1,
        "reminders_warnings" => acc["reminders_warnings"] + warnings
    }
  end

  defp tally_reminder(acc, :skipped),
    do: %{acc | "reminders_skipped" => acc["reminders_skipped"] + 1}

  defp tally_reminder(acc, :duplicate),
    do: %{acc | "reminders_duplicate" => acc["reminders_duplicate"] + 1}

  defp tally_reminder(acc, {:error, _}), do: acc

  # Carries out `ReminderMapper`'s decision (design spec 2026-10-14 §4).
  # Returns `{outcome, contact}`; the contact may have been updated.
  defp import_single_reminder(user_id, contact, data, import_job, today) do
    case ReminderMapper.map(data, contact, today) do
      :birthday ->
        outcome =
          contact
          |> import_derived(data, import_job, fn -> Reminders.sync_birthday(contact) end)
          |> with_warnings(0)

        {outcome, contact}

      :first_met ->
        import_first_met(contact, data, import_job)

      {:create, attrs, notes} ->
        Enum.each(notes, fn note ->
          Logger.warning("[MonicaMiscData] reminder #{data["id"]}: #{note}; imported as one-time")
        end)

        outcome =
          user_id
          |> upsert_reminder(contact, data, attrs, import_job)
          |> with_warnings(length(notes))

        {outcome, contact}

      {:skip, reason} ->
        Logger.warning("[MonicaMiscData] reminder #{data["id"]} skipped: #{reason}")
        {:skipped, contact}
    end
  end

  defp with_warnings(:ok, warnings), do: {:ok, warnings}
  defp with_warnings(other, _warnings), do: other

  defp import_first_met(contact, data, import_job) do
    case Contacts.update_contact(contact, %{first_met_reminder: true}) do
      {:ok, updated} ->
        outcome =
          updated
          |> import_derived(data, import_job, fn -> Reminders.sync_first_met(updated) end)
          |> with_warnings(0)

        {outcome, updated}

      {:error, reason} ->
        {log_reminder_error(reason), contact}
    end
  end

  # A derived reminder (birthday / first_met) is owned by the contact, not the
  # import; the import only records the mapping.
  defp import_derived(contact, data, import_job, sync) do
    case sync.() do
      {:ok, %Reminders.Reminder{} = reminder} ->
        maybe_record_entity(import_job, "reminder", data["id"], "reminder", reminder.id)
        :ok

      {:ok, :none} ->
        log_reminder_error({:no_derived_reminder, contact.id})

      {:error, reason} ->
        log_reminder_error(reason)
    end
  end

  # Upsert by mapping so an Oban retry of the same contact's misc job updates
  # the reminder it already made instead of duplicating it. Cross-import
  # re-imports never get here: contacts from earlier imports are skipped.
  defp upsert_reminder(user_id, contact, data, attrs, import_job) do
    new_type = attrs["type"]

    result =
      case mapped_local_reminder(import_job, data["id"]) do
        %Reminders.Reminder{type: ^new_type} = mapped ->
          Reminders.update_reminder(mapped, Map.delete(attrs, "type"))

        _missing_or_other ->
          case find_duplicate_reminder(contact, attrs) do
            nil -> create(user_id, contact, attrs)
            existing -> {:duplicate, existing}
          end
      end

    case result do
      {:ok, reminder} ->
        maybe_record_entity(import_job, "reminder", data["id"], "reminder", reminder.id)
        :ok

      # The survivor of an auto-merge already has this reminder (its own, or one
      # imported from another merged duplicate). Map to it so a retry is stable.
      {:duplicate, existing} ->
        maybe_record_entity(import_job, "reminder", data["id"], "reminder", existing.id)
        :duplicate

      {:error, reason} ->
        log_reminder_error(reason)
    end
  end

  # Same contact, type, anchor date, interval and (case/space-insensitive) title.
  defp find_duplicate_reminder(contact, attrs) do
    title = attrs["title"] |> to_string() |> String.trim() |> String.downcase()

    Repo.one(
      from(r in Reminders.Reminder,
        where:
          r.contact_id == ^contact.id and r.type == ^attrs["type"] and
            r.anchor_date == ^attrs["anchor_date"] and
            fragment("lower(trim(coalesce(?, '')))", r.title) == ^title and
            fragment(
              "? IS NOT DISTINCT FROM ?",
              r.interval_unit,
              type(^attrs["interval_unit"], :string)
            ) and
            fragment(
              "? IS NOT DISTINCT FROM ?",
              r.interval_count,
              type(^attrs["interval_count"], :integer)
            ),
        order_by: [asc: r.id],
        limit: 1
      )
    )
  end

  defp create(user_id, contact, attrs),
    do:
      Reminders.create_reminder(
        contact.account_id,
        user_id,
        Map.put(attrs, "contact_id", contact.id)
      )

  defp mapped_local_reminder(nil, _source_id), do: nil
  defp mapped_local_reminder(_import_job, nil), do: nil

  defp mapped_local_reminder(import_job, source_id) do
    case Imports.find_import_record(
           import_job.account_id,
           import_job.source,
           "reminder",
           to_string(source_id)
         ) do
      %{local_entity_id: id} when is_integer(id) ->
        Reminders.get_reminder(import_job.account_id, id)

      _ ->
        nil
    end
  end

  defp log_reminder_error(reason) do
    Logger.warning("[MonicaMiscData] reminder error: #{inspect_errors(reason)}")
    {:error, reason}
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

    # Upsert by mapping so an Oban retry of this job reuses the conversation
    # (and skips the messages) it already imported.
    result =
      case mapped_entity(import_job, "conversation", convo_data["id"], Conversation) do
        %Conversation{} = existing -> {:ok, existing}
        nil -> reuse_or_create_conversation(account_id, user_id, contact, attrs)
      end

    case result do
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
      if is_nil(mapped_entity(import_job, "message", msg["id"], Message)) and
           not message_duplicate?(conversation.id, msg) do
        add_conversation_message(conversation, msg, import_job)
      end
    end)
  end

  defp add_conversation_message(conversation, msg, import_job) do
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
  end

  # The local row an earlier attempt of this import mapped `source_id` to, if it
  # still exists.
  defp mapped_entity(nil, _type, _source_id, _schema), do: nil
  defp mapped_entity(_import_job, _type, nil, _schema), do: nil

  defp mapped_entity(import_job, type, source_id, schema) do
    case Imports.find_import_record(
           import_job.account_id,
           import_job.source,
           type,
           to_string(source_id)
         ) do
      %{local_entity_id: id} when is_integer(id) ->
        Repo.get_by(schema, id: id, account_id: import_job.account_id)

      _ ->
        nil
    end
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

  # ── Content duplicates ───────────────────────────────────────────────
  #
  # After an auto-merge the survivor may already hold what a merged duplicate
  # carries (its own copy, or one imported from another duplicate). These match
  # on content, ignoring case and surrounding space in text, so the merge adds
  # only what is new.

  defp gift_direction(gift_data),
    do: if(gift_data["is_for"] == "contact", do: "given", else: "received")

  defp debt_direction(debt_data),
    do: if(debt_data["in_debt"] == "yes", do: "owed_by_me", else: "owed_to_me")

  defp norm(text), do: (text || "") |> to_string() |> String.trim() |> String.downcase()

  defp call_duplicate?(contact_id, call_data) do
    occurred_at = parse_datetime(call_data["called_at"])
    notes = non_empty_string(call_data["content"])

    not is_nil(occurred_at) and
      Repo.exists?(
        from(c in Kith.Activities.Call,
          where:
            c.contact_id == ^contact_id and c.occurred_at == ^occurred_at and
              fragment("? IS NOT DISTINCT FROM ?", c.notes, type(^notes, :string))
        )
      )
  end

  defp activity_duplicate?(contact_id, activity_data) do
    title = activity_data["summary"] || activity_data["title"] || "Imported activity"

    occurred_at =
      parse_datetime(activity_data["happened_at"] || activity_data["date_it_happened"])

    # Without a date the importer stamps "now", so there is nothing stable to match.
    not is_nil(occurred_at) and
      Repo.exists?(
        from(a in Activity,
          join: ac in "activity_contacts",
          on: ac.activity_id == a.id,
          where:
            ac.contact_id == ^contact_id and a.title == ^title and a.occurred_at == ^occurred_at
        )
      )
  end

  defp gift_duplicate?(contact_id, gift_data) do
    name = norm(gift_data["name"] || "Imported gift")
    direction = gift_direction(gift_data)
    date = parse_date_string(gift_data["date"])

    Repo.exists?(
      from(g in Gift,
        where:
          g.contact_id == ^contact_id and fragment("lower(trim(?))", g.name) == ^name and
            g.direction == ^direction and
            fragment("? IS NOT DISTINCT FROM ?", g.date, type(^date, :date))
      )
    )
  end

  defp debt_duplicate?(contact_id, debt_data) do
    title = norm(debt_data["reason"] || "Imported debt")
    direction = debt_direction(debt_data)

    case Decimal.parse(to_string(debt_data["amount"] || "0")) do
      {amount, ""} ->
        Repo.exists?(
          from(d in Debt,
            where:
              d.contact_id == ^contact_id and fragment("lower(trim(?))", d.title) == ^title and
                d.direction == ^direction and d.amount == ^amount
          )
        )

      _ ->
        false
    end
  end

  # A merged duplicate's conversation joins the survivor's matching one (same
  # platform and subject) rather than making a twin; its messages are then
  # added only where the same message isn't already there.
  defp reuse_or_create_conversation(account_id, user_id, contact, attrs) do
    subject = attrs["subject"]

    existing =
      Repo.one(
        from(c in Conversation,
          where:
            c.contact_id == ^contact.id and c.platform == ^attrs["platform"] and
              fragment("? IS NOT DISTINCT FROM ?", c.subject, type(^subject, :string)),
          order_by: [asc: c.id],
          limit: 1
        )
      )

    case existing do
      nil -> Kith.Conversations.create_conversation(account_id, user_id, attrs)
      conversation -> {:ok, conversation}
    end
  end

  defp message_duplicate?(conversation_id, msg) do
    body = norm(msg["content"] || msg["written_by_me_body"] || "")
    sent_at = parse_datetime(msg["written_at"])

    not is_nil(sent_at) and
      Repo.exists?(
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and m.sent_at == ^sent_at and
              fragment("lower(trim(?))", m.body) == ^body
        )
      )
  end

  defp task_duplicate?(contact_id, task_data) do
    title = norm(task_data["title"] || "Imported task")
    status = if task_data["completed"], do: "completed", else: "pending"

    Repo.exists?(
      from(t in Task,
        where:
          t.contact_id == ^contact_id and fragment("lower(trim(?))", t.title) == ^title and
            t.status == ^status
      )
    )
  end

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

  # Monica also sends "2024-06-01 00:00:00" (space separator, no offset) —
  # not valid ISO 8601 for Date/DateTime, but a valid NaiveDateTime.
  defp parse_date_string(str) when is_binary(str) do
    parse_iso_date(str) || parse_iso_datetime(str) || parse_naive_datetime(str)
  end

  defp parse_date_string(_), do: nil

  defp parse_iso_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp parse_naive_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> NaiveDateTime.to_date(ndt)
      _ -> nil
    end
  end

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
