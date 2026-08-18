defmodule KithWeb.ContactLive.ClusterMerge do
  @moduledoc """
  Reviews and merges a cluster of duplicate contacts on one screen.

  All state is derived from the member selection: unchecking a member re-runs
  `MergeResolution` over the remaining members and discards any explicit field
  choices, so what is on screen is always a resolution of exactly the checked
  set.
  """

  use KithWeb, :live_view

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

  # Temporary — Task 7 adds the real event handlers (toggle-member, set-primary,
  # choose-field, toggle-value, not-duplicates, merge). Remove this clause then.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
              {MapSet.size(@selected_ids) - 1} contact(s) move to trash and stay recoverable for 30 days.
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
