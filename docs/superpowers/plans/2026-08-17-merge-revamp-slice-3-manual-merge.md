# Merge Revamp — Slice 3: Manual Merge and Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user merge contacts detection never linked — by search from the cluster screen, or by selecting them on the contacts list — then delete the old wizard and the dead duplicates LiveView.

**Architecture:** The cluster screen already renders a member strip from a list of contacts. This slice makes that list come from three sources instead of one: a detected cluster, a bare contact id plus search, or a set of ids passed from the contacts index. The engine and resolver do not change — a manually added member is indistinguishable from a detected one once it is in the strip.

**Tech Stack:** Elixir, Ecto, Phoenix LiveView, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-17-duplicate-merge-revamp-design.md`

**Depends on:** slices 1 and 2 complete and merged.

## Global Constraints

- Account-scoped multitenancy: every lookup goes through `scope.account.id`.
- Never add `Co-Authored-By` lines to commits.
- Run `mix test` before every commit and ensure 0 failures.
- `mix format` after each task.
- Authorization uses `Kith.Policy.can?(user, :update, :contact)`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/kith_web/live/contact_live/cluster_merge.ex` (modify) | Accepts a bare contact id and an id list; adds the Add contact search. |
| `lib/kith_web/live/contact_live/index.ex` (modify) | Selection state and the Merge selected action. |
| `lib/kith_web/live/contact_live/index.html.heex` (modify) | Row checkboxes and the selection bar. |
| `lib/kith_web/live/contact_live/show.html.heex` (modify) | Merge link points at the cluster screen. |
| `lib/kith_web/router.ex` (modify) | Removes `/contacts/:id/merge`. |
| `lib/kith_web/live/contact_live/merge.ex` (delete) | The wizard. |
| `lib/kith_web/live/contact_live/duplicates.ex` (delete) | Dead since before this work — unrouted and unreferenced. |

---

### Task 1: A bare contact id opens a one-member screen

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Consumes: `DuplicateDetection.get_cluster/2`, `Contacts.get_contact/3`.
- Produces: `handle_params/3` falls back to a synthetic single-member cluster when the id belongs to no pending cluster. Adds `:synthetic?` to assigns.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "manual entry" do
    test "a contact in no cluster renders alone", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, _live, html} = live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}")

      assert html =~ "Dana"
      assert html =~ "Add contact"
      refute html =~ "Sarah"
    end

    test "merge is disabled until a second member is added", ctx do
      loner = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, live, _html} = live(ctx.conn, "/contacts/duplicates/cluster/#{loner.id}")

      assert has_element?(live, "button[phx-click='merge'][disabled]")
    end

    test "a contact id from another account is refused", ctx do
      other = AccountsFixtures.user_fixture()
      stranger = ContactsFixtures.contact_fixture(other.account_id, %{first_name: "Zed"})

      assert {:error, {:live_redirect, %{to: "/contacts"}}} =
               live(ctx.conn, "/contacts/duplicates/cluster/#{stranger.id}")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "manual entry"`
Expected: FAIL — the screen redirects to `/contacts` with "No duplicate cluster found".

- [ ] **Step 3: Write minimal implementation**

In `lib/kith_web/live/contact_live/cluster_merge.ex`, replace the `handle_params/3`
`cond` with:

```elixir
  def handle_params(%{"id" => id}, _uri, socket) do
    scope = socket.assigns.current_scope
    contact_id = String.to_integer(id)

    cond do
      not Policy.can?(scope.user, :update, :contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to merge contacts")
         |> push_navigate(to: ~p"/contacts")}

      cluster = DuplicateDetection.get_cluster(scope.account.id, contact_id) ->
        {:noreply, load_cluster(socket, cluster, false)}

      contact = Contacts.get_contact(scope.account.id, contact_id) ->
        # Not a detected duplicate — the user came here to merge by hand.
        {:noreply, load_cluster(socket, synthetic_cluster(contact), true)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "Contact not found")
         |> push_navigate(to: ~p"/contacts")}
    end
  end

  defp synthetic_cluster(contact) do
    %Kith.DuplicateDetection.Cluster{
      key: contact.id,
      contacts: [contact],
      pairs: [],
      max_score: 0.0,
      reasons: []
    }
  end
```

Change `load_cluster/2` to `load_cluster/3` and add the two new assigns:

```elixir
  defp load_cluster(socket, cluster, synthetic?) do
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
    |> assign(:synthetic?, synthetic?)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> recompute()
  end
```

In the member strip card, add the search affordance after the chips (Task 2
wires its events; rendering the input now satisfies the "Add contact" assertion):

```heex
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
```

Also guard `default_primary/1` and the footer against a one-member screen: the
footer's `MapSet.size(@selected_ids) - 1` reads "0 contact(s) move to trash",
which is correct, and the merge button is already disabled below two members.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): open the cluster screen for a contact with no cluster"
```

---

### Task 2: Adding a member by search

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Consumes: `Contacts.search_contacts/2`.
- Produces: `handle_event/3` clauses for `"search"` and `"add-member"`.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "add contact search" do
    test "searching lists matches excluding current members", ctx do
      ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana", last_name: "Reed"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = live |> form("form[phx-change='search']", %{query: "Dana"}) |> render_change()

      assert html =~ "Dana"
      refute html =~ ~s(phx-click="add-member" phx-value-id="#{ctx.a.id}")
    end

    test "adding a contact puts it in the strip, checked", ctx do
      dana = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dana"})

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live |> form("form[phx-change='search']", %{query: "Dana"}) |> render_change()

      html =
        live |> element("button[phx-click='add-member'][phx-value-id='#{dana.id}']")
        |> render_click()

      assert html =~ "Merge 3 contacts"
      assert has_element?(live, "input[phx-click='toggle-member'][phx-value-id='#{dana.id}']")
    end

    test "an added member contributes to conflicts", ctx do
      dana =
        ContactsFixtures.contact_fixture(ctx.account_id, %{
          first_name: "Sarah",
          last_name: "Kim",
          occupation: "Designer"
        })

      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      live |> form("form[phx-change='search']", %{query: "Sarah"}) |> render_change()

      html =
        live |> element("button[phx-click='add-member'][phx-value-id='#{dana.id}']")
        |> render_click()

      assert html =~ "Designer"
    end

    test "a short query returns nothing", ctx do
      {:ok, live, _html} = live(ctx.conn, cluster_path(ctx.a, ctx.b))

      html = live |> form("form[phx-change='search']", %{query: "D"}) |> render_change()

      refute html =~ "add-member"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "add contact search"`
Expected: FAIL — no `"search"` handler.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/kith_web/live/contact_live/cluster_merge.ex`:

```elixir
  def handle_event("search", %{"query" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        current = MapSet.new(socket.assigns.members, & &1.id)

        socket.assigns.current_scope.account.id
        |> Contacts.search_contacts(query)
        |> Enum.reject(&MapSet.member?(current, &1.id))
        |> Enum.take(8)
      else
        []
      end

    {:noreply, socket |> assign(:search_query, query) |> assign(:search_results, results)}
  end

  def handle_event("add-member", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Contacts.get_contact(socket.assigns.current_scope.account.id, id) do
      nil ->
        {:noreply, socket}

      contact ->
        # An added member is indistinguishable from a detected one from here on;
        # the engine does not care how it got into the strip.
        {:noreply,
         socket
         |> assign(:members, socket.assigns.members ++ [contact])
         |> assign(:selected_ids, MapSet.put(socket.assigns.selected_ids, contact.id))
         |> assign(:overrides, %{})
         |> assign(:dropped, MapSet.new())
         |> assign(:search_query, "")
         |> assign(:search_results, [])
         |> recompute()}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "feat(duplicates): add members to a merge by search"
```

---

### Task 3: Merging from the contacts list

**Files:**
- Modify: `lib/kith_web/live/contact_live/index.ex`
- Modify: `lib/kith_web/live/contact_live/index.html.heex`
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex`
- Modify: `lib/kith_web/router.ex`
- Test: `test/kith_web/live/contact_live/merge_selected_test.exs` (create)

**Interfaces:**
- Produces: the contacts index assigns `:selected_contact_ids` (MapSet) and handles `"toggle-select"` and `"clear-selection"`. "Merge selected" navigates to `/contacts/duplicates/cluster/:id?with=<comma-separated ids>`. `ClusterMerge.handle_params/3` reads `with` and appends those contacts as members.

This reuses the existing `:id` route rather than adding a second one, so every
entry point resolves through the same `handle_params/3`.

- [ ] **Step 1: Write the failing test**

Create `test/kith_web/live/contact_live/merge_selected_test.exs`:

```elixir
defmodule KithWeb.ContactLive.MergeSelectedTest do
  use KithWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()

    a = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Ann"})
    b = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Bea"})
    c = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Cal"})

    %{conn: log_in_user(conn, user), user: user, account_id: user.account_id, a: a, b: b, c: c}
  end

  test "selecting contacts reveals a merge action", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/contacts")

    html =
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{ctx.a.id}']")
      |> render_click()

    refute html =~ "Merge selected"

    html =
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{ctx.b.id}']")
      |> render_click()

    assert html =~ "Merge selected"
    assert html =~ "2 selected"
  end

  test "merge selected opens the cluster screen with those members", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/contacts")

    for contact <- [ctx.a, ctx.b, ctx.c] do
      live
      |> element("input[phx-click='toggle-select'][phx-value-id='#{contact.id}']")
      |> render_click()
    end

    assert {:error, {:live_redirect, %{to: path}}} =
             live |> element("a[data-role='merge-selected']") |> render_click()

    {:ok, _merge_live, html} = live(ctx.conn, path)

    assert html =~ "Merge 3 contacts"
    for name <- ~w(Ann Bea Cal), do: assert(html =~ name)
  end

  test "contacts from a URL are refused if they belong to another account", ctx do
    other = AccountsFixtures.user_fixture()
    stranger = ContactsFixtures.contact_fixture(other.account_id, %{first_name: "Zed"})

    {:ok, _live, html} =
      live(ctx.conn, "/contacts/duplicates/cluster/#{ctx.a.id}?with=#{stranger.id}")

    refute html =~ "Zed"
    assert html =~ "Ann"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/merge_selected_test.exs`
Expected: FAIL — no `toggle-select` handler on the index.

- [ ] **Step 3: Write minimal implementation**

In `lib/kith_web/live/contact_live/index.ex`, add to `mount/3`:

```elixir
     |> assign(:selected_contact_ids, MapSet.new())
```

and add these handlers:

```elixir
  def handle_event("toggle-select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected_contact_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected_contact_ids, selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, :selected_contact_ids, MapSet.new())}
  end
```

In `lib/kith_web/live/contact_live/index.html.heex`, add a checkbox to each
contact row in the `:index` listing (place it as the first child of the row
container):

```heex
              <input
                type="checkbox"
                checked={MapSet.member?(@selected_contact_ids, contact.id)}
                phx-click="toggle-select"
                phx-value-id={contact.id}
                class="me-3"
              />
```

And add the selection bar directly above the contact list:

```heex
    <div
      :if={@live_action == :index && MapSet.size(@selected_contact_ids) > 1}
      class="flex items-center justify-between gap-4 rounded-[var(--radius-lg)] border border-[var(--color-accent)] bg-[var(--color-accent-subtle)] px-4 py-3"
    >
      <span class="text-sm font-medium">
        {MapSet.size(@selected_contact_ids)} selected
      </span>
      <div class="flex items-center gap-2">
        <button
          phx-click="clear-selection"
          class="text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
        >
          Clear
        </button>
        <.link
          data-role="merge-selected"
          navigate={merge_selected_path(@selected_contact_ids)}
          class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-sm font-medium"
        >
          <.icon name="hero-arrows-right-left" class="size-4" /> Merge selected
        </.link>
      </div>
    </div>
```

Add the path helper to `lib/kith_web/live/contact_live/index.ex`:

```elixir
  defp merge_selected_path(selected_ids) do
    [first | rest] = Enum.sort(selected_ids)
    ~p"/contacts/duplicates/cluster/#{first}?#{[with: Enum.join(rest, ",")]}"
  end
```

In `lib/kith_web/live/contact_live/cluster_merge.ex`, accept the `with`
parameter. Change the `handle_params/3` head and add the appending step:

```elixir
  def handle_params(%{"id" => id} = params, _uri, socket) do
    scope = socket.assigns.current_scope
    contact_id = String.to_integer(id)

    cond do
      not Policy.can?(scope.user, :update, :contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to merge contacts")
         |> push_navigate(to: ~p"/contacts")}

      cluster = DuplicateDetection.get_cluster(scope.account.id, contact_id) ->
        {:noreply, socket |> load_cluster(cluster, false) |> append_from_params(params)}

      contact = Contacts.get_contact(scope.account.id, contact_id) ->
        {:noreply,
         socket |> load_cluster(synthetic_cluster(contact), true) |> append_from_params(params)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "Contact not found")
         |> push_navigate(to: ~p"/contacts")}
    end
  end

  # Extra members passed from the contacts list. Every id is re-fetched through
  # the account scope, so a hand-edited URL cannot pull in another account's
  # contact.
  defp append_from_params(socket, %{"with" => with_param}) when is_binary(with_param) do
    account_id = socket.assigns.current_scope.account.id
    existing = MapSet.new(socket.assigns.members, & &1.id)

    extra =
      with_param
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn raw ->
        case Integer.parse(raw) do
          {id, ""} -> [id]
          _ -> []
        end
      end)
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.map(&Contacts.get_contact(account_id, &1))
      |> Enum.reject(&is_nil/1)

    if extra == [] do
      socket
    else
      members = socket.assigns.members ++ extra

      socket
      |> assign(:members, members)
      |> assign(:selected_ids, MapSet.new(members, & &1.id))
      |> recompute()
    end
  end

  defp append_from_params(socket, _params), do: socket
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/kith_web/live/contact_live/merge_selected_test.exs`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
mix format
mix test
git add lib/kith_web/live/contact_live/index.ex lib/kith_web/live/contact_live/index.html.heex lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/merge_selected_test.exs
git commit -m "feat(contacts): merge selected contacts from the contacts list"
```

---

### Task 4: Delete the wizard and the dead LiveView

**Files:**
- Delete: `lib/kith_web/live/contact_live/merge.ex`
- Delete: `lib/kith_web/live/contact_live/duplicates.ex`
- Modify: `lib/kith_web/router.ex`
- Modify: `lib/kith_web/live/contact_live/show.html.heex`
- Modify: `lib/kith/contacts.ex`
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs`

**Interfaces:**
- Removes: the `/contacts/:id/merge` route, `KithWeb.ContactLive.Merge`, `KithWeb.ContactLive.Duplicates`. `Contacts.merge_contacts/3` stays — the REST API still uses it.

- [ ] **Step 1: Write the failing test**

Append to `test/kith_web/live/contact_live/cluster_merge_test.exs`:

```elixir
  describe "old routes" do
    test "the merge wizard route no longer exists", ctx do
      assert_raise Phoenix.Router.NoRouteError, fn ->
        get(ctx.conn, "/contacts/#{ctx.a.id}/merge")
      end
    end

    test "the contact page links to the cluster screen", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/contacts/#{ctx.a.id}")

      assert html =~ "/contacts/duplicates/cluster/#{ctx.a.id}"
      refute html =~ "/contacts/#{ctx.a.id}/merge"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/kith_web/live/contact_live/cluster_merge_test.exs -k "old routes"`
Expected: FAIL — the route still resolves and the show page still links to it.

- [ ] **Step 3: Write minimal implementation**

Remove the route from `lib/kith_web/router.ex`:

```elixir
      live "/contacts/:id/merge", ContactLive.Merge, :index
```

Delete both LiveViews:

```bash
git rm lib/kith_web/live/contact_live/merge.ex
git rm lib/kith_web/live/contact_live/duplicates.ex
```

In `lib/kith_web/live/contact_live/show.html.heex`, find the Merge link — it
points at `~p"/contacts/#{@contact.id}/merge"` — and change its target to:

```heex
~p"/contacts/duplicates/cluster/#{@contact.id}"
```

Search for any other reference before compiling:

```bash
grep -rn "ContactLive.Merge\|/merge\"" lib/ test/
```

Delete `test/kith_web/live/contact_live/merge_test.exs` if it exists — it tests
a removed module. Its behaviour is covered by
`cluster_merge_test.exs` and the slice 1 engine tests.

`Contacts.merge_contacts/3` is **not** removed: `contact_controller.ex` still
calls it for `POST /api/contacts/merge`, which keeps its documented request
shape. Confirm with:

```bash
grep -rn "merge_contacts" lib/
```

Expect exactly two hits — the definition in `contacts.ex` and the API
controller.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test`
Expected: PASS across the suite, with no compile warnings about undefined
modules.

- [ ] **Step 5: Commit**

```bash
mix format
mix compile --warnings-as-errors
mix credo --strict
mix test
git add -A lib/ test/
git commit -m "refactor(duplicates): remove the merge wizard and dead duplicates live view"
```

---

## Slice 3 completion checklist

- [ ] `mix precommit` passes.
- [ ] Spec scenarios covered: E1–E4.
- [ ] E4 (merging past a dismissal) is exercised end to end: dismiss two contacts
      as not duplicates, then select both on the contacts list and merge. The
      merge must succeed and the dismissed pair must end as `merged` — this is
      the recovery path that replaces a dismissed-candidates view, so verify it
      by hand as well as in tests.
- [ ] `grep -rn "ContactLive.Merge\|ContactLive.Duplicates" lib/ test/` returns
      nothing.

## Whole-feature verification

After all three slices, walk the spec's §8 scenarios against the running app:

- [ ] A four-member cluster appears as one entry and merges in one action.
- [ ] Unchecking one member and merging leaves the other pending pairs alone, and
      the unchecked member does not come back.
- [ ] A five-member cluster holding two people resolves in two passes.
- [ ] `POST /api/contacts/merge` still works and now writes an audit entry.
- [ ] A `viewer` is refused the cluster screen.
