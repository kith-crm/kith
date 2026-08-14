defmodule Kith.Workers.MonicaPhotoSyncWorker do
  @moduledoc """
  Imports photos for a Monica API import after the main contact crawl completes.

  Enqueued by `MonicaApiCrawlWorker` when `api_options["photos"]` is true.
  Paginates `GET /api/photos`, decodes each photo's inline `dataUrl`, dedups
  by SHA-256 content hash, persists to storage and the `photos` table, and
  sets the owning contact's avatar if not already set.

  Writes incremental progress to `import.sync_summary` after each page so the
  import-history UI shows live counts and a per-photo table.
  """

  use Oban.Worker, queue: :imports, max_attempts: 3

  require Logger

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.Repo
  alias Kith.Storage

  @page_limit 100
  @max_rate_limit_retries 3
  @rate_limit_sleep_ms :timer.seconds(65)
  @max_photos_in_summary 500
  @log_prefix "[MonicaPhotoSync]"

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "import_id" => import_id,
          "credential_url" => credential_url,
          "credential_api_key" => credential_api_key
        }
      }) do
    import_job = Imports.get_import!(import_id)
    Logger.metadata(import_id: import_id, worker: "MonicaPhotoSync")
    Logger.info("#{@log_prefix} Starting photo sync for import #{import_id}")

    credential = %{
      url: credential_url,
      api_key: credential_api_key,
      req_options: Application.get_env(:kith, :monica_req_options, [])
    }

    initial = empty_summary()
    Imports.update_sync_summary(import_job, initial)

    case crawl_pages(credential, import_job, 1, initial) do
      {:ok, final} ->
        Imports.update_sync_summary(import_job, final)

        Logger.info(
          "#{@log_prefix} Photo sync complete: " <>
            "#{final["synced"]}/#{final["total"]} synced, " <>
            "#{final["failed"]} failed, #{final["not_found"]} not_found"
        )

        :ok

      {:error, reason} ->
        Logger.error("#{@log_prefix} Photo sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  # ── Page loop ───────────────────────────────────────────────────────────

  defp crawl_pages(credential, import_job, page, summary) do
    url = "#{credential.url}/api/photos"

    case api_get_json(credential, url, limit: @page_limit, page: page) do
      {:ok, %{"data" => photos, "meta" => meta}} when is_list(photos) ->
        last_page = meta["last_page"] || 1

        Logger.info(
          "#{@log_prefix} page #{page}: #{length(photos)} photos (#{last_page} pages total)"
        )

        page_summary =
          Enum.reduce(photos, summary, fn photo, acc ->
            import_one_photo(photo, import_job, acc)
          end)

        Logger.info(
          "#{@log_prefix} page #{page} done (running: " <>
            "#{page_summary["synced"]}/#{page_summary["total"]} synced, " <>
            "#{page_summary["failed"]} failed, #{page_summary["not_found"]} not_found)"
        )

        Imports.update_sync_summary(import_job, page_summary)

        if page < last_page do
          crawl_pages(credential, import_job, page + 1, page_summary)
        else
          {:ok, page_summary}
        end

      {:error, reason} ->
        Logger.warning("#{@log_prefix} Failed to fetch photos page #{page}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("#{@log_prefix} Unexpected response on page #{page}: #{inspect(other)}")
        {:ok, summary}
    end
  end

  # ── Per-photo flow ─────────────────────────────────────────────────────

  defp import_one_photo(photo, import_job, summary) do
    summary = bump(summary, "total")
    uuid = photo["uuid"]
    monica_contact_id = get_in(photo, ["contact", "id"])

    case resolve_contact(import_job.account_id, monica_contact_id) do
      {:ok, contact} ->
        handle_decode(contact, photo, import_job, summary, uuid)

      {:not_found, reason} ->
        Logger.info("#{@log_prefix} photo #{uuid}: #{reason}")

        summary
        |> record_photo(%{
          "uuid" => uuid,
          "contact_id" => monica_contact_id,
          "status" => "not_found",
          "reason" => reason
        })
        |> bump("not_found")
    end
  end

  defp resolve_contact(_account_id, nil),
    do: {:not_found, "missing contact id in /api/photos response"}

  defp resolve_contact(account_id, monica_contact_id) do
    source_id = to_string(monica_contact_id)

    case Imports.find_import_record(account_id, "monica_api", "contact", source_id) do
      nil ->
        {:not_found, "contact #{source_id} not in import_records"}

      %{local_entity_id: local_id} ->
        case Repo.get(Contacts.Contact, local_id) do
          nil ->
            {:not_found, "local contact #{local_id} not found"}

          %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
            {:not_found, "local contact #{local_id} is soft-deleted"}

          contact ->
            {:ok, contact}
        end
    end
  end

  defp handle_decode(contact, photo, import_job, summary, uuid) do
    case decode_photo_data(photo) do
      {:ok, binary} ->
        handle_dedup(contact, photo, binary, import_job, summary, uuid)

      {:error, reason} ->
        Logger.warning("#{@log_prefix} photo #{uuid}: failed (#{reason})")

        summary
        |> record_photo(%{
          "uuid" => uuid,
          "contact_id" => contact.id,
          "status" => "failed",
          "reason" => to_string(reason)
        })
        |> bump("failed")
    end
  end

  defp handle_dedup(contact, photo, binary, import_job, summary, uuid) do
    content_hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    if Contacts.photo_exists_by_hash?(contact.id, content_hash) do
      Logger.debug(
        "#{@log_prefix} photo #{uuid}: duplicate hash for contact #{contact.id}, skipping"
      )

      summary
      |> record_photo(%{
        "uuid" => uuid,
        "contact_id" => contact.id,
        "status" => "synced",
        "reason" => "duplicate"
      })
      |> bump("synced")
    else
      do_upload(contact, photo, binary, content_hash, import_job, summary, uuid)
    end
  end

  defp do_upload(contact, photo, binary, content_hash, import_job, summary, uuid) do
    file_name = photo["original_filename"] || "photo.jpg"
    key = Storage.generate_key(contact.account_id, "photos", file_name)

    attrs = %{
      "file_name" => file_name,
      "storage_key" => key,
      "file_size" => byte_size(binary),
      "content_type" => photo["mime_type"] || "image/jpeg",
      "content_hash" => content_hash
    }

    with {:ok, _} <- Storage.upload_binary(binary, key),
         {:ok, photo_record} <- Contacts.create_photo(contact, attrs) do
      maybe_record_entity(import_job, uuid, photo_record.id)
      maybe_set_avatar(contact, key)

      Logger.debug(
        "#{@log_prefix} photo #{uuid} → contact #{contact.id}: synced " <>
          "(hash #{String.slice(content_hash, 0, 8)})"
      )

      summary
      |> record_photo(%{
        "uuid" => uuid,
        "contact_id" => contact.id,
        "status" => "synced"
      })
      |> bump("synced")
    else
      {:error, reason} ->
        reason_str = inspect(reason)
        Logger.warning("#{@log_prefix} photo #{uuid}: failed (#{reason_str})")

        summary
        |> record_photo(%{
          "uuid" => uuid,
          "contact_id" => contact.id,
          "status" => "failed",
          "reason" => reason_str
        })
        |> bump("failed")
    end
  end

  defp maybe_set_avatar(%{avatar: nil} = contact, key) do
    contact
    |> Ecto.Changeset.change(avatar: key)
    |> Repo.update!()
  end

  defp maybe_set_avatar(_contact, _key), do: :ok

  defp maybe_record_entity(_import_job, nil, _local_id), do: :ok

  defp maybe_record_entity(import_job, uuid, local_id),
    do: Imports.record_imported_entity(import_job, "photo", uuid, "photo", local_id)

  # ── Summary helpers ────────────────────────────────────────────────────

  defp empty_summary do
    %{
      "total" => 0,
      "synced" => 0,
      "failed" => 0,
      "not_found" => 0,
      "photos" => []
    }
  end

  defp bump(summary, key), do: Map.update!(summary, key, &(&1 + 1))

  defp record_photo(summary, entry) do
    Map.update!(summary, "photos", fn list ->
      [entry | Enum.take(list, @max_photos_in_summary - 1)]
    end)
  end

  # ── Decoding ───────────────────────────────────────────────────────────

  defp decode_photo_data(%{"dataUrl" => "data:" <> _ = data_url}) do
    case String.split(data_url, ",", parts: 2) do
      [_meta, encoded] ->
        case Base.decode64(encoded) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, :base64_decode_failed}
        end

      _ ->
        {:error, :malformed_data_url}
    end
  end

  defp decode_photo_data(_), do: {:error, :no_data_url}

  # ── HTTP helpers ───────────────────────────────────────────────────────

  defp api_get_json(credential, url, params),
    do: api_get_json_with_retry(credential, url, params, 0)

  defp api_get_json_with_retry(_credential, _url, _params, retries)
       when retries >= @max_rate_limit_retries,
       do: {:error, :rate_limited}

  defp api_get_json_with_retry(credential, url, params, retries) do
    case api_get(credential, url, params) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 429}} ->
        Logger.warning(
          "#{@log_prefix} rate limited, sleeping #{@rate_limit_sleep_ms}ms (retry #{retries + 1})"
        )

        Process.sleep(@rate_limit_sleep_ms)
        api_get_json_with_retry(credential, url, params, retries + 1)

      {:ok, %{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_get(credential, url, params) do
    headers = [
      {"Authorization", "Bearer #{credential.api_key}"},
      {"Accept", "application/json"}
    ]

    options = [headers: headers, params: params] ++ Map.get(credential, :req_options, [])
    Req.get(url, options)
  end
end
