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

  # The value sections, keyed on the identifier the drop payload and the
  # summary both use. The display label is a rendering detail hanging off that
  # key, never the key itself: were `drop_key/1` to match on the label, a copy
  # edit or an i18n pass would make it return `nil` for everything, and every
  # unchecked value would silently come back on the survivor.
  @sections [
    {:contact_fields, "Fields"},
    {:addresses, "Addresses"},
    {:tags, "Tags"},
    {:aliases, "Aliases"}
  ]

  # The collapsible `<details>` blocks, whose open/closed state lives in
  # `@open_sections`. Distinct from `@sections` above, which names the
  # categories of droppable owned records. Listed so `toggle-section` has
  # something to validate its payload against.
  @toggle_sections ~w(identity contact_details history)a

  # Rendered instead of an attribution when every `first_met_through_id`
  # candidate was a member of this merge. `Merge.clear_member_self_reference/2`
  # coerces such a value to `:clear`, so offering it would be offering a value
  # the engine silently discards.
  @self_reference_note "a contact cannot be met through a record it just absorbed"

  # Read-only rows (design spec §3: resolved by policy, not by choice) and the
  # rule that produced each one.
  @policy_notes %{
    favorite: "favorite if any of these contacts is",
    is_archived: "archived only if every contact is archived",
    deceased: "deceased if any of these contacts is",
    deceased_at: "the earliest date among the deceased contacts"
  }

  # Postgres `bigint` upper bound. `Integer.parse/1` returns integers wider
  # than the column happily, and Postgrex then refuses to encode them —
  # `DBConnection.EncodeError`, which takes the LiveView process down. Ids
  # that arrive from the URL are the only ones that reach a query without
  # first being matched against something already on screen, so they are the
  # only ones that need this bound.
  @max_bigint 9_223_372_036_854_775_807

  # `?with=` is hand-editable. The legitimate producer is "Merge selected" on
  # the contacts index, where a realistic selection is a handful of contacts;
  # 50 is far above that and far below anything that would tie up a database
  # connection.
  @max_with_members 50

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :error, nil)}

  # A contact id from the URL, or `nil` if it could never name a row: not an
  # integer, or outside what the column can hold.
  defp parse_contact_id(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} when id > 0 and id <= @max_bigint -> id
      _ -> nil
    end
  end

  defp parse_contact_id(_raw), do: nil

  # Resolves a client-supplied id against records the socket already holds.
  #
  # Every id in an event payload here names something already on screen, so
  # none of them is ever parsed and handed to the database: LiveView payloads
  # are fully attacker-controlled (see the framework's security guide), and
  # matching on the rendered form means an unknown, malformed, or oversized id
  # simply finds nothing instead of reaching Postgrex.
  defp find_by_id(records, id) when is_binary(id) do
    Enum.find(records, &(to_string(&1.id) == id))
  end

  # A payload value that is not a string cannot name anything on screen —
  # every id is rendered as a string — so it finds nothing, exactly as an
  # unknown string id would.
  defp find_by_id(_records, _id), do: nil

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    scope = socket.assigns.current_scope

    # `id` comes straight from the URL and is not guaranteed numeric — a bad
    # value (e.g. "/contacts/duplicates/cluster/abc") must land on the same
    # "not found" redirect as an unknown id rather than raising. An id wider
    # than `bigint` is refused for the same reason: it parses, but Postgrex
    # then refuses to encode it.
    contact_id = parse_contact_id(id)

    cond do
      not Policy.can?(scope.user, :update, :contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to merge contacts")
         |> push_navigate(to: ~p"/contacts")}

      cluster = contact_id && DuplicateDetection.get_cluster(scope.account.id, contact_id) ->
        {:noreply,
         socket |> load_cluster(cluster, false) |> append_from_params(params, contact_id)}

      contact = contact_id && Contacts.get_contact(scope.account.id, contact_id) ->
        # Not a detected duplicate — the user came here to merge by hand.
        {:noreply,
         socket
         |> load_cluster(synthetic_cluster(contact), true)
         |> append_from_params(params, contact_id)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "No duplicate cluster found for that contact")
         |> push_navigate(to: ~p"/contacts")}
    end
  end

  # Extra members passed from the contacts list "Merge selected" action. Every
  # id is re-fetched through the account scope, so a hand-edited URL cannot
  # pull in another account's contact.
  defp append_from_params(socket, %{"with" => with_param}, lead_id) when is_binary(with_param) do
    account_id = socket.assigns.current_scope.account.id
    existing = MapSet.new(socket.assigns.members, & &1.id)

    requested =
      with_param
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn raw ->
        case parse_contact_id(raw) do
          nil -> []
          id -> [id]
        end
      end)
      |> Enum.uniq()
      |> Enum.take(@max_with_members)

    extra =
      requested
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> then(&Contacts.list_contacts_by_ids(account_id, &1))

    members = socket.assigns.members ++ extra

    # `members` and `selected_ids` part ways here. `load_cluster/3` seeds both
    # from the detected cluster, which is right when the cluster IS the
    # subject; but on this path the subject is the user's own selection, and
    # the lead id may happen to sit in an unrelated pending cluster. Those
    # cluster-mates stay on screen — they may well be duplicates — but
    # checking them would merge contacts the user never picked.
    selected =
      [lead_id | requested]
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(members, & &1.id))

    selected_members = Enum.filter(members, &MapSet.member?(selected, &1.id))

    socket
    |> assign(:members, members)
    |> assign(:selected_ids, selected)
    |> assign(:labels, Contacts.merge_association_labels(members))
    # The URL id leads only because `merge_selected_path/1` sorts the
    # selection — the user expressed no preference — so the survivor has to
    # be re-derived over every selected member, not just the one
    # `load_cluster/3` saw. Safe only here: this runs immediately after
    # `load_cluster/3`, so there is no "make primary" choice to clobber.
    |> assign(:primary_id, DuplicateDetection.default_primary(selected_members).id)
    |> recompute()
  end

  defp append_from_params(socket, _params, _lead_id), do: socket

  defp synthetic_cluster(contact) do
    %Kith.DuplicateDetection.Cluster{
      key: contact.id,
      contacts: [contact],
      pairs: [],
      max_score: 0.0,
      reasons: []
    }
  end

  defp load_cluster(socket, cluster, synthetic?) do
    members = cluster.contacts
    primary = DuplicateDetection.default_primary(members)

    socket
    |> assign(:page_title, "Merge duplicates")
    |> assign(:cluster, cluster)
    |> assign(:members, members)
    # Derived from `:members`, which changes only here, in `add-member`, and
    # in `append_from_params/3` — not on every toggle. Three queries, so it
    # does not belong in `recompute/1`.
    |> assign(:labels, Contacts.merge_association_labels(members))
    |> assign(:selected_ids, MapSet.new(members, & &1.id))
    |> assign(:primary_id, primary.id)
    |> assign(:overrides, %{})
    |> assign(:dropped, MapSet.new())
    |> assign(:error, nil)
    # `<details>` carrying an id but no `open` attribute loses a user-set
    # `open` on every morphdom patch, and contact details is the only place
    # value pruning happens — unchecking N values would cost 2N clicks.
    # Tracked in assigns rather than fenced off with `phx-update="ignore"`,
    # which would also freeze the checkbox state inside these sections.
    |> assign(:open_sections, MapSet.new())
    |> assign(:synthetic?, synthetic?)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
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
  def handle_event("search", %{"query" => query}, socket) do
    results =
      if is_binary(query) and String.length(query) >= 2 do
        current = MapSet.new(socket.assigns.members, & &1.id)

        socket.assigns.current_scope.account.id
        # Capped in the database — this runs on every debounced keystroke and
        # the unbounded query scans five columns plus a `contact_fields` join.
        # The headroom is the current members, all of which are rejected
        # below, so a full page of results can never come back short. Tags are
        # not rendered here and `add-member` re-fetches by id, so skip them.
        |> Contacts.search_contacts(query,
          limit: 8 + MapSet.size(current),
          preload_tags: false
        )
        |> Enum.reject(&MapSet.member?(current, &1.id))
        |> Enum.take(8)
      else
        []
      end

    query = if is_binary(query), do: query, else: ""

    {:noreply, socket |> assign(:search_query, query) |> assign(:search_results, results)}
  end

  def handle_event("add-member", %{"id" => id}, socket) do
    existing = MapSet.new(socket.assigns.members, & &1.id)

    # The id is client-supplied, so it is parsed rather than cast, and an id
    # already in the strip is ignored: `selected_members/1` filters `:members`,
    # so a repeat would reach the resolution and the summary twice and make the
    # chip strip, the button count and the trash line disagree.
    with {id, ""} <- Integer.parse(id),
         false <- MapSet.member?(existing, id),
         contact when not is_nil(contact) <-
           Contacts.get_contact(socket.assigns.current_scope.account.id, id) do
      # An added member is indistinguishable from a detected one from here
      # on; the engine does not care how it got into the strip. Discarding
      # overrides/dropped mirrors "toggle-member": the selection changed, so
      # every derived value is stale.
      members = socket.assigns.members ++ [contact]

      {:noreply,
       socket
       |> assign(:members, members)
       |> assign(:labels, Contacts.merge_association_labels(members))
       |> assign(:selected_ids, MapSet.put(socket.assigns.selected_ids, contact.id))
       |> assign(:overrides, %{})
       |> assign(:dropped, MapSet.new())
       |> assign(:search_query, "")
       |> assign(:search_results, [])
       |> recompute()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle-member", %{"id" => id}, socket) do
    case cast_member_id(id) do
      {:ok, id} -> toggle_member(socket, id)
      :error -> {:noreply, socket}
    end
  end

  def handle_event("set-primary", %{"id" => id}, socket) do
    case cast_member_id(id) do
      {:ok, id} -> {:noreply, socket |> assign(:primary_id, id) |> recompute()}
      :error -> {:noreply, socket}
    end
  end

  # "Leave empty" posts the literal index "clear" (spec B7) rather than a
  # candidate position — route it to the override directly instead of
  # `String.to_integer/1`, which would raise on this value.
  def handle_event("choose-field", %{"field" => field, "index" => "clear"}, socket) do
    case cast_choice_field(field) do
      {:ok, field} ->
        {:noreply,
         socket
         |> assign(:overrides, Map.put(socket.assigns.overrides, field, :clear))
         |> assign(:error, nil)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("choose-field", %{"field" => field, "index" => index}, socket) do
    with {:ok, field} <- cast_choice_field(field),
         {:ok, index} <- cast_member_id(index) do
      choose_field(socket, field, index)
    else
      :error -> {:noreply, socket}
    end
  end

  # `:open_sections` (see `load_cluster/3`) is what survives a morphdom patch;
  # the browser toggles `<details>` on its own, so the client also
  # reports the toggle so the assign and the browser's own toggle agree.
  def handle_event("toggle-section", %{"section" => section}, socket) do
    case cast_section(section) do
      {:ok, section} -> {:noreply, assign(socket, :open_sections, toggled(socket, section))}
      :error -> {:noreply, socket}
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
    cond do
      not authorized?(socket) ->
        {:noreply, refuse(socket)}

      # The button carries `disabled` below two selected, but the event is
      # client-controlled and one member is now this screen's default landing
      # state — don't rely on the engine's `:no_losers` to catch it.
      MapSet.size(socket.assigns.selected_ids) < 2 ->
        {:noreply, assign(socket, :error, "Pick at least two contacts to merge.")}

      true ->
        run_merge(socket)
    end
  end

  # Ruling S7: `immich_status` is `null: false` with a check constraint
  # restricting it to "unlinked"/"needs_review"/"linked", so unlike the other
  # three (nullable) Immich fields it cannot be set to `:clear` — that maps
  # to `nil` in the engine and would raise a `Postgrex.Error`. This mirrors
  # `MergeResolution.resolve_immich/3`'s own handling of "no member linked".
  def handle_event("choose-immich", %{"id" => "none"}, socket) do
    overrides =
      MergeFields.immich_fields()
      |> Enum.reduce(socket.assigns.overrides, fn
        :immich_status, acc -> Map.put(acc, :immich_status, "unlinked")
        field, acc -> Map.put(acc, field, :clear)
      end)
      |> Map.put(:__immich__, :none)

    {:noreply, assign(socket, :overrides, overrides)}
  end

  def handle_event("choose-immich", %{"id" => id}, socket) do
    case cast_member_id(id) do
      {:ok, id} -> choose_immich(socket, id)
      :error -> {:noreply, socket}
    end
  end

  def handle_event("not-duplicates", _params, socket) do
    cond do
      # Never rendered for a hand-picked set (see the template), so a client
      # sending it anyway gets nothing rather than dismissed rows for pairs
      # detection never proposed.
      socket.assigns.synthetic? -> {:noreply, socket}
      authorized?(socket) -> dismiss_selection(socket)
      true -> {:noreply, refuse(socket)}
    end
  end

  defp toggle_member(socket, id) do
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

  defp choose_field(socket, field, index) do
    # Must resolve the clicked index the same way it was rendered — against
    # `visible_candidates/2` over the current selection, never against
    # `@resolution.conflicts[field]`, which is built by a different, unsorted
    # helper and could pick a different value than the button the user clicked.
    case Enum.at(visible_candidates(selected_members(socket), field), index) do
      nil ->
        {:noreply, socket}

      candidate ->
        {:noreply,
         socket
         |> assign(:overrides, Map.put(socket.assigns.overrides, field, candidate.value))
         |> assign(:error, nil)}
    end
  end

  defp choose_field_candidate(_socket, _field, _index), do: nil

  defp run_merge(socket) do
    survivor_id = socket.assigns.primary_id

    loser_ids =
      socket |> selected_members() |> Enum.map(& &1.id) |> Enum.reject(&(&1 == survivor_id))

    resolution = %{
      # `:__immich__` is UI bookkeeping, not a contact field, and MUST be
      # stripped here. `Merge.validate_fields/2` reduces over every entry in
      # `fields` and dispatches non-computed, non-`:clear` values to
      # `held_by_member?/3`, whose first act is `Map.fetch!(member, field)`
      # on a `Contact` struct — `:__immich__` is neither `:clear` nor a known
      # computed field, so leaving it in raises an unhandled `KeyError`
      # outside the engine's documented error contract, not a silently
      # dropped key.
      fields:
        socket.assigns.resolution.fields
        |> Map.merge(Map.delete(socket.assigns.overrides, :__immich__)),
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

  # Keyed on the section identifier the template renders as `phx-value-type`,
  # never on its display label — see `@sections`. Aliases deliberately fall
  # through: they are a whole-array field carried in `fields`, not a `drop`.
  defp drop_key("contact_fields"), do: :contact_fields
  defp drop_key("addresses"), do: :addresses
  defp drop_key("tags"), do: :tags
  defp drop_key(_type), do: nil

  # An alias has no backing row — the alias id *is* the string — so unchecking
  # one is a subtraction from the resolved array rather than a `drop` entry
  # (design spec §3).
  defp drop_aliases(resolution, dropped) do
    dropped_aliases = for {"aliases", value} <- dropped, do: value

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

  # `MergeSummary.build/1` gives contact_fields/addresses/tags entries an
  # integer row id, but alias entries are keyed by the alias string
  # itself (there is no per-row id to drop). Casting by the value's shape
  # rather than by category would corrupt a numeric-looking alias like
  # "007" — `Integer.parse/1` would turn it into `7`, which can never match
  # the `{"aliases", "007"}` key the render side looks up.
  defp cast_entry_id("aliases", id), do: id

  defp cast_entry_id(_type, id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  # ── Casting client-supplied event payloads ─────────────────────────────

  # `phx-value-*` is whatever the client sends, not whatever the template
  # rendered. Casting it with `String.to_existing_atom/1` alone is not enough:
  # it narrows the input to atoms this node has already created, and plenty of
  # those (`:page_title`, `:flash`, every other assign name) are not `Contact`
  # struct keys, so they reach `Map.fetch!/2` downstream and take the LiveView
  # process down with a `KeyError`. Each cast below therefore ends in a
  # membership check against the list the render side actually drew from, and
  # an unrecognised payload is dropped rather than raised on — matching how
  # `find_cluster/2` already treats an unparseable id in the URL.

  defp cast_choice_field(field) when is_binary(field) do
    cast_known_atom(field, MergeFields.choice_fields())
  end

  defp cast_choice_field(_field), do: :error

  defp cast_section(section) when is_binary(section) do
    cast_known_atom(section, @toggle_sections)
  end

  defp cast_section(_section), do: :error

  defp cast_known_atom(string, allowed) do
    atom = String.to_existing_atom(string)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    # No atom by this name exists, so it cannot be in `allowed` either.
    ArgumentError -> :error
  end

  # Also used for the candidate index in `choose-field`, which is a position in
  # a rendered list and so is bounded by the same non-negative-integer shape.
  defp cast_member_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp cast_member_id(_id), do: :error

  # ── Rendering helpers ──────────────────────────────────────────────────

  defp effective(assigns, field) do
    Map.get(assigns.overrides, field, Map.get(assigns.resolution.fields, field))
  end

  defp conflict?(assigns, field), do: Map.has_key?(assigns.resolution.conflicts, field)

  defp conflict_count(assigns) do
    Enum.count(MergeFields.choice_fields(), &conflict?(assigns, &1))
  end

  defp candidates(assigns, field) do
    visible_candidates(selected_from_assigns(assigns), field)
  end

  # Design spec §3 and the constraint slice 2 carried over from slice 1: never
  # offer a member's own id as a `first_met_through_id` value.
  # `Merge.clear_member_self_reference/2` coerces such a choice to `:clear`, so
  # the merge would succeed and the survivor's first-met-through would come
  # back empty with no error and nothing on screen having said why.
  defp visible_candidates(selected, :first_met_through_id) do
    member_ids = MapSet.new(selected, & &1.id)

    selected
    |> MergeResolution.candidates_for(:first_met_through_id)
    |> Enum.reject(&MapSet.member?(member_ids, &1.value))
  end

  defp visible_candidates(selected, field),
    do: MergeResolution.candidates_for(selected, field)

  defp selected_from_assigns(assigns) do
    Enum.filter(assigns.members, &MapSet.member?(assigns.selected_ids, &1.id))
  end

  # True when the only first-met-through values on offer were members of this
  # merge, so the row renders as cleared with the reason rather than as an
  # attribution for a value nobody can pick.
  defp self_reference_only?(assigns) do
    selected = selected_from_assigns(assigns)

    MergeResolution.candidates_for(selected, :first_met_through_id) != [] and
      visible_candidates(selected, :first_met_through_id) == []
  end

  defp attribution_text(assigns, :first_met_through_id = field) do
    if self_reference_only?(assigns),
      do: @self_reference_note,
      else: resolved_attribution(assigns, field)
  end

  defp attribution_text(assigns, field), do: resolved_attribution(assigns, field)

  defp resolved_attribution(assigns, field) do
    total = MapSet.size(assigns.selected_ids)

    case Map.get(assigns.resolution.attributions, field) do
      :all_agree -> "all #{total} agree"
      {:only, id} -> "only #{member_name(assigns, id)} has this"
      {:some, n} -> "#{n} of #{total}"
      _ -> nil
    end
  end

  defp policy_note(field), do: Map.fetch!(@policy_notes, field)

  defp sections, do: @sections

  defp member_name(assigns, id) do
    case Enum.find(assigns.members, &(&1.id == id)) do
      nil -> "unknown"
      contact -> contact.display_name
    end
  end

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_id", "") |> String.replace("_", " ")
  end

  # Design spec §3, "Association ids": the UI renders the associated record's
  # name. Without this a contested gender renders as a button reading "3".
  # An id with no row behind it (deleted between load and render) falls back
  # to the plain value rather than blanking the row.
  defp display(assigns, field, value)
       when field in [:gender_id, :currency_id, :first_met_through_id],
       do: assigns.labels |> Map.fetch!(field) |> Map.get(value) || display(value)

  defp display(_assigns, _field, value), do: display(value)

  defp display(nil), do: nil
  defp display(:clear), do: nil
  defp display(%Date{} = date), do: Date.to_iso8601(date)
  defp display(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp display(true), do: "Yes"
  defp display(false), do: "No"
  defp display(list) when is_list(list), do: Enum.join(list, ", ")
  defp display(value), do: to_string(value)

  defp linked_members(assigns) do
    assigns
    |> selected_from_assigns()
    |> Enum.filter(&(not is_nil(&1.immich_person_id)))
  end

  # Which member's Immich group is currently winning, so the row can highlight
  # it without exposing the opaque person id.
  defp immich_source_id(assigns) do
    case Map.get(assigns.overrides, :__immich__, :default) do
      :default ->
        chosen = Map.get(assigns.resolution.fields, :immich_person_id)

        case Enum.find(linked_members(assigns), &(&1.immich_person_id == chosen)) do
          nil -> :none
          member -> member.id
        end

      other ->
        other
    end
  end

  defp immich_sync_label(nil), do: "never synced"
  defp immich_sync_label(at), do: "synced #{Calendar.strftime(at, "%d %b %Y")}"

  # A hand-picked set was never "matched" on anything, and a detected cluster
  # loaded before this slice can still carry no reasons — either way the
  # "Matched on ." sentence would name nothing.
  defp matched_on?(assigns), do: not assigns.synthetic? and assigns.cluster.reasons != []

  # Nothing detection proposed is a "possible duplicate", and the manual path
  # routinely lands on a single member.
  defp member_count_label(assigns) do
    count = length(assigns.members)
    noun = if assigns.synthetic?, do: "contact", else: "possible duplicate"

    "#{count} #{noun}#{if count == 1, do: "", else: "s"}"
  end

  # `@cluster` never learns about members added by search or by `?with=`, so a
  # link built from its key would drop them all on the one error this link
  # exists for. Built from current state instead.
  defp reload_path(assigns) do
    others = assigns.members |> Enum.map(& &1.id) |> Enum.reject(&(&1 == assigns.primary_id))

    if others == [] do
      ~p"/contacts/duplicates/cluster/#{assigns.primary_id}"
    else
      ~p"/contacts/duplicates/cluster/#{assigns.primary_id}?#{[with: Enum.join(others, ",")]}"
    end
  end

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
          <.link navigate={reload_path(assigns)} class="underline ms-2">
            Reload
          </.link>
        </div>

        <UI.card>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <p class="font-semibold text-[var(--color-text-primary)]">
                {member_count_label(assigns)} · {MapSet.size(@selected_ids)} selected
              </p>
              <p :if={matched_on?(assigns)} class="text-sm text-[var(--color-text-tertiary)]">
                Matched on {Enum.join(@cluster.reasons, ", ")}. Uncheck anyone who isn't this person.
              </p>
              <p :if={not matched_on?(assigns)} class="text-sm text-[var(--color-text-tertiary)]">
                Pick the contacts to merge into one.
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

          <div class="mt-4 border-t border-[var(--color-border-subtle)] pt-4">
            <form phx-change="search" phx-submit="search">
              <label class="block text-xs text-[var(--color-text-tertiary)] mb-1.5">
                Add contact
              </label>
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search by name, email or phone…"
                phx-debounce="300"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm"
              />
            </form>

            <div
              :if={@search_results != []}
              class="mt-2 rounded-[var(--radius-md)] border border-[var(--color-border)] divide-y divide-[var(--color-border-subtle)]"
            >
              <button
                :for={result <- @search_results}
                type="button"
                phx-click="add-member"
                phx-value-id={result.id}
                class="w-full text-start px-3 py-2 text-sm hover:bg-[var(--color-surface-sunken)]"
              >
                {result.display_name}
              </button>
            </div>
          </div>
        </UI.card>

        <details
          id="section-identity"
          open={conflict_count(assigns) > 0 or MapSet.member?(@open_sections, :identity)}
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary
            phx-click="toggle-section"
            phx-value-section="identity"
            class="flex items-center justify-between p-4 cursor-pointer"
          >
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
            data-field={field}
            class={[
              "grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]",
              conflict?(assigns, field) && "bg-[var(--color-danger-subtle)]"
            ]}
          >
            <div class="text-sm text-[var(--color-text-secondary)] capitalize">
              {humanize(field)}
            </div>
            <%!--
              Spec B6: a resolved row is click-to-change too, opening in place as
              the same segmented control a contested row gets. The only rows
              without one are those no member holds a usable value for.
            --%>
            <div
              :if={candidates(assigns, field) != []}
              class="flex flex-wrap items-center gap-2"
            >
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
                {display(assigns, field, candidate.value)}
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
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {attribution_text(assigns, field)}
              </span>
            </div>

            <div
              :if={candidates(assigns, field) == []}
              class="flex items-center gap-3 text-sm"
            >
              <span class="italic text-[var(--color-text-disabled)]">
                Not set on any contact
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {attribution_text(assigns, field)}
              </span>
            </div>
          </div>
          <%!--
            Spec B1 requires every mergeable scalar on screen, the flags
            included. §3 resolves these by policy rather than by choice, so
            they state the outcome and the rule instead of offering a control.
          --%>
          <div
            :for={field <- MergeFields.policy_fields()}
            data-field={field}
            class="grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]"
          >
            <div class="text-sm text-[var(--color-text-secondary)] capitalize">
              {humanize(field)}
            </div>
            <div class="flex items-center gap-3 text-sm">
              <span :if={display(effective(assigns, field))}>
                {display(effective(assigns, field))}
              </span>
              <span
                :if={is_nil(display(effective(assigns, field)))}
                class="italic text-[var(--color-text-disabled)]"
              >
                Not set
              </span>
              <span class="text-xs text-[var(--color-text-tertiary)]">
                {policy_note(field)}
              </span>
            </div>
          </div>

          <div
            :if={linked_members(assigns) != []}
            class="grid grid-cols-[10rem_1fr] gap-4 items-center px-4 py-2.5 border-t border-[var(--color-border-subtle)]"
          >
            <div class="text-sm text-[var(--color-text-secondary)]">Photo library</div>
            <div class="flex flex-wrap items-center gap-2">
              <button
                :for={member <- linked_members(assigns)}
                type="button"
                phx-click="choose-immich"
                phx-value-id={member.id}
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm text-start",
                  if(immich_source_id(assigns) == member.id,
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                {member.display_name}
                <span class="block text-[10px] opacity-70">
                  {immich_sync_label(member.immich_last_synced_at)}
                </span>
              </button>
              <button
                type="button"
                phx-click="choose-immich"
                phx-value-id="none"
                class={[
                  "rounded-[var(--radius-md)] border px-3 py-1.5 text-sm",
                  if(immich_source_id(assigns) == :none,
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)]",
                    else: "border-[var(--color-border)]"
                  )
                ]}
              >
                Not linked
              </button>
            </div>
          </div>
        </details>

        <details
          id="section-contact-details"
          open={MapSet.member?(@open_sections, :contact_details)}
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary
            phx-click="toggle-section"
            phx-value-section="contact_details"
            class="flex items-center justify-between p-4 cursor-pointer"
          >
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
            :for={{key, label} <- sections()}
            data-field={key}
            class="px-4 py-3 border-t border-[var(--color-border-subtle)]"
          >
            <p class="text-sm text-[var(--color-text-secondary)] mb-2">{label}</p>
            <label
              :for={entry <- Map.fetch!(@summary, key)}
              class="flex items-center gap-2 text-sm py-0.5"
            >
              <input
                type="checkbox"
                disabled={entry.duplicate?}
                checked={
                  not entry.duplicate? and
                    not MapSet.member?(@dropped, {to_string(key), entry.id})
                }
                phx-click="toggle-value"
                phx-value-type={key}
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
            <p
              :if={Map.fetch!(@summary, key) == []}
              class="text-sm text-[var(--color-text-disabled)] italic"
            >
              None
            </p>
          </div>
        </details>

        <details
          id="section-history"
          open={MapSet.member?(@open_sections, :history)}
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]"
        >
          <summary
            phx-click="toggle-section"
            phx-value-section="history"
            class="flex items-center justify-between p-4 cursor-pointer"
          >
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
              <%!-- A hand-picked set was never proposed as duplicates, so there
                    is nothing to dismiss — marking it would insert dismissed
                    candidate rows for pairs detection never suggested and
                    permanently suppress real future matches. --%>
              <UI.button :if={@synthetic?} variant="secondary" navigate={~p"/contacts"}>
                Cancel
              </UI.button>
              <UI.button :if={not @synthetic?} variant="secondary" phx-click="not-duplicates">
                Not duplicates
              </UI.button>
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
