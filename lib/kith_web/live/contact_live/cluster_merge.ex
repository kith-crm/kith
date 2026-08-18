defmodule KithWeb.ContactLive.ClusterMerge do
  @moduledoc """
  Reviews and merges a cluster of duplicate contacts on one screen.

  All state is derived from the member selection: unchecking a member re-runs
  `MergeResolution` over the remaining members and discards any explicit field
  choices, so what is on screen is always a resolution of exactly the checked
  set.
  """

  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.{MergeFields, MergeResolution, MergeSummary}
  alias Kith.DuplicateDetection
  alias Kith.Policy

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :error, nil)}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    scope = socket.assigns.current_scope

    cond do
      not Policy.can?(scope.user, :update, :contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to merge contacts")
         |> push_navigate(to: ~p"/contacts")}

      cluster = find_cluster(scope.account.id, id) ->
        {:noreply, load_cluster(socket, cluster)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "No duplicate cluster found for that contact")
         |> push_navigate(to: ~p"/contacts")}
    end
  end

  # `id` comes straight from the URL and is not guaranteed numeric — a bad
  # value (e.g. "/contacts/duplicates/cluster/abc") must land on the same
  # "no cluster found" redirect as an unknown id rather than raising.
  defp find_cluster(account_id, id) do
    case Integer.parse(id) do
      {contact_id, ""} -> DuplicateDetection.get_cluster(account_id, contact_id)
      _ -> nil
    end
  end

  defp load_cluster(socket, cluster) do
    members = cluster.contacts
    primary = DuplicateDetection.default_primary(members)

    socket
    |> assign(:page_title, "Merge duplicates")
    |> assign(:cluster, cluster)
    |> assign(:members, members)
    |> assign(:selected_ids, MapSet.new(members, & &1.id))
    |> assign(:primary_id, primary.id)
    |> assign(:overrides, %{})
    |> assign(:dropped, MapSet.new())
    |> assign(:error, nil)
    |> recompute()
  end

  # Everything downstream of the selection is derived, never patched in place.
  defp recompute(socket) do
    selected = selected_members(socket)
    primary_id = ensure_primary(socket, selected)

    socket
    |> assign(:primary_id, primary_id)
    |> assign(:resolution, MergeResolution.resolve(selected, primary_id))
    |> assign(:summary, MergeSummary.build(selected))
    # A merge error describes the resolution that was submitted. Anything that
    # changes the resolution makes it stale, so it never outlives one.
    |> assign(:error, nil)
  end

  defp selected_members(socket) do
    Enum.filter(socket.assigns.members, &MapSet.member?(socket.assigns.selected_ids, &1.id))
  end

  defp ensure_primary(socket, selected) do
    if Enum.any?(selected, &(&1.id == socket.assigns.primary_id)) do
      socket.assigns.primary_id
    else
      case selected do
        [] -> nil
        members -> DuplicateDetection.default_primary(members).id
      end
    end
  end

  @impl true
  def handle_event("toggle-member", %{"id" => id}, socket) do
    id = String.to_integer(id)

    selected =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    if MapSet.size(selected) == 0 do
      # `MergeResolution.resolve/2` requires a non-empty member list, and there
      # is no meaningful "merge nothing" state to render — refuse to uncheck
      # the last remaining member instead of leaving a selection that would
      # crash the next recompute. Re-assigning an equal `selected_ids` would
      # not itself produce a diff (`assign/3` skips equal values), which would
      # leave the browser's checkbox showing unchecked while the server still
      # holds that member selected — flash a notice so a patch is always sent.
      {:noreply, put_flash(socket, :info, "At least one contact must stay selected")}
    else
      {:noreply,
       socket
       |> clear_flash(:info)
       |> assign(:selected_ids, selected)
       # Selection changed, so every derived value is stale — including choices
       # the user made, which may no longer be held by any selected member.
       |> assign(:overrides, %{})
       |> assign(:dropped, MapSet.new())
       |> recompute()}
    end
  end

  def handle_event("set-primary", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:primary_id, String.to_integer(id)) |> recompute()}
  end

  # "Leave empty" posts the literal index "clear" (spec B7) rather than a
  # candidate position — route it to the override directly instead of
  # `String.to_integer/1`, which would raise on this value.
  def handle_event("choose-field", %{"field" => field, "index" => "clear"}, socket) do
    field = String.to_existing_atom(field)

    {:noreply,
     socket
     |> assign(:overrides, Map.put(socket.assigns.overrides, field, :clear))
     |> assign(:error, nil)}
  end

  def handle_event("choose-field", %{"field" => field, "index" => index}, socket) do
    field = String.to_existing_atom(field)
    index = String.to_integer(index)

    # Must resolve the clicked index the same way it was rendered — against
    # `candidates_for/2` over the current selection, never against
    # `@resolution.conflicts[field]`, which is built by a different, unsorted
    # helper and could pick a different value than the button the user clicked.
    case Enum.at(MergeResolution.candidates_for(selected_members(socket), field), index) do
      nil ->
        {:noreply, socket}

      candidate ->
        {:noreply,
         socket
         |> assign(:overrides, Map.put(socket.assigns.overrides, field, candidate.value))
         |> assign(:error, nil)}
    end
  end

  def handle_event("toggle-value", %{"type" => type, "id" => id}, socket) do
    key = {type, cast_entry_id(type, id)}

    dropped =
      if MapSet.member?(socket.assigns.dropped, key) do
        MapSet.delete(socket.assigns.dropped, key)
      else
        MapSet.put(socket.assigns.dropped, key)
      end

    {:noreply, socket |> assign(:dropped, dropped) |> assign(:error, nil)}
  end

  def handle_event("merge", _params, socket) do
    survivor_id = socket.assigns.primary_id

    loser_ids =
      socket |> selected_members() |> Enum.map(& &1.id) |> Enum.reject(&(&1 == survivor_id))

    resolution = %{
      fields: Map.merge(socket.assigns.resolution.fields, socket.assigns.overrides),
      drop: build_drop(socket),
      # Every member the screen showed but the user excluded, so the engine can
      # dismiss exactly the pairs the user reviewed and rejected. Leaving these
      # out would leave those pairs `pending` and they would be suggested again.
      unchecked_ids: unchecked_ids(socket)
    }

    resolution = drop_aliases(resolution, socket.assigns.dropped)

    case Contacts.merge_cluster(socket.assigns.current_scope, survivor_id, loser_ids, resolution) do
      {:ok, survivor} ->
        {:noreply,
         socket
         |> put_flash(:info, "Merged #{length(loser_ids) + 1} contacts")
         |> redirect(to: ~p"/contacts/#{survivor.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("not-duplicates", _params, socket) do
    DuplicateDetection.dismiss_selection(
      socket.assigns.current_scope.account.id,
      MapSet.to_list(socket.assigns.selected_ids),
      unchecked_ids(socket)
    )

    {:noreply,
     socket
     |> put_flash(:info, "Marked as not duplicates")
     |> redirect(to: ~p"/contacts/duplicates")}
  end

  defp unchecked_ids(socket) do
    socket.assigns.members
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(socket.assigns.selected_ids, &1))
  end

  # The screen groups dropped values by its own section labels; the engine wants
  # them keyed by entity type. Aliases are deliberately absent: they are a
  # whole-array field carried in `fields`, with no row to drop.
  defp build_drop(socket) do
    socket.assigns.dropped
    |> Enum.reduce(%{}, fn {label, id}, acc ->
      case drop_key(label) do
        nil ->
          acc

        key ->
          ids = equivalent_ids(socket, key, id)
          Map.update(acc, key, ids, &(ids ++ &1))
      end
    end)
    |> Map.new(fn {key, ids} -> {key, Enum.uniq(ids)} end)
  end

  # `Kith.Contacts.Merge`'s contract: its `:dedupe_owned` step collapses equal
  # rows *before* `:apply_drop` runs, keeping whichever row has the lower id.
  # Naming only the row the user clicked would therefore leave its equivalent
  # standing on the survivor and the excluded value would come back. Each
  # `MergeSummary` entry carries the dedupe-equivalence `key` for exactly this:
  # expand a dropped entry to every entry sharing its key.
  defp equivalent_ids(socket, section, id) do
    entries = Map.fetch!(socket.assigns.summary, section)

    case Enum.find(entries, &(&1.id == id)) do
      nil -> [id]
      entry -> for other <- entries, other.key == entry.key, do: other.id
    end
  end

  defp drop_key("Fields"), do: :contact_fields
  defp drop_key("Addresses"), do: :addresses
  defp drop_key("Tags"), do: :tags
  defp drop_key(_label), do: nil

  # An alias has no backing row — the alias id *is* the string — so unchecking
  # one is a subtraction from the resolved array rather than a `drop` entry
  # (design spec §3).
  defp drop_aliases(resolution, dropped) do
    dropped_aliases = for {"Aliases", value} <- dropped, do: value

    case resolution.fields do
      %{aliases: list} when is_list(list) and dropped_aliases != [] ->
        put_in(resolution.fields[:aliases], list -- dropped_aliases)

      _fields ->
        resolution
    end
  end

  defp error_message(reason) when reason in [:not_found, :trashed],
    do: "One of these contacts changed since you opened this page."

  defp error_message({:unknown_value, field}),
    do: "The #{humanize(field)} you picked changed since you opened this page."

  defp error_message({:not_clearable, field}),
    do: "#{String.capitalize(humanize(field))} can't be left empty."

  defp error_message({:unknown_drop, _key}),
    do: "One of the values you unchecked changed since you opened this page."

  defp error_message({:invalid_fields, _changeset}),
    do: "The values you picked can't be saved to one contact."

  # `:different_accounts`, `:survivor_in_losers`, `:no_losers` and anything the
  # engine grows later. None is reachable from this screen's own UI, and a raw
  # reason tuple on the page reads as a crash — say something true instead.
  defp error_message(_reason),
    do: "This merge couldn't be completed. Reload the page and try again."

  # `MergeSummary.build/1` gives "Fields"/"Addresses"/"Tags" entries an
  # integer row id, but "Aliases" entries are keyed by the alias string
  # itself (there is no per-row id to drop). Casting by the value's shape
  # rather than by category would corrupt a numeric-looking alias like
  # "007" — `Integer.parse/1` would turn it into `7`, which can never match
  # the `{"Aliases", "007"}` key the render side looks up.
  defp cast_entry_id("Aliases", id), do: id

  defp cast_entry_id(_type, id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  # ── Rendering helpers ──────────────────────────────────────────────────

  defp effective(assigns, field) do
    Map.get(assigns.overrides, field, Map.get(assigns.resolution.fields, field))
  end

  defp conflict?(assigns, field), do: Map.has_key?(assigns.resolution.conflicts, field)

  defp conflict_count(assigns) do
    Enum.count(MergeFields.choice_fields(), &conflict?(assigns, &1))
  end

  defp candidates(assigns, field) do
    MergeResolution.candidates_for(selected_from_assigns(assigns), field)
  end

  defp selected_from_assigns(assigns) do
    Enum.filter(assigns.members, &MapSet.member?(assigns.selected_ids, &1.id))
  end

  defp attribution_text(assigns, field) do
    total = MapSet.size(assigns.selected_ids)

    case Map.get(assigns.resolution.attributions, field) do
      :all_agree -> "all #{total} agree"
      {:only, id} -> "only #{member_name(assigns, id)} has this"
      {:some, n} -> "#{n} of #{total}"
      _ -> nil
    end
  end

  defp member_name(assigns, id) do
    case Enum.find(assigns.members, &(&1.id == id)) do
      nil -> "unknown"
      contact -> contact.display_name
    end
  end

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_id", "") |> String.replace("_", " ")
  end

  defp display(nil), do: nil
  defp display(:clear), do: nil
  defp display(%Date{} = date), do: Date.to_iso8601(date)
  defp display(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp display(true), do: "Yes"
  defp display(false), do: "No"
  defp display(list) when is_list(list), do: Enum.join(list, ", ")
  defp display(value), do: to_string(value)

  defp trash_summary(assigns) do
    case MapSet.size(assigns.selected_ids) - 1 do
      n when n <= 0 -> "Nothing moves to trash."
      1 -> "1 contact moves to trash and stays recoverable for 30 days."
      n -> "#{n} contacts move to trash and stay recoverable for 30 days."
    end
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
      <div class="max-w-4xl mx-auto space-y-4">
        <div
          :if={@error}
          class="rounded-[var(--radius-md)] border-s-4 border-[var(--color-danger)] bg-[var(--color-danger-subtle)] p-3 text-sm"
        >
          {@error}
          <.link navigate={~p"/contacts/duplicates/cluster/#{@cluster.key}"} class="underline ms-2">
            Reload
          </.link>
        </div>

        <UI.card>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <p class="font-semibold text-[var(--color-text-primary)]">
                {length(@members)} possible duplicates · {MapSet.size(@selected_ids)} selected
              </p>
              <p class="text-sm text-[var(--color-text-tertiary)]">
                Matched on {Enum.join(@cluster.reasons, ", ")}. Uncheck anyone who isn't this person.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap gap-2 mt-4">
            <div :for={member <- @members} class="flex items-center gap-1">
              <label class={[
                "flex items-center gap-2 rounded-full border ps-2 pe-3 py-1.5 cursor-pointer transition-colors",
                if(member.id == @primary_id,
                  do: "border-[var(--color-accent)] bg-[var(--color-accent-subtle)]",
                  else: "border-[var(--color-border)]"
                ),
                not MapSet.member?(@selected_ids, member.id) && "opacity-50"
              ]}>
                <input
                  type="checkbox"
                  checked={MapSet.member?(@selected_ids, member.id)}
                  phx-click="toggle-member"
                  phx-value-id={member.id}
                />
                <KithUI.avatar name={member.display_name} src={avatar_url(member)} size={:sm} />
                <span class="text-sm">
                  {member.display_name}
                  <span :if={member.id == @primary_id} class="text-xs text-[var(--color-accent)] ms-1">
                    primary
                  </span>
                </span>
              </label>
              <button
                :if={member.id != @primary_id && MapSet.member?(@selected_ids, member.id)}
                type="button"
                phx-click="set-primary"
                phx-value-id={member.id}
                class="text-xs text-[var(--color-text-tertiary)] hover:text-[var(--color-accent)]"
              >
                make primary
              </button>
            </div>
          </div>
        </UI.card>

        <details
          id="section-identity"
          open={conflict_count(assigns) > 0}
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Identity</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {length(MergeFields.choice_fields())} fields · click any value to change it
              </span>
              <span
                :if={conflict_count(assigns) > 0}
                class="rounded-full bg-[var(--color-danger-subtle)] text-[var(--color-danger)] px-2 py-0.5 text-xs font-medium"
              >
                {conflict_count(assigns)} need{if conflict_count(assigns) == 1, do: "s"} a decision
              </span>
              <span
                :if={conflict_count(assigns) == 0}
                class="rounded-full bg-[var(--color-success-subtle)] text-[var(--color-success)] px-2 py-0.5 text-xs font-medium"
              >
                all resolved
              </span>
            </span>
          </summary>

          <div
            :for={field <- MergeFields.choice_fields()}
            class={[
              "grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]",
              conflict?(assigns, field) && "bg-[var(--color-danger-subtle)]"
            ]}
          >
            <div class="text-sm text-[var(--color-text-secondary)] capitalize">
              {humanize(field)}
            </div>

            <div :if={conflict?(assigns, field)} class="flex flex-wrap items-center gap-2">
              <button
                :for={{candidate, index} <- Enum.with_index(candidates(assigns, field))}
                type="button"
                phx-click="choose-field"
                phx-value-field={field}
                phx-value-index={index}
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm text-start",
                  if(effective(assigns, field) == candidate.value,
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                {display(candidate.value)}
                <span class="block text-[10px] opacity-70">{candidate.count} record(s)</span>
              </button>
              <button
                :if={not MergeFields.non_clearable?(field)}
                type="button"
                phx-click="choose-field"
                phx-value-field={field}
                phx-value-index="clear"
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm text-start italic",
                  if(effective(assigns, field) == :clear,
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)] text-[var(--color-text-tertiary)]"
                  )
                ]}
              >
                Leave empty
              </button>
            </div>

            <div :if={not conflict?(assigns, field)} class="flex items-center gap-3 text-sm">
              <span :if={display(effective(assigns, field))}>
                {display(effective(assigns, field))}
              </span>
              <span
                :if={is_nil(display(effective(assigns, field)))}
                class="italic text-[var(--color-text-disabled)]"
              >
                Not set on any contact
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {attribution_text(assigns, field)}
              </span>
            </div>
          </div>
        </details>

        <details
          id="section-contact-details"
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Contact details</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {length(@summary.contact_fields)} fields, {length(@summary.addresses)} addresses, {length(
                  @summary.tags
                )} tags combined
              </span>
            </span>
          </summary>

          <div
            :for={
              {label, entries} <- [
                {"Fields", @summary.contact_fields},
                {"Addresses", @summary.addresses},
                {"Tags", @summary.tags},
                {"Aliases", @summary.aliases}
              ]
            }
            class="px-4 py-3 border-t border-[var(--color-border-subtle)]"
          >
            <p class="text-sm text-[var(--color-text-secondary)] mb-2">{label}</p>
            <label :for={entry <- entries} class="flex items-center gap-2 text-sm py-0.5">
              <input
                type="checkbox"
                disabled={entry.duplicate?}
                checked={not entry.duplicate? and not MapSet.member?(@dropped, {label, entry.id})}
                phx-click="toggle-value"
                phx-value-type={label}
                phx-value-id={entry.id}
              />
              <span class={entry.duplicate? && "line-through text-[var(--color-text-disabled)]"}>
                {entry.value}
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {if entry.duplicate?,
                  do: "duplicate · dropped",
                  else: member_name(assigns, entry.owner_id)}
              </span>
            </label>
            <p :if={entries == []} class="text-sm text-[var(--color-text-disabled)] italic">None</p>
          </div>
        </details>

        <details
          id="section-history"
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary class="flex items-center justify-between p-4 cursor-pointer">
            <span class="flex items-baseline gap-3">
              <strong class="text-sm">Carried over as-is</strong>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {@summary.history |> Map.values() |> Enum.sum()} records move to the primary
              </span>
            </span>
          </summary>
          <div class="flex flex-wrap gap-2 p-4 border-t border-[var(--color-border-subtle)]">
            <span
              :for={{key, count} <- Enum.sort_by(@summary.history, &elem(&1, 0))}
              :if={count > 0}
              class="rounded-[var(--radius-sm)] border border-[var(--color-border-subtle)] bg-[var(--color-surface-sunken)] px-2.5 py-1 text-xs"
            >
              <strong>{count}</strong> {String.replace(to_string(key), "_", " ")}
            </span>
          </div>
        </details>

        <UI.card>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <p class="text-sm text-[var(--color-text-tertiary)] max-w-md">
              {trash_summary(assigns)}
              <span :if={MapSet.size(@selected_ids) < length(@members)}>
                Unchecked contacts will be marked as not duplicates and won't be suggested again.
              </span>
            </p>
            <div class="flex gap-2">
              <UI.button variant="secondary" phx-click="not-duplicates">Not duplicates</UI.button>
              <UI.button phx-click="merge" disabled={MapSet.size(@selected_ids) < 2}>
                Merge {MapSet.size(@selected_ids)} contacts
              </UI.button>
            </div>
          </div>
        </UI.card>
      </div>
    </Layouts.app>
    """
  end
end
