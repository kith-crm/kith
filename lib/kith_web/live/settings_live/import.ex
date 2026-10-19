defmodule KithWeb.SettingsLive.Import do
  use KithWeb, :live_view

  alias Kith.Policy
  alias Kith.VCard.Parser
  alias Kith.Workers.ImportWorker
  alias KithWeb.API.ContactImportController

  import KithWeb.SettingsLive.SettingsLayout

  @max_file_size 10 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import Contacts")
     |> assign(:uploaded_files, [])
     |> assign(:importing, false)
     |> assign(:results, nil)
     |> assign(:progress, nil)
     |> allow_upload(:vcf_file,
       accept: ~w(.vcf),
       max_file_size: @max_file_size,
       max_entries: 1
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    if Policy.can?(user, :create, :import) do
      # Subscribe to import progress for async imports
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

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("import", _params, socket) do
    scope = socket.assigns.current_scope
    account_id = scope.account.id

    socket = assign(socket, :importing, true)

    results =
      consume_uploaded_entries(socket, :vcf_file, fn %{path: path}, _entry ->
        {:ok, process_uploaded_vcf(path, account_id, scope.user.id)}
      end)

    handle_import_result(socket, List.first(results))
  end

  defp process_uploaded_vcf(path, account_id, user_id) do
    with {:ok, data} <- File.read(path),
         {:ok, parsed_contacts} <- Parser.parse(data) do
      import_parsed_contacts(account_id, user_id, data, parsed_contacts)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "Could not read uploaded file."}
    end
  end

  defp import_parsed_contacts(account_id, user_id, data, parsed_contacts) do
    if length(parsed_contacts) > 100 do
      %{account_id: account_id, user_id: user_id, file_data: data}
      |> ImportWorker.new()
      |> Oban.insert()

      {:async, length(parsed_contacts)}
    else
      result =
        ContactImportController.import_contacts_sync(account_id, parsed_contacts)

      {:sync, result}
    end
  end

  defp handle_import_result(socket, {:sync, result}) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:results, result)}
  end

  defp handle_import_result(socket, {:async, total}) do
    {:noreply,
     socket
     |> assign(:progress, %{current: 0, total: total})
     |> put_flash(:info, "Processing #{total} contacts... This may take a few minutes.")}
  end

  defp handle_import_result(socket, {:error, reason}) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> put_flash(:error, reason)}
  end

  defp handle_import_result(socket, _) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> put_flash(:error, "No file uploaded.")}
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info({:import_complete, results}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:progress, nil)
     |> assign(:results, results)}
  end

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
          <:subtitle>Import contacts from a vCard (.vcf) file</:subtitle>
        </UI.header>

        <%!-- Warning banner --%>
        <div class="mt-6 bg-[var(--color-warning-subtle)] border border-[var(--color-warning)]/30 rounded-[var(--radius-lg)] p-4">
          <p class="text-[var(--color-warning)] font-medium">Before you import</p>
          <p class="text-[var(--color-text-secondary)] text-sm mt-1">
            Import creates new contacts. Existing contacts are not updated.
            Review for duplicates after import.
          </p>
        </div>

        <%!-- Results --%>
        <div
          :if={@results}
          class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6"
        >
          <h3 class="text-lg font-semibold mb-3">Import Results</h3>

          <div class="space-y-2">
            <p class="text-[var(--color-success)]">
              <span class="font-semibold">{@results.imported}</span> contacts imported successfully
            </p>
            <p :if={@results.skipped > 0} class="text-[var(--color-warning)]">
              <span class="font-semibold">{@results.skipped}</span> entries skipped
            </p>
            <p :if={@results.skipped_duplicates > 0} class="text-[var(--color-warning)] text-sm">
              {@results.duplicate_message}
            </p>
          </div>

          <div :if={@results.errors != []} class="mt-4">
            <details class="text-sm">
              <summary class="cursor-pointer text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)]">
                Show error details ({length(@results.errors)} errors)
              </summary>
              <ul class="mt-2 space-y-1 text-[var(--color-error)]">
                <li :for={error <- @results.errors}>{error}</li>
              </ul>
            </details>
          </div>

          <div class="mt-4">
            <.link
              navigate={~p"/contacts"}
              class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] hover:underline text-sm"
            >
              View imported contacts
            </.link>
          </div>
        </div>

        <%!-- Progress --%>
        <div
          :if={@progress}
          class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6"
        >
          <p class="text-[var(--color-text-secondary)] mb-2">
            Processing import... This may take a few minutes.
          </p>
          <div class="w-full bg-[var(--color-border)] rounded-full h-2">
            <div
              class="bg-[var(--color-accent)] h-2 rounded-full transition-all duration-300"
              style={"width: #{if @progress.total > 0, do: round(@progress.current / @progress.total * 100), else: 0}%"}
            >
            </div>
          </div>
          <p class="text-sm text-[var(--color-text-tertiary)] mt-1">
            {@progress.current} / {@progress.total} contacts
          </p>
        </div>

        <%!-- Upload form --%>
        <div
          :if={!@results && !@progress}
          class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6"
        >
          <form id="import-form" phx-submit="import" phx-change="validate">
            <div
              class="border-2 border-dashed border-[var(--color-border)] rounded-[var(--radius-lg)] p-8 text-center hover:border-[var(--color-text-tertiary)] transition-colors"
              phx-drop-target={@uploads.vcf_file.ref}
            >
              <.live_file_input upload={@uploads.vcf_file} class="hidden" />
              <p class="text-[var(--color-text-tertiary)]">
                Drag and drop a <span class="font-semibold">.vcf</span>
                file here, or
                <label
                  for={@uploads.vcf_file.ref}
                  class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] hover:underline cursor-pointer"
                >
                  browse
                </label>
              </p>
              <p class="text-xs text-[var(--color-text-disabled)] mt-1">Maximum file size: 10 MB</p>
            </div>

            <%!-- Show selected file --%>
            <div
              :for={entry <- @uploads.vcf_file.entries}
              class="mt-4 flex items-center justify-between"
            >
              <span class="text-sm text-[var(--color-text-secondary)]">{entry.client_name}</span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {Float.round(entry.client_size / 1024, 1)} KB
              </span>
            </div>

            <%!-- Upload errors --%>
            <p
              :for={err <- upload_errors(@uploads.vcf_file)}
              class="mt-2 text-sm text-[var(--color-error)]"
            >
              {upload_error_message(err)}
            </p>

            <div class="mt-4">
              <UI.button
                type="submit"
                size="sm"
                disabled={@importing || @uploads.vcf_file.entries == []}
              >
                {if @importing, do: "Importing...", else: "Import Contacts"}
              </UI.button>
            </div>
          </form>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp upload_error_message(:too_large), do: "File is too large (max 10 MB)"
  defp upload_error_message(:not_accepted), do: "Only .vcf files are accepted"
  defp upload_error_message(:too_many_files), do: "Only one file at a time"
  defp upload_error_message(other), do: "Upload error: #{inspect(other)}"
end
