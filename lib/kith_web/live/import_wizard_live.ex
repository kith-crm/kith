defmodule KithWeb.ImportWizardLive do
  @moduledoc """
  Multi-step import wizard LiveView.

  Steps:
    1. source — Choose source (vCard or Monica API) and upload/configure
    2. confirm — Review summary before starting
    3. progress — Real-time progress bar during import
    4. complete — Results summary
  """

  use KithWeb, :live_view

  alias Kith.Contacts.PhoneFormatter
  alias Kith.Imports
  alias Kith.Imports.Sources.MonicaApi
  alias Kith.Policy
  alias Kith.Storage
  alias Kith.Workers.{ImportSourceWorker, MonicaApiCrawlWorker}

  import KithWeb.SettingsLive.SettingsLayout

  @max_file_size 50 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    locale = account_locale(socket)

    {:ok,
     socket
     |> assign(:page_title, "Import Contacts")
     |> assign(:step, :source)
     |> assign(:source, "vcard")
     |> assign(:api_url, "")
     |> assign(:api_key, "")
     |> assign(:api_options, default_api_options(socket))
     |> assign(:phone_regions, build_phone_regions(locale))
     |> assign(:api_testing, false)
     |> assign(:current_import, nil)
     |> assign(:progress, nil)
     |> assign(:results, nil)
     |> assign(:error, nil)
     |> allow_upload(:import_file,
       accept: ~w(.vcf .json),
       max_file_size: @max_file_size,
       max_entries: 1
     )}
  end

  defp default_api_options(socket) do
    %{
      "photos" => false,
      "auto_merge_duplicates" => true,
      "phone_default_region" => account_default_region(socket),
      "pets" => true,
      "calls" => true,
      "activities" => true,
      "gifts" => true,
      "debts" => true,
      "tasks" => true,
      "reminders" => true,
      "conversations" => true
    }
  end

  defp account_default_region(%{assigns: %{current_scope: %{account: %{locale: locale}}}})
       when is_binary(locale),
       do: PhoneFormatter.region_for_locale(locale) || ""

  defp account_default_region(_socket), do: ""

  @impl true
  def handle_params(_params, _uri, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    if Policy.can?(user, :create, :import) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{scope.account.id}")
      end

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You do not have permission to import contacts.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # ── Event handlers ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("set_source", %{"source" => source}, socket)
      when source in ["vcard", "monica_api"] do
    {:noreply, assign(socket, :source, source)}
  end

  def handle_event("update_api_url", %{"value" => url}, socket) do
    {:noreply, assign(socket, :api_url, url)}
  end

  def handle_event("update_api_key", %{"value" => key}, socket) do
    {:noreply, assign(socket, :api_key, key)}
  end

  def handle_event("toggle_option", %{"option" => option}, socket) do
    options = socket.assigns.api_options
    updated = Map.update(options, option, true, &(!&1))
    {:noreply, assign(socket, :api_options, updated)}
  end

  def handle_event("next_step", _params, socket) do
    case validate_step(socket) do
      :ok ->
        {:noreply,
         socket |> assign(:error, nil) |> assign(:api_testing, false) |> assign(:step, :confirm)}

      {:error, msg} ->
        {:noreply, socket |> assign(:error, msg) |> assign(:api_testing, false)}
    end
  end

  def handle_event("back_to_source", _params, socket) do
    {:noreply, socket |> assign(:step, :source) |> assign(:error, nil)}
  end

  def handle_event("start_import", _params, socket) do
    scope = socket.assigns.current_scope

    case do_start_import(socket, scope) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, msg, socket} ->
        {:noreply, socket |> assign(:error, msg) |> assign(:step, :source)}
    end
  end

  def handle_event("cancel_import", _params, socket) do
    if import = socket.assigns.current_import do
      Imports.cancel_import(import)
    end

    {:noreply,
     socket
     |> assign(:step, :source)
     |> assign(:current_import, nil)
     |> assign(:progress, nil)
     |> assign(:error, nil)}
  end

  def handle_event("restart", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :source)
     |> assign(:source, "vcard")
     |> assign(:api_url, "")
     |> assign(:api_key, "")
     |> assign(:api_options, default_api_options(socket))
     |> assign(:api_testing, false)
     |> assign(:current_import, nil)
     |> assign(:progress, nil)
     |> assign(:results, nil)
     |> assign(:error, nil)}
  end

  def handle_event("set_phone_region", %{"region" => region}, socket) do
    options = Map.put(socket.assigns.api_options, "phone_default_region", region)
    {:noreply, assign(socket, :api_options, options)}
  end

  # ── PubSub handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info({:import_complete, results}, socket) do
    {:noreply,
     socket
     |> assign(:step, :complete)
     |> assign(:progress, nil)
     |> assign(:results, results)}
  end

  def handle_info({:sync_complete, _summary}, socket) do
    {:noreply, socket}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp validate_step(socket) do
    case socket.assigns.source do
      "vcard" -> validate_vcard_step(socket)
      "monica_api" -> validate_monica_api_step(socket)
    end
  end

  defp validate_vcard_step(socket) do
    if socket.assigns.uploads.import_file.entries == [] do
      {:error, "Please select a .vcf file to upload."}
    else
      :ok
    end
  end

  defp validate_monica_api_step(socket) do
    with :ok <- validate_api_credentials(socket) do
      test_api_connection(socket)
    end
  end

  defp validate_api_credentials(socket) do
    url = String.trim(socket.assigns.api_url)
    key = String.trim(socket.assigns.api_key)

    cond do
      url == "" -> {:error, "Monica URL is required."}
      key == "" -> {:error, "Monica API key is required."}
      true -> :ok
    end
  end

  defp test_api_connection(socket) do
    url = String.trim(socket.assigns.api_url)
    key = String.trim(socket.assigns.api_key)

    case MonicaApi.test_connection(%{url: url, api_key: key}) do
      :ok -> :ok
      {:error, msg} -> {:error, "Connection failed: #{msg}"}
    end
  end

  defp do_start_import(socket, scope) do
    if socket.assigns.source == "monica_api" do
      do_start_api_import(socket, scope)
    else
      do_start_file_import(socket, scope)
    end
  end

  defp do_start_file_import(socket, scope) do
    account_id = scope.account.id
    user_id = scope.user.id
    source = socket.assigns.source

    results =
      consume_uploaded_entries(socket, :import_file, fn %{path: path}, entry ->
        data = File.read!(path)

        storage_key =
          "imports/#{account_id}/#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}"

        case Storage.upload_binary(data, storage_key) do
          {:ok, _} -> {:ok, {storage_key, entry.client_name, byte_size(data)}}
          {:error, reason} -> {:ok, {:error, "Failed to store file: #{inspect(reason)}"}}
        end
      end)

    case List.first(results) do
      {:error, msg} ->
        {:error, msg, socket}

      nil ->
        {:error, "No file uploaded.", socket}

      {storage_key, file_name, file_size} ->
        create_and_enqueue_file_import(
          socket,
          account_id,
          user_id,
          source,
          storage_key,
          file_name,
          file_size
        )
    end
  end

  defp do_start_api_import(socket, scope) do
    account_id = scope.account.id
    user_id = scope.user.id

    import_attrs = %{
      source: "monica_api",
      api_url: String.trim(socket.assigns.api_url),
      api_key_encrypted: String.trim(socket.assigns.api_key),
      api_options: build_api_options(socket)
    }

    case Imports.create_import(account_id, user_id, import_attrs) do
      {:ok, import_job} ->
        %{import_id: import_job.id} |> MonicaApiCrawlWorker.new() |> Oban.insert()

        socket =
          socket
          |> assign(:current_import, import_job)
          |> assign(:step, :progress)
          |> assign(:progress, %{current: 0, total: 0})
          |> assign(:error, nil)

        {:ok, socket}

      {:error, :import_in_progress} ->
        {:error, "An import is already in progress. Please wait for it to finish.", socket}

      {:error, _changeset} ->
        {:error, "Failed to create import job. Please try again.", socket}
    end
  end

  defp create_and_enqueue_file_import(
         socket,
         account_id,
         user_id,
         source,
         storage_key,
         file_name,
         file_size
       ) do
    import_attrs = %{
      source: source,
      file_name: file_name,
      file_size: file_size,
      file_storage_key: storage_key
    }

    case Imports.create_import(account_id, user_id, import_attrs) do
      {:ok, import_job} ->
        %{import_id: import_job.id} |> ImportSourceWorker.new() |> Oban.insert()

        socket =
          socket
          |> assign(:current_import, import_job)
          |> assign(:step, :progress)
          |> assign(:progress, %{current: 0, total: 0})
          |> assign(:error, nil)

        {:ok, socket}

      {:error, :import_in_progress} ->
        {:error, "An import is already in progress. Please wait for it to finish.", socket}

      {:error, _changeset} ->
        {:error, "Failed to create import job. Please try again.", socket}
    end
  end

  defp build_api_options(socket) do
    # Pass options through unchanged so non-boolean settings (phone_default_region)
    # survive. MonicaApi reads each key directly and treats falsy as off.
    socket.assigns.api_options
  end

  defp build_phone_regions(locale) do
    [{"", phone_off_label(locale)} | PhoneFormatter.supported_regions(locale)]
  end

  defp account_locale(%{assigns: %{current_scope: %{account: %{locale: locale}}}})
       when is_binary(locale),
       do: locale

  defp account_locale(_), do: "en"

  defp phone_off_label("en"), do: "Don't normalize bare numbers"
  defp phone_off_label("fr"), do: "Ne pas normaliser les numéros sans indicatif"
  defp phone_off_label("de"), do: "Nackte Nummern nicht normalisieren"
  defp phone_off_label("es"), do: "No normalizar números sin prefijo"
  defp phone_off_label("pt"), do: "Não normalizar números sem prefixo"
  defp phone_off_label(_), do: "Don't normalize bare numbers"

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <.settings_shell current_path={@current_path} current_scope={@current_scope}>
        <UI.header>
          Import Contacts
          <:subtitle>Import contacts from a vCard file or Monica CRM API</:subtitle>
        </UI.header>

        <%!-- Step 1: Source selection --%>
        <div :if={@step == :source} class="mt-6">
          <form id="import-source-form" phx-submit="next_step" phx-change="validate">
            <%!-- Source selection --%>
            <div class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6 mb-4">
              <p class="text-sm font-medium text-[var(--color-text-primary)] mb-4">
                Select import source
              </p>

              <div class="space-y-3">
                <label class={[
                  "flex items-start gap-3 p-3 rounded-[var(--radius-md)] border cursor-pointer transition-colors",
                  @source == "vcard" && "border-[var(--color-accent)] bg-[var(--color-accent)]/5",
                  @source != "vcard" &&
                    "border-[var(--color-border)] hover:border-[var(--color-text-tertiary)]"
                ]}>
                  <input
                    type="radio"
                    name="source"
                    value="vcard"
                    checked={@source == "vcard"}
                    phx-click="set_source"
                    phx-value-source="vcard"
                    class="mt-0.5"
                  />
                  <div>
                    <p class="font-medium text-sm text-[var(--color-text-primary)]">vCard (.vcf)</p>
                    <p class="text-xs text-[var(--color-text-secondary)] mt-0.5">
                      Import from Google Contacts, Apple Contacts, Outlook, or any vCard export
                    </p>
                  </div>
                </label>

                <label class={[
                  "flex items-start gap-3 p-3 rounded-[var(--radius-md)] border cursor-pointer transition-colors",
                  @source == "monica_api" &&
                    "border-[var(--color-accent)] bg-[var(--color-accent)]/5",
                  @source != "monica_api" &&
                    "border-[var(--color-border)] hover:border-[var(--color-text-tertiary)]"
                ]}>
                  <input
                    type="radio"
                    name="source"
                    value="monica_api"
                    checked={@source == "monica_api"}
                    phx-click="set_source"
                    phx-value-source="monica_api"
                    class="mt-0.5"
                  />
                  <div>
                    <p class="font-medium text-sm text-[var(--color-text-primary)]">
                      Monica CRM (API)
                    </p>
                    <p class="text-xs text-[var(--color-text-secondary)] mt-0.5">
                      Import directly from your Monica instance via API. No file export needed.
                    </p>
                  </div>
                </label>
              </div>
            </div>

            <%!-- File upload (vCard only) --%>
            <div
              :if={@source != "monica_api"}
              class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6 mb-4"
            >
              <p class="text-sm font-medium text-[var(--color-text-primary)] mb-3">
                Upload vCard file (.vcf)
              </p>

              <div
                class="border-2 border-dashed border-[var(--color-border)] rounded-[var(--radius-lg)] p-8 text-center hover:border-[var(--color-text-tertiary)] transition-colors"
                phx-drop-target={@uploads.import_file.ref}
              >
                <.live_file_input upload={@uploads.import_file} class="hidden" />
                <p class="text-[var(--color-text-tertiary)]">
                  Drag and drop your <span class="font-semibold">.vcf</span>
                  file here, or
                  <label
                    for={@uploads.import_file.ref}
                    class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] hover:underline cursor-pointer"
                  >
                    browse
                  </label>
                </p>
                <p class="text-xs text-[var(--color-text-disabled)] mt-1">Maximum file size: 50 MB</p>
              </div>

              <div
                :for={entry <- @uploads.import_file.entries}
                class="mt-4 flex items-center justify-between"
              >
                <span class="text-sm text-[var(--color-text-secondary)]">{entry.client_name}</span>
                <span class="text-xs text-[var(--color-text-tertiary)]">
                  {Float.round(entry.client_size / 1024, 1)} KB
                </span>
              </div>

              <p
                :for={err <- upload_errors(@uploads.import_file)}
                class="mt-2 text-sm text-[var(--color-error)]"
              >
                {upload_error_message(err)}
              </p>
            </div>

            <%!-- Monica API connection --%>
            <div
              :if={@source == "monica_api"}
              class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6 mb-4"
            >
              <p class="text-sm font-medium text-[var(--color-text-primary)] mb-1">
                Monica API connection
              </p>
              <p class="text-xs text-[var(--color-text-secondary)] mb-4">
                Enter your Monica instance URL and API key. Connection will be verified before import.
              </p>

              <div class="space-y-3">
                <div>
                  <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-1">
                    Monica URL
                  </label>
                  <input
                    type="url"
                    value={@api_url}
                    phx-blur="update_api_url"
                    phx-value-value={@api_url}
                    placeholder="https://your-monica-instance.com"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none"
                  />
                </div>

                <div>
                  <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-1">
                    API Key
                  </label>
                  <input
                    type="password"
                    value={@api_key}
                    phx-blur="update_api_key"
                    phx-value-value={@api_key}
                    placeholder="Your Monica API key"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none"
                  />
                </div>

                <%!-- API options --%>
                <div :if={String.trim(@api_url) != "" && String.trim(@api_key) != ""}>
                  <p class="text-xs font-medium text-[var(--color-text-secondary)] mb-2">
                    Options:
                  </p>
                  <div class="space-y-2">
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={@api_options["photos"]}
                        phx-click="toggle_option"
                        phx-value-option="photos"
                        class="rounded border-[var(--color-border)]"
                      />
                      <span class="text-sm text-[var(--color-text-primary)]">Import photos</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={@api_options["extra_notes"] != false}
                        phx-click="toggle_option"
                        phx-value-option="extra_notes"
                        class="rounded border-[var(--color-border)]"
                      />
                      <span class="text-sm text-[var(--color-text-primary)]">
                        Fetch all notes (for contacts with more than 3)
                      </span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={@api_options["auto_merge_duplicates"]}
                        phx-click="toggle_option"
                        phx-value-option="auto_merge_duplicates"
                        class="rounded border-[var(--color-border)]"
                      />
                      <div>
                        <span class="text-sm text-[var(--color-text-primary)]">
                          Auto-merge definite duplicates
                        </span>
                        <p class="text-xs text-[var(--color-text-tertiary)]">
                          Merge contacts that share 2+ strong signals (email, phone, address) or share an email/phone and an address
                        </p>
                      </div>
                    </label>
                    <div class="mt-2">
                      <label class="block">
                        <span class="text-sm text-[var(--color-text-primary)]">
                          Default country for phone numbers without country code
                        </span>
                        <p class="text-xs text-[var(--color-text-tertiary)] mb-1">
                          Phones written as <span class="font-mono">(555) 123-4567</span>
                          will be stored in E.164 form using this region.
                          Numbers that already start with <span class="font-mono">+</span>
                          are unaffected.
                        </p>
                        <select
                          phx-change="set_phone_region"
                          name="region"
                          class="mt-1 block w-full rounded border-[var(--color-border)] text-sm"
                        >
                          <option
                            :for={{code, label} <- @phone_regions}
                            value={code}
                            selected={@api_options["phone_default_region"] == code}
                          >
                            {label}
                          </option>
                        </select>
                      </label>
                    </div>
                  </div>
                  <div class="mt-3 pt-3 border-t border-[var(--color-border-subtle)]">
                    <span class="text-xs font-medium text-[var(--color-text-tertiary)] uppercase tracking-wide">
                      Data to import
                    </span>
                    <div class="mt-2 space-y-2">
                      <label
                        :for={
                          {key, label} <- [
                            {"pets", "Pets"},
                            {"calls", "Calls"},
                            {"activities", "Activities"},
                            {"gifts", "Gifts"},
                            {"debts", "Debts"},
                            {"tasks", "Tasks"},
                            {"reminders", "Reminders"},
                            {"conversations", "Conversations"},
                            {"documents", "Documents (async)"}
                          ]
                        }
                        class="flex items-center gap-2 cursor-pointer"
                      >
                        <input
                          type="checkbox"
                          checked={@api_options[key] != false}
                          phx-click="toggle_option"
                          phx-value-option={key}
                          class="rounded border-[var(--color-border)]"
                        />
                        <span class="text-sm text-[var(--color-text-primary)]">{label}</span>
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Error display --%>
            <p :if={@error} class="mb-4 text-sm text-[var(--color-error)]">{@error}</p>

            <UI.button type="submit" size="sm">
              Continue
            </UI.button>
          </form>
        </div>

        <%!-- Step 2: Confirmation --%>
        <div :if={@step == :confirm} class="mt-6">
          <div class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6 mb-4">
            <h3 class="text-base font-semibold text-[var(--color-text-primary)] mb-4">
              Review import settings
            </h3>

            <dl class="space-y-3 text-sm">
              <div class="flex justify-between">
                <dt class="text-[var(--color-text-secondary)]">Source</dt>
                <dd class="font-medium text-[var(--color-text-primary)]">
                  {source_label(@source)}
                </dd>
              </div>

              <div :if={@uploads.import_file.entries != []} class="flex justify-between">
                <dt class="text-[var(--color-text-secondary)]">File</dt>
                <dd class="font-medium text-[var(--color-text-primary)]">
                  {List.first(@uploads.import_file.entries).client_name}
                </dd>
              </div>

              <div
                :if={@source == "monica_api" && String.trim(@api_url) != ""}
                class="flex justify-between"
              >
                <dt class="text-[var(--color-text-secondary)]">Monica URL</dt>
                <dd class="font-medium text-[var(--color-text-primary)] truncate max-w-xs">
                  {@api_url}
                </dd>
              </div>

              <div
                :if={@source == "monica_api" && String.trim(@api_url) != ""}
                class="flex justify-between"
              >
                <dt class="text-[var(--color-text-secondary)]">Options</dt>
                <dd class="font-medium text-[var(--color-text-primary)]">
                  {api_sync_description(@api_options)}
                </dd>
              </div>
            </dl>
          </div>

          <div class="bg-[var(--color-warning-subtle)] border border-[var(--color-warning)]/30 rounded-[var(--radius-lg)] p-4 mb-6">
            <p class="text-[var(--color-warning)] font-medium text-sm">Before you import</p>
            <p class="text-[var(--color-text-secondary)] text-sm mt-1">
              Import creates new contacts. Existing contacts are not updated.
              Review for duplicates after import.
            </p>
          </div>

          <%!-- Error display --%>
          <p :if={@error} class="mb-4 text-sm text-[var(--color-error)]">{@error}</p>

          <div class="flex gap-3">
            <UI.button variant="secondary" size="sm" phx-click="back_to_source">
              Back
            </UI.button>
            <UI.button size="sm" phx-click="start_import">
              Start import
            </UI.button>
          </div>
        </div>

        <%!-- Step 3: Progress --%>
        <div :if={@step == :progress} class="mt-6">
          <div class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <p class="text-[var(--color-text-secondary)] mb-4">
              Import in progress. This may take a few minutes depending on the size of your data.
            </p>

            <div :if={@progress && @progress.total > 0}>
              <div class="w-full bg-[var(--color-border)] rounded-full h-2 mb-2">
                <div
                  class="bg-[var(--color-accent)] h-2 rounded-full transition-all duration-300"
                  style={"width: #{round(@progress.current / @progress.total * 100)}%"}
                >
                </div>
              </div>
              <p class="text-sm text-[var(--color-text-tertiary)]">
                {@progress.current} / {@progress.total} contacts
              </p>
            </div>

            <div :if={!@progress || @progress.total == 0} class="flex items-center gap-3">
              <div class="w-full bg-[var(--color-border)] rounded-full h-2">
                <div class="bg-[var(--color-accent)] h-2 rounded-full w-1/3 animate-pulse"></div>
              </div>
              <span class="text-sm text-[var(--color-text-tertiary)] shrink-0">Processing...</span>
            </div>
          </div>

          <div class="mt-4">
            <UI.button variant="secondary" size="sm" phx-click="cancel_import">
              Cancel import
            </UI.button>
          </div>
        </div>

        <%!-- Step 4: Complete --%>
        <div :if={@step == :complete} class="mt-6">
          <div class="bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h3 class="text-lg font-semibold mb-4">Import complete</h3>

            <div :if={@results} class="space-y-2">
              <p class="text-[var(--color-success)]">
                <span class="font-semibold">{@results["imported"] || @results[:imported] || 0}</span>
                contacts imported successfully
              </p>
              <p
                :if={(@results["skipped"] || @results[:skipped] || 0) > 0}
                class="text-[var(--color-warning)]"
              >
                <span class="font-semibold">{@results["skipped"] || @results[:skipped]}</span>
                entries skipped
              </p>
              <p
                :if={(@results["skipped_duplicates"] || @results[:skipped_duplicates] || 0) > 0}
                class="text-[var(--color-warning)] text-sm"
              >
                {@results["duplicate_message"] || @results[:duplicate_message]}
              </p>
              <p
                :if={(@results["merged"] || @results[:merged] || 0) > 0}
                class="text-[var(--color-accent)]"
              >
                <span class="font-semibold">{@results["merged"] || @results[:merged]}</span>
                duplicate contacts auto-merged
              </p>
            </div>

            <div
              :if={@results && (@results["errors"] || @results[:errors] || []) != []}
              class="mt-4"
            >
              <details class="text-sm">
                <summary class="cursor-pointer text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)]">
                  Show error details ({length(@results["errors"] || @results[:errors] || [])} errors)
                </summary>
                <ul class="mt-2 space-y-1 text-[var(--color-error)]">
                  <li :for={error <- @results["errors"] || @results[:errors] || []}>{error}</li>
                </ul>
              </details>
            </div>

            <div class="mt-6 flex gap-3">
              <.link
                navigate={~p"/contacts"}
                class="inline-flex items-center gap-2 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors"
              >
                View contacts
              </.link>
              <UI.button variant="secondary" size="sm" phx-click="restart">
                Import more
              </UI.button>
            </div>
          </div>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  # ── Private render helpers ──────────────────────────────────────────────────

  defp upload_error_message(:too_large), do: "File is too large (max 50 MB)"
  defp upload_error_message(:not_accepted), do: "Only .vcf and .json files are accepted"
  defp upload_error_message(:too_many_files), do: "Only one file at a time"
  defp upload_error_message(other), do: "Upload error: #{inspect(other)}"

  defp source_label("vcard"), do: "vCard (.vcf)"
  defp source_label("monica_api"), do: "Monica CRM (API)"
  defp source_label(other), do: other

  defp api_sync_description(options) do
    selected =
      options
      |> Enum.filter(fn {_k, v} -> v end)
      |> Enum.map(fn
        {"photos", _} -> "photos"
        {"extra_notes", _} -> "all notes"
        {k, _} -> k
      end)

    case selected do
      [] -> "None"
      list -> Enum.join(list, ", ")
    end
  end
end
