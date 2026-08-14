defmodule Kith.Imports.Sources.MonicaApi do
  @moduledoc """
  Monica CRM API-crawl import source.

  Imports contacts directly from a Monica instance via its REST API,
  eliminating the need for a JSON file export. Crawls the paginated
  contacts list endpoint and imports all embedded data in a single pass,
  then resolves cross-references (first_met_through, relationships) in
  a second pass once all contacts exist locally.

  ## Phases

    1. **Contact crawl** — paginate through `GET /api/contacts?limit=100&with=contactfields`,
       creating contacts with addresses, tags, contact fields, and up to 3 notes each.
    2. **Cross-references** — resolve `first_met_through_contact` and relationships
       using import_records (no API calls needed).
    3. **Extra notes** — for contacts with `statistics.number_of_notes > 3`,
       fetch remaining notes via `GET /api/contacts/{id}/notes`.

  Per-contact "misc" data (pets, calls, activities, gifts, debts, tasks,
  reminders, conversations) is planned during Phase 1 — for each contact,
  endpoints with `statistics.number_of_X > 0` are recorded in
  `summary.misc_data_plan` — and dispatched separately by
  `Kith.Workers.MonicaMiscDataWorker`. Photo import and document import
  follow the same separate-worker pattern (`MonicaPhotoSyncWorker`,
  `MonicaDocumentImportWorker`).
  """

  @behaviour Kith.Imports.Source

  import Ecto.Query, warn: false

  alias Kith.Contacts
  alias Kith.Contacts.PhoneFormatter
  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi.RateLimiter
  alias Kith.Repo
  alias Kith.Workers.MonicaDocumentImportWorker

  require Logger

  @page_limit 100

  # ── Behaviour callbacks ───────────────────────────────────────────────

  @impl true
  def name, do: "Monica CRM (API)"

  @impl true
  def file_types, do: []

  @impl true
  def supports_api?, do: true

  @impl true
  def validate_file(_data), do: {:error, "API import does not use files"}

  @impl true
  def parse_summary(_data), do: {:error, "API import does not use files"}

  @impl true
  def import(_account_id, _user_id, _data, _opts),
    do: {:error, "Use MonicaApiCrawlWorker for API imports"}

  @impl true
  def test_connection(%{url: url} = credential) do
    case api_get(credential, "#{url}/api/me") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  # ── Main crawl entry point ───────────────────────────────────────────

  @doc """
  Crawls a Monica instance via API and imports all contacts.

  Called by `MonicaApiCrawlWorker.perform/1`. Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def crawl(account_id, user_id, credential, import_job, opts \\ %{}) do
    ctx = %{
      account_id: account_id,
      user_id: user_id,
      credential: credential,
      import_job: import_job,
      opts: opts,
      topic: "import:#{account_id}"
    }

    # Phase 1: Crawl contacts
    {acc, deferred, ref_data} = crawl_all_contacts(ctx)

    # Phase 1.4: Coverage check + backfill any silently-dropped contacts.
    # See docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md
    {acc, _ref_data, coverage_stats} = coverage_check_and_backfill(ctx, acc, ref_data)

    # Phase 1.5: Auto-merge definite duplicates (optional).
    # Runs AFTER Phase 1.4 so backfilled contacts participate in auto-merge.
    merge_result =
      if opts["auto_merge_duplicates"] do
        auto_merge_duplicates(account_id, import_job)
      else
        %{merged: 0, errors: []}
      end

    # Phase 2: Resolve cross-references
    ref_errors = resolve_cross_references(account_id, deferred, import_job)

    # Phase 3: Extra notes
    notes_errors =
      if opts["extra_notes"] != false do
        fetch_all_extra_notes(credential, account_id, user_id, deferred.extra_notes, import_job)
      else
        []
      end

    # Phase 4: Per-contact "misc" data (pets, calls, activities, gifts, debts,
    # tasks, reminders, conversations) is now planned during the main crawl
    # and dispatched as a separate `MonicaMiscDataWorker` Oban job by
    # `MonicaApiCrawlWorker`. The plan is carried in `summary.misc_data_plan`.

    # Phase 5: Enqueue document import jobs (async, runs after main import)
    if opts["documents"] do
      enqueue_document_imports(credential, account_id, user_id, import_job)
    end

    all_errors =
      acc.errors ++
        ref_errors ++
        notes_errors ++
        merge_result.errors

    error_count =
      acc.error_count + length(ref_errors) + length(notes_errors) +
        length(merge_result.errors)

    {:ok,
     %{
       imported: acc.contacts,
       contacts: acc.contacts,
       notes: acc.notes,
       skipped: acc.skipped,
       merged: merge_result.merged,
       error_count: error_count,
       errors: Enum.take(all_errors, 50),
       misc_data_plan: Enum.reverse(deferred.misc_data),
       coverage_backfill: coverage_stats
     }}
  catch
    :cancelled ->
      {:ok,
       %{
         imported: 0,
         contacts: 0,
         notes: 0,
         skipped: 0,
         merged: 0,
         error_count: 1,
         errors: ["Import cancelled"],
         coverage_backfill: empty_backfill_stats()
       }}
  end

  # ── Phase 1: Paginated contact crawl ──────────────────────────────────

  defp crawl_all_contacts(ctx) do
    initial_state = %{
      page: 1,
      total: nil,
      acc: %{contacts: 0, notes: 0, skipped: 0, error_count: 0, errors: []},
      deferred: %{
        first_met_through: [],
        relationships: [],
        extra_notes: [],
        misc_data: []
      },
      ref_data: nil,
      global_idx: 0
    }

    crawl_contacts_loop(ctx, initial_state)
  end

  defp crawl_contacts_loop(ctx, state) do
    case fetch_contacts_page(ctx.credential, state.page) do
      {:ok, %{"data" => contacts, "meta" => meta}} when is_list(contacts) ->
        handle_contacts_page(ctx, state, contacts, meta)

      {:ok, %{"data" => [], "meta" => _}} ->
        {state.acc, state.deferred, state.ref_data}

      {:ok, unexpected} ->
        Logger.error("[MonicaApi] Unexpected contacts response: #{inspect(unexpected)}")
        acc = add_error(state.acc, "Unexpected API response format from contacts endpoint")
        {acc, state.deferred, state.ref_data}

      {:error, :rate_limited} ->
        acc = add_error(state.acc, "Rate limited by Monica API after retries")
        {acc, state.deferred, state.ref_data}

      {:error, reason} ->
        acc =
          add_error(state.acc, "Failed to fetch contacts page #{state.page}: #{inspect(reason)}")

        {acc, state.deferred, state.ref_data}
    end
  end

  defp handle_contacts_page(ctx, state, contacts, meta) do
    total = state.total || meta["total"] || 0
    last_page = meta["last_page"] || 1

    ref_data = build_or_update_ref_data(ctx.account_id, contacts, state.ref_data)

    {acc, deferred, global_idx} =
      process_contact_page(
        ctx,
        contacts,
        ref_data,
        total,
        state.acc,
        state.deferred,
        state.global_idx
      )

    if state.page < last_page do
      next_state = %{
        state
        | page: state.page + 1,
          total: total,
          acc: acc,
          deferred: deferred,
          ref_data: ref_data,
          global_idx: global_idx
      }

      crawl_contacts_loop(ctx, next_state)
    else
      {acc, deferred, ref_data}
    end
  end

  defp fetch_contacts_page(credential, page) do
    url = "#{credential.url}/api/contacts"
    params = [limit: @page_limit, page: page, with: "contactfields"]
    api_get_json(credential, url, params)
  end

  defp process_contact_page(ctx, contacts, ref_data, total, acc, deferred, global_idx) do
    broadcast_interval = max(1, div(total, 50))

    Enum.reduce(contacts, {acc, deferred, global_idx}, fn api_contact,
                                                          {acc_inner, def_inner, idx} ->
      idx = idx + 1
      maybe_check_import_cancelled(ctx.import_job, idx)

      {acc_inner, def_inner} =
        safe_import_api_contact(ctx, api_contact, ref_data, acc_inner, def_inner)

      maybe_broadcast_progress(ctx.topic, idx, total, broadcast_interval)
      {acc_inner, def_inner, idx}
    end)
  end

  defp safe_import_api_contact(ctx, api_contact, ref_data, acc, deferred) do
    import_api_contact(ctx, api_contact, ref_data, acc, deferred)
  rescue
    e ->
      name = api_contact_display_name(api_contact)
      msg = "Contact #{name}: #{Exception.message(e)}"
      Logger.error("[MonicaApi] #{msg}")
      {add_error(acc, msg), deferred}
  end

  # ── Phase 1.4: Coverage check + backfill ──────────────────────────────
  #
  # Monica's /api/contacts listing endpoint silently drops a subset of
  # contacts under LIMIT/OFFSET pagination over its default sort (this is
  # a v4 server-side issue we can't fix). We compensate by re-fetching
  # meta.total and any IDs in [min_seen, max_seen + safety_margin] that
  # weren't returned by the listing.
  #
  # See docs/superpowers/specs/2026-05-17-monica-import-coverage-backfill-design.md
  # for full design context.

  @safety_margin 50
  @max_iterations_buffer 100

  defp coverage_check_and_backfill(ctx, acc, ref_data) do
    case fetch_meta_total(ctx.credential) do
      {:ok, monica_total} ->
        do_backfill(ctx, acc, ref_data, monica_total)

      {:error, _reason} ->
        # Can't determine gap; pass through with zeroed coverage stats.
        {acc, ref_data, empty_backfill_stats()}
    end
  end

  defp fetch_meta_total(credential) do
    url = "#{credential.url}/api/contacts"

    case api_get_json(credential, url, limit: 1, page: 1) do
      {:ok, %{"meta" => %{"total" => total}}} when is_integer(total) -> {:ok, total}
      _ -> {:error, :unknown_total}
    end
  end

  defp do_backfill(ctx, acc, ref_data, monica_total) do
    seen_ids = seen_source_ids(ctx.import_job.id)

    if Enum.empty?(seen_ids) do
      # Nothing imported by listing; refuse to scan an unbounded range.
      {acc, ref_data, empty_backfill_stats(gap: monica_total)}
    else
      min_id = Enum.min(seen_ids)
      max_id = Enum.max(seen_ids)
      gap = monica_total - MapSet.size(seen_ids)

      stats = %{
        gap_detected: gap,
        range_scanned: 0,
        imported_full: 0,
        imported_partial: 0,
        skipped_deleted: 0,
        skipped_inactive: 0,
        errors: 0,
        unresolved_gap: 0
      }

      if gap <= 0 do
        {acc, ref_data, %{stats | unresolved_gap: 0}}
      else
        scan_gap_range(ctx, acc, ref_data, seen_ids, min_id, max_id, monica_total, stats)
      end
    end
  end

  defp seen_source_ids(import_id) do
    from(ir in Imports.ImportRecord,
      where:
        ir.import_id == ^import_id and
          ir.source_entity_type == "contact",
      select: ir.source_entity_id
    )
    |> Repo.all()
    |> Enum.flat_map(fn s ->
      case Integer.parse(s) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp scan_gap_range(ctx, acc, ref_data, seen_ids, min_id, max_id, monica_total, stats) do
    scan_start = min_id
    scan_end = max_id + @safety_margin
    max_iterations = max_id - min_id + @max_iterations_buffer

    Logger.info(
      "[MonicaApi] Coverage backfill scanning [#{scan_start}..#{scan_end}] " <>
        "(seen=#{MapSet.size(seen_ids)}, monica_total=#{monica_total}, gap=#{stats.gap_detected})"
    )

    candidates =
      scan_start..scan_end
      |> Enum.reject(&MapSet.member?(seen_ids, &1))
      |> Enum.take(max_iterations)

    initial = {acc, ref_data, stats, seen_ids}

    {final_acc, final_ref_data, final_stats, final_seen} =
      Enum.reduce_while(candidates, initial, fn id, state ->
        step_backfill(ctx, id, state, monica_total)
      end)

    unresolved = max(0, monica_total - MapSet.size(final_seen))

    if unresolved > 0 do
      Logger.warning(
        "[MonicaApi] Coverage backfill could not close the gap: " <>
          "monica_total=#{monica_total}, seen=#{MapSet.size(final_seen)}, unresolved=#{unresolved}"
      )
    end

    {final_acc, final_ref_data, %{final_stats | unresolved_gap: unresolved}}
  end

  defp step_backfill(ctx, id, {acc, ref_data, stats, seen} = state, monica_total) do
    if MapSet.size(seen) >= monica_total do
      {:halt, state}
    else
      case fetch_and_dispatch_backfill(ctx, id, acc, ref_data) do
        {:imported_full, new_acc, new_ref_data} ->
          {:cont,
           {new_acc, new_ref_data,
            %{
              stats
              | range_scanned: stats.range_scanned + 1,
                imported_full: stats.imported_full + 1
            }, MapSet.put(seen, id)}}

        {:imported_partial, new_acc, new_ref_data} ->
          {:cont,
           {new_acc, new_ref_data,
            %{
              stats
              | range_scanned: stats.range_scanned + 1,
                imported_partial: stats.imported_partial + 1
            }, MapSet.put(seen, id)}}

        :skipped_deleted ->
          {:cont,
           {acc, ref_data,
            %{
              stats
              | range_scanned: stats.range_scanned + 1,
                skipped_deleted: stats.skipped_deleted + 1
            }, seen}}

        :skipped_inactive ->
          {:cont,
           {acc, ref_data,
            %{
              stats
              | range_scanned: stats.range_scanned + 1,
                skipped_inactive: stats.skipped_inactive + 1
            }, seen}}

        {:error, _reason} ->
          {:cont,
           {acc, ref_data,
            %{stats | range_scanned: stats.range_scanned + 1, errors: stats.errors + 1}, seen}}
      end
    end
  end

  defp fetch_and_dispatch_backfill(ctx, monica_id, acc, ref_data) do
    case fetch_single_contact(ctx.credential, monica_id) do
      :not_found -> :skipped_deleted
      {:error, reason} -> {:error, reason}
      {:ok, api_contact} -> dispatch_accepted_contact(ctx, api_contact, acc, ref_data)
    end
  end

  defp dispatch_accepted_contact(ctx, api_contact, acc, ref_data) do
    case accept_backfill_response(api_contact) do
      :skip_inactive ->
        :skipped_inactive

      verdict when verdict in [:import_full, :import_partial] ->
        new_ref_data = build_or_update_ref_data(ctx.account_id, [api_contact], ref_data)

        {new_acc, _new_deferred} =
          safe_import_api_contact(ctx, api_contact, new_ref_data, acc, %{
            first_met_through: [],
            relationships: [],
            extra_notes: [],
            misc_data: []
          })

        case verdict do
          :import_full -> {:imported_full, new_acc, new_ref_data}
          :import_partial -> {:imported_partial, new_acc, new_ref_data}
        end
    end
  end

  defp empty_backfill_stats(opts \\ []) do
    %{
      gap_detected: Keyword.get(opts, :gap, 0),
      range_scanned: 0,
      imported_full: 0,
      imported_partial: 0,
      skipped_deleted: 0,
      skipped_inactive: 0,
      errors: 0,
      unresolved_gap: Keyword.get(opts, :gap, 0)
    }
  end

  defp import_api_contact(ctx, api_contact, ref_data, acc, deferred) do
    source_id = to_string(api_contact["id"])

    # Check for existing import record (re-import)
    existing = Imports.find_import_record(ctx.account_id, "monica_api", "contact", source_id)

    case existing do
      %{local_entity_id: local_id} ->
        handle_existing_contact(ctx, api_contact, source_id, ref_data, acc, deferred, local_id)

      nil ->
        do_create_api_contact(ctx, api_contact, source_id, ref_data, acc, deferred)
    end
  end

  defp handle_existing_contact(ctx, api_contact, source_id, ref_data, acc, deferred, local_id) do
    case Repo.get(Contacts.Contact, local_id) do
      nil ->
        do_create_api_contact(ctx, api_contact, source_id, ref_data, acc, deferred)

      %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        Logger.info("[MonicaApi] Skipping #{api_contact_display_name(api_contact)}: soft-deleted")

        {%{acc | skipped: acc.skipped + 1}, deferred}

      contact ->
        do_update_api_contact(ctx, contact, api_contact, source_id, ref_data, acc, deferred)
    end
  end

  defp do_create_api_contact(ctx, api_contact, source_id, ref_data, acc, deferred) do
    attrs = build_contact_attrs_from_api(api_contact, ref_data)

    case Contacts.create_contact(ctx.account_id, attrs) do
      {:ok, contact} ->
        Imports.record_imported_entity(
          ctx.import_job,
          "contact",
          source_id,
          "contact",
          contact.id
        )

        import_api_contact_children(ctx, contact, api_contact, source_id, ref_data, acc, deferred)

      {:error, changeset} ->
        name = api_contact_display_name(api_contact)
        msg = "Contact #{name}: #{inspect_errors(changeset)}"
        Logger.warning("[MonicaApi] #{msg}")
        {add_error(acc, msg), deferred}
    end
  end

  defp do_update_api_contact(ctx, contact, api_contact, source_id, ref_data, acc, deferred) do
    attrs = build_contact_attrs_from_api(api_contact, ref_data)

    case Contacts.update_contact(contact, attrs) do
      {:ok, contact} ->
        Imports.record_imported_entity(
          ctx.import_job,
          "contact",
          source_id,
          "contact",
          contact.id
        )

        import_api_contact_children(ctx, contact, api_contact, source_id, ref_data, acc, deferred)

      {:error, changeset} ->
        name = api_contact_display_name(api_contact)
        msg = "Contact #{name} (update): #{inspect_errors(changeset)}"
        Logger.warning("[MonicaApi] #{msg}")
        {add_error(acc, msg), deferred}
    end
  end

  # ── Contact attr mapping (API → Kith) ──────────────────────────────

  defp build_contact_attrs_from_api(api_contact, ref_data) do
    gender_name = api_contact["gender"]
    gender_id = if gender_name, do: Map.get(ref_data.genders, gender_name)

    info = api_contact["information"] || %{}
    career = info["career"] || %{}
    dates = info["dates"] || %{}
    how_you_met = info["how_you_met"] || %{}

    birthdate_info = parse_special_date(dates["birthdate"])
    first_met_date_info = parse_special_date(how_you_met["first_met_date"])

    is_active = api_contact["is_active"]
    is_archived = if is_active == false, do: true, else: false

    base = %{
      first_name: api_contact["first_name"],
      last_name: api_contact["last_name"],
      nickname: api_contact["nickname"],
      description: api_contact["description"],
      company: career["company"],
      occupation: career["job"],
      favorite: api_contact["is_starred"] || false,
      is_archived: is_archived,
      deceased: api_contact["is_dead"] || false,
      gender_id: gender_id
    }

    base
    |> maybe_put(:birthdate, birthdate_info[:date])
    |> maybe_put(:birthdate_year_unknown, birthdate_info[:year_unknown])
    |> maybe_put(:first_met_at, first_met_date_info[:date])
    |> maybe_put(:first_met_year_unknown, first_met_date_info[:year_unknown])
    |> maybe_put(:first_met_where, non_empty_string(how_you_met["first_met_where"]))
    |> maybe_put(:first_met_additional_info, non_empty_string(how_you_met["general_information"]))
  end

  # ── Contact children import ─────────────────────────────────────────

  defp import_api_contact_children(ctx, contact, api_contact, source_id, ref_data, acc, deferred) do
    # Contact fields (embedded with ?with=contactfields)
    import_api_contact_fields(contact, api_contact, ref_data, ctx)

    # Addresses (embedded directly)
    import_api_addresses(contact, api_contact, ctx.import_job)

    # Notes (up to 3 most recent, embedded with ?with=contactfields)
    n = import_api_notes(contact, ctx.user_id, api_contact, ctx.import_job)

    # Tags (embedded directly)
    import_api_tags(contact, api_contact, ref_data)

    # Collect deferred data
    deferred = collect_deferred_data(api_contact, source_id, contact.id, deferred, ctx.opts)

    acc = %{acc | contacts: acc.contacts + 1, notes: acc.notes + n}
    {acc, deferred}
  end

  defp import_api_contact_fields(contact, api_contact, ref_data, ctx) do
    fields = api_contact["contactFields"] || []

    Enum.each(fields, fn field ->
      import_single_contact_field(contact, field, ref_data, ctx)
    end)
  end

  defp import_single_contact_field(contact, field, ref_data, ctx) do
    cft_name = get_in(field, ["contact_field_type", "name"])
    cft_id = if cft_name, do: Map.get(ref_data.contact_field_types, cft_name)
    raw_value = field["content"]
    value = normalize_field_value(raw_value, cft_id, ref_data, ctx)

    if cft_id && value && !contact_field_duplicate?(contact.id, cft_id, value) do
      create_contact_field(contact, field, cft_id, value, ctx.import_job)
    end
  end

  # Normalize phone fields to E.164 at import time so detection and intra-contact
  # dedup do simple equality. Other field types (email, social, etc) pass through.
  defp normalize_field_value(nil, _cft_id, _ref_data, _ctx), do: nil

  defp normalize_field_value(value, cft_id, ref_data, ctx) when is_binary(value) do
    if cft_id && Map.has_key?(ref_data.phone_cft_ids, cft_id) do
      region = parse_phone_region(ctx.opts["phone_default_region"])
      {:ok, normalized} = PhoneFormatter.normalize(value, region)
      normalized || value
    else
      value
    end
  end

  defp parse_phone_region(region) when region in [nil, ""], do: nil
  defp parse_phone_region(region) when is_binary(region), do: region

  defp create_contact_field(contact, field, cft_id, value, import_job) do
    attrs = %{"value" => value, "contact_field_type_id" => cft_id}

    case Contacts.create_contact_field(contact, attrs, normalize: false) do
      {:ok, cf} ->
        maybe_record_entity(import_job, "contact_field", field["uuid"], "contact_field", cf.id)

      {:error, reason} ->
        Logger.warning("[MonicaApi] Contact field for #{contact.first_name}: #{inspect(reason)}")
    end
  end

  defp import_api_addresses(contact, api_contact, import_job) do
    addresses = api_contact["addresses"] || []

    Enum.each(addresses, fn addr ->
      country_name =
        case addr["country"] do
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end

      attrs = %{
        "label" => addr["name"],
        "line1" => addr["street"],
        "city" => addr["city"],
        "province" => addr["province"],
        "postal_code" => addr["postal_code"],
        "country" => country_name
      }

      unless address_duplicate?(contact.id, attrs["line1"], attrs["city"], country_name) do
        create_imported_address(contact, attrs, addr, import_job)
      end
    end)
  end

  defp create_imported_address(contact, attrs, addr, import_job) do
    case Contacts.create_address(contact, attrs) do
      {:ok, address} ->
        maybe_record_entity(import_job, "address", addr["uuid"], "address", address.id)

      {:error, reason} ->
        Logger.warning("[MonicaApi] Address for #{contact.first_name}: #{inspect(reason)}")
    end
  end

  defp import_api_notes(contact, user_id, api_contact, import_job) do
    notes = api_contact["notes"] || []

    Enum.each(notes, fn note ->
      unless note_duplicate?(contact.id, note["body"]) do
        create_imported_note(contact, user_id, note, import_job)
      end
    end)

    length(notes)
  end

  defp create_imported_note(contact, user_id, note, import_job) do
    attrs = %{"body" => note["body"]}

    case Contacts.create_note(contact, user_id, attrs) do
      {:ok, n} ->
        maybe_record_entity(import_job, "note", note["uuid"], "note", n.id)

      {:error, reason} ->
        Logger.warning("[MonicaApi] Note for #{contact.first_name}: #{inspect(reason)}")
    end
  end

  defp import_api_tags(contact, api_contact, ref_data) do
    tags = api_contact["tags"] || []

    Enum.each(tags, fn tag ->
      tag_name = tag["name"]
      tag_id = Map.get(ref_data.tags, tag_name)

      if tag_id do
        Repo.insert_all(
          "contact_tags",
          [%{contact_id: contact.id, tag_id: tag_id}],
          on_conflict: :nothing
        )
      end
    end)
  end

  defp collect_deferred_data(api_contact, source_id, local_id, deferred, opts) do
    deferred
    |> collect_first_met_through(api_contact, source_id)
    |> collect_relationships(api_contact, source_id)
    |> collect_extra_notes(api_contact, source_id)
    |> collect_misc_data(api_contact, source_id, local_id, opts)
  end

  @misc_endpoints [
    {:calls, "number_of_calls"},
    {:activities, "number_of_activities"},
    {:gifts, "number_of_gifts"},
    {:debts, "number_of_debts"},
    {:tasks, "number_of_tasks"},
    {:reminders, "number_of_reminders"},
    {:conversations, "number_of_conversations"}
  ]

  # Build a plan entry for a contact's per-contact extra-data endpoints.
  # An endpoint is included only if (a) the wizard opt for that data type is
  # not explicitly false AND (b) Monica's `statistics.number_of_X` reports
  # > 0 (or the stat field is missing — safer to fetch than to silently
  # skip when Monica's payload shape is unfamiliar).
  #
  # `:pets` has no statistics field in Monica's contact payload, so it is
  # included whenever the wizard opt is on. The redundant fetch for pet-free
  # contacts is the documented cost.
  defp collect_misc_data(deferred, api_contact, source_id, local_id, opts) do
    stats = api_contact["statistics"] || %{}

    endpoints =
      @misc_endpoints
      |> Enum.filter(fn {key, stat_field} ->
        opts[Atom.to_string(key)] != false and (stats[stat_field] || 1) > 0
      end)
      |> Enum.map(&elem(&1, 0))

    endpoints = if opts["pets"] != false, do: [:pets | endpoints], else: endpoints

    if endpoints == [] do
      deferred
    else
      entry = %{
        source_id: to_string(source_id),
        local_id: local_id,
        endpoints: Enum.map(endpoints, &Atom.to_string/1)
      }

      %{deferred | misc_data: [entry | deferred.misc_data]}
    end
  end

  defp collect_first_met_through(deferred, api_contact, source_id) do
    info = api_contact["information"] || %{}
    how_you_met = info["how_you_met"] || %{}

    case how_you_met["first_met_through_contact"] do
      %{"id" => through_id} when not is_nil(through_id) ->
        entry = %{contact_source_id: source_id, through_source_id: to_string(through_id)}
        %{deferred | first_met_through: [entry | deferred.first_met_through]}

      _ ->
        deferred
    end
  end

  defp collect_relationships(deferred, api_contact, source_id) do
    info = api_contact["information"] || %{}
    relationships = info["relationships"] || %{}

    rel_entries =
      Enum.flat_map(relationships, fn {category, %{"contacts" => contacts}} ->
        Enum.map(contacts || [], fn rel ->
          rel_info = rel["relationship"] || %{}
          related_contact = rel["contact"] || %{}

          %{
            contact_source_id: source_id,
            related_source_id: to_string(related_contact["id"]),
            type_name: rel_info["name"] || category,
            reverse_name: rel_info["name"] || category
          }
        end)
      end)

    %{deferred | relationships: deferred.relationships ++ rel_entries}
  end

  defp collect_extra_notes(deferred, api_contact, source_id) do
    stats = api_contact["statistics"] || %{}
    note_count = stats["number_of_notes"] || 0
    embedded_notes = length(api_contact["notes"] || [])

    if note_count > embedded_notes do
      entry = %{
        source_id: source_id,
        monica_id: api_contact["id"],
        embedded_count: embedded_notes
      }

      %{deferred | extra_notes: [entry | deferred.extra_notes]}
    else
      deferred
    end
  end

  # ── Phase 1.5: Auto-merge definite duplicates ───────────────────────

  defp auto_merge_duplicates(account_id, import_job) do
    # Get all contact IDs imported in this batch
    import_records =
      Repo.all(
        from(ir in Imports.ImportRecord,
          where:
            ir.import_id == ^import_job.id and
              ir.source_entity_type == "contact",
          select: ir.local_entity_id
        )
      )

    # Load contacts with contact fields and addresses (addresses participate
    # in the broadened definite-duplicate predicate).
    contacts =
      Repo.all(
        from(c in Contacts.Contact,
          where: c.id in ^import_records and is_nil(c.deleted_at),
          preload: [:addresses, contact_fields: :contact_field_type]
        )
      )

    # Group by trimmed-and-collapsed normalized name. CardDAV-style duplicates
    # (monicahq/monica#6175) often differ only in trailing whitespace or
    # double-space artifacts, so the trim is load-bearing here.
    name_groups =
      contacts
      |> Enum.group_by(&name_key/1)
      |> Enum.filter(fn {_key, group} -> length(group) >= 2 end)

    merged_ids = MapSet.new()
    {merged_count, errors, _} = merge_name_groups(name_groups, account_id, import_job, merged_ids)

    Logger.info("[MonicaApi] Auto-merge: #{merged_count} contacts merged")
    %{merged: merged_count, errors: errors}
  end

  defp merge_name_groups(groups, account_id, import_job, merged_ids) do
    Enum.reduce(groups, {0, [], merged_ids}, fn {_name_key, group}, {count, errors, seen} ->
      # Sort by ID so survivor is always the first-imported
      sorted = Enum.sort_by(group, & &1.id)
      merge_group_contacts(sorted, account_id, import_job, count, errors, seen)
    end)
  end

  defp merge_group_contacts([_single], _account_id, _import_job, count, errors, seen),
    do: {count, errors, seen}

  defp merge_group_contacts(
         [survivor | rest],
         account_id,
         import_job,
         count,
         errors,
         seen
       ) do
    if MapSet.member?(seen, survivor.id) do
      {count, errors, seen}
    else
      Enum.reduce(rest, {count, errors, seen}, fn candidate, acc ->
        try_merge_candidate(survivor, candidate, account_id, import_job, acc)
      end)
    end
  end

  defp try_merge_candidate(survivor, candidate, account_id, import_job, {c, e, s}) do
    cond do
      MapSet.member?(s, candidate.id) ->
        {c, e, s}

      not definite_duplicate?(survivor, candidate) ->
        {c, e, s}

      true ->
        case Contacts.merge_contacts(survivor.id, candidate.id) do
          {:ok, _} ->
            update_import_records_after_merge(account_id, import_job, candidate.id, survivor.id)
            {c + 1, e, MapSet.put(s, candidate.id)}

          {:error, reason} ->
            msg =
              "Failed to merge #{candidate.first_name} #{candidate.last_name} (#{candidate.id}): #{inspect(reason)}"

            Logger.warning("[MonicaApi] #{msg}")
            {c, e ++ [msg], s}
        end
    end
  end

  # "Definite duplicate" predicate evaluated only after callers have already
  # grouped contacts by normalized {first_name, last_name}. The trimmed-name
  # equality is itself a strong identity signal, so within a group a single
  # shared {email, phone, address} suffices — this catches CardDAV-shaped
  # duplicates (monicahq/monica#6175) where every field is identical, the
  # "triple duplicates" case (same name + same email × N), and the original
  # narrow case (same name + shared phone or email).
  defp definite_duplicate?(contact_a, contact_b) do
    shared_emails?(contact_a, contact_b) or
      shared_phones?(contact_a, contact_b) or
      shared_addresses?(contact_a, contact_b)
  end

  defp shared_emails?(a, b) do
    set_a = extract_values_by_protocol(a, "mailto", &normalize_email_value/1)
    set_b = extract_values_by_protocol(b, "mailto", &normalize_email_value/1)
    intersects?(set_a, set_b)
  end

  defp shared_phones?(a, b) do
    # Phone values are E.164-canonical at this point (PhoneFormatter.normalize/2
    # ran during import for `tel`-protocol fields). Comparison is strict equality
    # after stripping non-digit characters as a safety net for any pre-existing
    # rows that bypassed normalization.
    set_a = extract_values_by_protocol(a, "tel", &normalize_phone_digits/1)
    set_b = extract_values_by_protocol(b, "tel", &normalize_phone_digits/1)
    intersects?(set_a, set_b)
  end

  defp shared_addresses?(a, b) do
    set_a = address_keys(a)
    set_b = address_keys(b)
    intersects?(set_a, set_b)
  end

  defp extract_values_by_protocol(contact, protocol_prefix, normalizer) do
    contact.contact_fields
    |> Enum.filter(fn cf ->
      cf.contact_field_type &&
        String.starts_with?(cf.contact_field_type.protocol || "", protocol_prefix)
    end)
    |> Enum.map(fn cf -> normalizer.(cf.value) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
  end

  defp normalize_email_value(nil), do: nil
  defp normalize_email_value(v) when is_binary(v), do: v |> String.trim() |> String.downcase()

  defp normalize_phone_digits(nil), do: nil

  defp normalize_phone_digits(v) when is_binary(v) do
    case String.replace(v, ~r/[^0-9]/, "") do
      "" -> nil
      digits -> digits
    end
  end

  defp address_keys(contact) do
    contact.addresses
    |> Enum.map(fn a ->
      line1 = normalize_address_part(a.line1)
      postal = normalize_address_part(a.postal_code)
      if line1 != "" and postal != "", do: {line1, postal}, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_address_part(nil), do: ""

  defp normalize_address_part(v) when is_binary(v) do
    v |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")
  end

  defp intersects?(a, b) do
    if MapSet.size(a) == 0 or MapSet.size(b) == 0 do
      false
    else
      not MapSet.disjoint?(a, b)
    end
  end

  defp name_key(contact) do
    {normalize_name_part(contact.first_name), normalize_name_part(contact.last_name)}
  end

  defp normalize_name_part(nil), do: ""

  defp normalize_name_part(v) when is_binary(v) do
    v |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")
  end

  defp update_import_records_after_merge(account_id, import_job, old_contact_id, new_contact_id) do
    from(ir in Imports.ImportRecord,
      where:
        ir.import_id == ^import_job.id and
          ir.source_entity_type == "contact" and
          ir.local_entity_id == ^old_contact_id
    )
    |> Repo.update_all(set: [local_entity_id: new_contact_id])

    # Also update any non-contact records that reference the old contact
    # (This is handled by merge_contacts which remaps sub-entities,
    # but import_records still need updating for Phase 2 cross-refs)
    Logger.info(
      "[MonicaApi] Remapped import records from contact #{old_contact_id} to #{new_contact_id} " <>
        "(account #{account_id})"
    )
  end

  # ── Phase 2: Cross-reference resolution ──────────────────────────────

  defp resolve_cross_references(account_id, deferred, import_job) do
    fmt_errors = resolve_first_met_through(account_id, deferred.first_met_through)
    rel_errors = resolve_relationships(account_id, deferred.relationships, import_job)
    fmt_errors ++ rel_errors
  end

  defp resolve_first_met_through(account_id, entries) do
    Enum.reduce(entries, [], fn %{contact_source_id: source_id, through_source_id: through_id},
                                errors ->
      with contact_rec when not is_nil(contact_rec) <-
             Imports.find_import_record(account_id, "monica_api", "contact", source_id),
           through_rec when not is_nil(through_rec) <-
             Imports.find_import_record(account_id, "monica_api", "contact", through_id),
           contact when not is_nil(contact) <-
             Repo.get(Contacts.Contact, contact_rec.local_entity_id),
           {:ok, _} <-
             Contacts.update_contact(contact, %{first_met_through_id: through_rec.local_entity_id}) do
        errors
      else
        nil ->
          msg = "Could not resolve first_met_through for contact #{source_id} -> #{through_id}"
          Logger.warning("[MonicaApi] #{msg}")
          errors ++ [msg]

        {:error, reason} ->
          msg = "first_met_through for #{source_id}: #{inspect_errors(reason)}"
          Logger.warning("[MonicaApi] #{msg}")
          errors ++ [msg]
      end
    end)
  end

  defp resolve_relationships(account_id, entries, import_job) do
    Enum.reduce(entries, [], fn entry, errors ->
      resolve_single_relationship(account_id, entry, import_job, errors)
    end)
  end

  defp resolve_single_relationship(account_id, entry, import_job, errors) do
    with contact_rec when not is_nil(contact_rec) <-
           Imports.find_import_record(
             account_id,
             "monica_api",
             "contact",
             entry.contact_source_id
           ),
         related_rec when not is_nil(related_rec) <-
           Imports.find_import_record(
             account_id,
             "monica_api",
             "contact",
             entry.related_source_id
           ),
         rt when not is_nil(rt) <-
           find_or_create_relationship_type(account_id, entry.type_name, entry.reverse_name) do
      contact = %Contacts.Contact{id: contact_rec.local_entity_id, account_id: account_id}

      attrs = %{
        "related_contact_id" => related_rec.local_entity_id,
        "relationship_type_id" => rt.id
      }

      case Contacts.create_relationship(contact, attrs) do
        {:ok, rel} ->
          maybe_record_entity(import_job, "relationship", nil, "relationship", rel.id)
          errors

        {:error, reason} ->
          msg =
            "Relationship #{entry.type_name} between #{entry.contact_source_id} and #{entry.related_source_id}: #{inspect_errors(reason)}"

          Logger.warning("[MonicaApi] #{msg}")
          errors ++ [msg]
      end
    else
      nil ->
        msg =
          "Skipping relationship #{entry.type_name} between #{entry.contact_source_id} and #{entry.related_source_id}: one or both contacts not imported"

        Logger.warning("[MonicaApi] #{msg}")
        errors ++ [msg]
    end
  rescue
    e in Ecto.ConstraintError ->
      Logger.info("[MonicaApi] Relationship already exists: #{Exception.message(e)}")
      errors
  end

  # ── Phase 3: Extra notes ─────────────────────────────────────────────

  defp fetch_all_extra_notes(credential, account_id, user_id, entries, import_job) do
    Enum.reduce(entries, [], fn entry, errors ->
      fetch_extra_notes_for_contact(credential, account_id, user_id, entry, import_job, errors)
    end)
  end

  defp fetch_extra_notes_for_contact(credential, account_id, user_id, entry, import_job, errors) do
    contact_rec =
      Imports.find_import_record(account_id, "monica_api", "contact", entry.source_id)

    if contact_rec do
      contact = Repo.get(Contacts.Contact, contact_rec.local_entity_id)

      if contact do
        fetch_notes_pages(credential, contact, user_id, entry, import_job, errors)
      else
        errors
      end
    else
      errors
    end
  end

  defp fetch_notes_pages(credential, contact, user_id, entry, import_job, errors) do
    fetch_notes_loop(
      credential,
      contact,
      user_id,
      entry,
      import_job,
      errors,
      _page = 1,
      _skip = entry.embedded_count
    )
  end

  defp fetch_notes_loop(credential, contact, user_id, entry, import_job, errors, page, skip) do
    url = "#{credential.url}/api/contacts/#{entry.monica_id}/notes"

    case api_get_json(credential, url, limit: @page_limit, page: page) do
      {:ok, %{"data" => notes, "meta" => meta}} when is_list(notes) ->
        last_page = meta["last_page"] || 1

        # Skip already-imported notes (first N were embedded in contact response)
        notes_to_import = if skip > 0, do: Enum.drop(notes, skip), else: notes
        import_extra_notes_batch(contact, user_id, notes_to_import, import_job)

        if page < last_page do
          fetch_notes_loop(credential, contact, user_id, entry, import_job, errors, page + 1, 0)
        else
          errors
        end

      {:error, :rate_limited} ->
        errors ++ ["Rate limited fetching notes for contact #{entry.source_id}"]

      {:error, reason} ->
        errors ++ ["Failed to fetch notes for contact #{entry.source_id}: #{inspect(reason)}"]

      _ ->
        errors
    end
  end

  defp import_extra_notes_batch(contact, user_id, notes, import_job) do
    Enum.each(notes, fn note ->
      unless note_duplicate?(contact.id, note["body"]) do
        create_imported_note(contact, user_id, note, import_job)
      end
    end)
  end

  # ── Reference data building ──────────────────────────────────────────

  defp build_or_update_ref_data(account_id, contacts, nil) do
    genders = collect_api_genders(contacts)
    tags = collect_api_tags(contacts)
    cfts = collect_api_contact_field_types(contacts)
    cft_map = find_or_create_contact_field_types(account_id, cfts)

    %{
      genders: find_or_create_genders(account_id, genders),
      tags: find_or_create_tags(account_id, tags),
      contact_field_types: cft_map,
      phone_cft_ids: phone_cft_id_map(account_id, Map.values(cft_map))
    }
  end

  defp build_or_update_ref_data(account_id, contacts, ref_data) do
    new_genders =
      contacts
      |> collect_api_genders()
      |> Enum.reject(&Map.has_key?(ref_data.genders, &1))

    new_tags =
      contacts
      |> collect_api_tags()
      |> Enum.reject(&Map.has_key?(ref_data.tags, &1))

    new_cfts =
      contacts
      |> collect_api_contact_field_types()
      |> Enum.reject(&Map.has_key?(ref_data.contact_field_types, &1))

    added_cfts = find_or_create_contact_field_types(account_id, new_cfts)

    phone_cft_ids =
      if new_cfts == [] do
        ref_data.phone_cft_ids
      else
        Map.merge(
          ref_data.phone_cft_ids,
          phone_cft_id_map(account_id, Map.values(added_cfts))
        )
      end

    %{
      genders: Map.merge(ref_data.genders, find_or_create_genders(account_id, new_genders)),
      tags: Map.merge(ref_data.tags, find_or_create_tags(account_id, new_tags)),
      contact_field_types: Map.merge(ref_data.contact_field_types, added_cfts),
      phone_cft_ids: phone_cft_ids
    }
  end

  defp collect_api_genders(contacts) do
    contacts
    |> Enum.map(& &1["gender"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_api_tags(contacts) do
    contacts
    |> Enum.flat_map(fn c -> (c["tags"] || []) |> Enum.map(& &1["name"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_api_contact_field_types(contacts) do
    contacts
    |> Enum.flat_map(fn c ->
      (c["contactFields"] || [])
      |> Enum.map(&get_in(&1, ["contact_field_type", "name"]))
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp find_or_create_genders(_account_id, []), do: %{}

  defp find_or_create_genders(account_id, names) do
    Map.new(names, fn name ->
      gender =
        Repo.one(
          from(g in Contacts.Gender,
            where: g.name == ^name and (g.account_id == ^account_id or is_nil(g.account_id)),
            limit: 1
          )
        ) || elem(Contacts.create_gender(account_id, %{name: name}), 1)

      {name, gender.id}
    end)
  end

  defp find_or_create_tags(_account_id, []), do: %{}

  defp find_or_create_tags(account_id, names) do
    Map.new(names, fn name ->
      tag =
        Repo.one(
          from(t in Contacts.Tag,
            where: t.name == ^name and t.account_id == ^account_id,
            limit: 1
          )
        ) || elem(Contacts.create_tag(account_id, %{name: name}), 1)

      {name, tag.id}
    end)
  end

  defp find_or_create_contact_field_types(_account_id, []), do: %{}

  defp find_or_create_contact_field_types(account_id, names) do
    Map.new(names, fn name ->
      cft =
        Repo.one(
          from(t in Contacts.ContactFieldType,
            where: t.name == ^name and (t.account_id == ^account_id or is_nil(t.account_id)),
            limit: 1
          )
        ) || elem(Contacts.create_contact_field_type(account_id, %{name: name}), 1)

      {name, cft.id}
    end)
  end

  # O(1)-lookup map of phone-protocol contact_field_type IDs. A plain map
  # (`%{id => true}`) is used rather than a MapSet to keep dialyzer happy
  # with the ref_data shape inference.
  defp phone_cft_id_map(_account_id, []), do: %{}

  defp phone_cft_id_map(account_id, cft_ids) when is_list(cft_ids) do
    Repo.all(
      from t in Contacts.ContactFieldType,
        where: t.id in ^cft_ids,
        where: is_nil(t.account_id) or t.account_id == ^account_id,
        where: fragment("? LIKE 'tel%'", t.protocol),
        select: t.id
    )
    |> Map.new(&{&1, true})
  end

  defp find_or_create_relationship_type(_account_id, nil, _reverse), do: nil

  defp find_or_create_relationship_type(account_id, name, reverse_name) do
    Repo.one(
      from(rt in Contacts.RelationshipType,
        where: rt.name == ^name and (rt.account_id == ^account_id or is_nil(rt.account_id)),
        limit: 1
      )
    ) ||
      case Contacts.create_relationship_type(account_id, %{
             name: name,
             reverse_name: reverse_name || name
           }) do
        {:ok, rt} -> rt
        {:error, _} -> nil
      end
  end

  # ── HTTP helpers ─────────────────────────────────────────────────────

  defp api_get(credential, url, params \\ []) do
    RateLimiter.wait!(credential.url)

    headers = [{"Authorization", "Bearer #{credential.api_key}"}, {"Accept", "application/json"}]
    req_options = Map.get(credential, :req_options, [])

    options =
      [
        headers: headers,
        params: params,
        max_retries: 5,
        retry_log_level: :warn
      ] ++ req_options

    Req.get(url, options)
  end

  defp api_get_json(credential, url, params) do
    case api_get(credential, url, params) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_single_contact(credential, monica_id) do
    url = "#{credential.url}/api/contacts/#{monica_id}"

    case api_get(credential, url, []) do
      {:ok, %{status: 200, body: %{"data" => contact}}} when is_map(contact) ->
        {:ok, contact}

      {:ok, %{status: 404}} ->
        :not_found

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Mirror Monica's listing filter on direct-GET responses:
  # - Monica's index() chains ->real()->active() which means
  #   is_active = 1 AND is_partial = 0.
  # - Partials still anchor relationship targets, so we accept them
  #   (relationship resolution depends on importing the partial stubs).
  # - Inactive contacts are deliberately hidden by Monica's UI; skip them.
  defp accept_backfill_response(%{"is_active" => true, "is_partial" => true}),
    do: :import_partial

  defp accept_backfill_response(%{"is_active" => true, "is_partial" => false}),
    do: :import_full

  defp accept_backfill_response(%{"is_active" => false}), do: :skip_inactive
  defp accept_backfill_response(_other), do: :skip_inactive

  # ── Date parsing helpers ─────────────────────────────────────────────

  defp parse_special_date(nil), do: %{}

  defp parse_special_date(date_data) do
    date_str = date_data["date"]

    if date_str do
      case parse_date_or_datetime(date_str) do
        {:ok, date} ->
          year_unknown = date_data["is_year_unknown"] == true
          %{date: date, year_unknown: year_unknown}

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp parse_date_or_datetime(str) do
    case Date.from_iso8601(str) do
      {:ok, _date} = ok ->
        ok

      {:error, _} ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> {:ok, DateTime.to_date(dt)}
          _ -> :error
        end
    end
  end

  # ── General helpers ──────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty_string(nil), do: nil
  defp non_empty_string(""), do: nil
  defp non_empty_string(s) when is_binary(s), do: s
  defp non_empty_string(_), do: nil

  defp add_error(acc, msg) do
    errors = if length(acc.errors) < 50, do: acc.errors ++ [msg], else: acc.errors
    %{acc | skipped: acc.skipped + 1, error_count: acc.error_count + 1, errors: errors}
  end

  defp api_contact_display_name(api_contact) do
    [api_contact["first_name"], api_contact["last_name"]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
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

  defp contact_field_duplicate?(_contact_id, nil, _value), do: false
  defp contact_field_duplicate?(_contact_id, _cft_id, nil), do: false

  defp contact_field_duplicate?(contact_id, cft_id, value) do
    Repo.exists?(
      from(cf in Contacts.ContactField,
        where:
          cf.contact_id == ^contact_id and
            cf.contact_field_type_id == ^cft_id and
            fragment("lower(?)", cf.value) == fragment("lower(?)", ^value)
      )
    )
  end

  defp address_duplicate?(contact_id, line1, city, country) do
    Repo.exists?(
      from(a in Contacts.Address,
        where:
          a.contact_id == ^contact_id and
            fragment("lower(coalesce(?, ''))", a.line1) ==
              fragment("lower(coalesce(?, ''))", ^(line1 || "")) and
            fragment("lower(coalesce(?, ''))", a.city) ==
              fragment("lower(coalesce(?, ''))", ^(city || "")) and
            fragment("lower(coalesce(?, ''))", a.country) ==
              fragment("lower(coalesce(?, ''))", ^(country || ""))
      )
    )
  end

  defp note_duplicate?(_contact_id, nil), do: false
  defp note_duplicate?(_contact_id, ""), do: false

  defp note_duplicate?(contact_id, body) when is_binary(body) do
    trimmed = String.trim(body)

    Repo.exists?(
      from(n in Contacts.Note,
        where:
          n.contact_id == ^contact_id and
            fragment("trim(?)", n.body) == ^trimmed
      )
    )
  end

  defp maybe_check_import_cancelled(import_job, idx) do
    if import_job && rem(idx, 10) == 0 do
      refreshed = Imports.get_import!(import_job.id)
      if refreshed.status == "cancelled", do: throw(:cancelled)
    end
  end

  defp maybe_broadcast_progress(topic, idx, total, broadcast_interval) do
    if rem(idx, broadcast_interval) == 0 || idx == total do
      Phoenix.PubSub.broadcast(
        Kith.PubSub,
        topic,
        {:import_progress, %{current: idx, total: total}}
      )
    end
  end

  # ── Phase 13: Document import (async) ──────────────────────────────

  defp enqueue_document_imports(credential, account_id, user_id, import_job) do
    import_records =
      Repo.all(
        from(ir in Imports.ImportRecord,
          where:
            ir.import_id == ^import_job.id and
              ir.source_entity_type == "contact",
          select: {ir.source_entity_id, ir.local_entity_id}
        )
      )

    base_url = credential.url

    Enum.each(import_records, fn {source_id, local_id} ->
      url = "#{base_url}/api/contacts/#{source_id}/documents"

      case api_get_json(credential, url, []) do
        {:ok, %{"data" => docs}} when is_list(docs) and docs != [] ->
          %{
            "account_id" => account_id,
            "user_id" => user_id,
            "contact_id" => local_id,
            "import_id" => import_job.id,
            "credential_url" => credential.url,
            "credential_api_key" => credential.api_key,
            "documents" => docs
          }
          |> MonicaDocumentImportWorker.new()
          |> Oban.insert()

        _ ->
          :ok
      end
    end)
  end
end
