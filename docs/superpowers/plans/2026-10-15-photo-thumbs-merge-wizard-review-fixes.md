# Photo Thumbnails and Merge Wizard Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Parallel execution:** tasks are grouped into lanes (B-photo, B-wizard). Lanes run as separate agents in separate worktrees, in the waves defined by [the orchestration plan](2026-10-15-pr44-followups-orchestration.md). Read it first.

**Goal:** Land the PR #35/#36 review decisions on PR #44: stable hourly S3 signing, a one-shot image refresh with a hidden retry state, listener cleanup, logged CSP failures, avatar initials fallback with required ids, and a merge wizard whose back link, Cancel, tab and choice buttons say where they go and what is selected.

**Architecture:** Storage signing becomes deterministic per hour so LiveView diffs nothing and browsers cache. `ImgFallback` becomes a small state machine (`ok → retrying → failed`) that asks its stateful component for a fresh URL once and gives up when the URL didn't change. The merge wizard reads LiveView's `_live_referer` connect param once in `mount/3` and maps a whitelisted path to a back target.

**Tech Stack:** Elixir 1.19.5 / OTP 28.5, Phoenix LiveView 1.1.27, ExAws S3, vanilla JS hooks (esbuild), Playwright.

**Spec:** [`docs/superpowers/specs/2026-10-15-photo-thumbs-merge-wizard-review-fixes-design.md`](../specs/2026-10-15-photo-thumbs-merge-wizard-review-fixes-design.md). Decision ids B1–B12 below refer to it.

## Global Constraints

- Same toolchain, test DB, commit and push rules as the orchestration plan (0 failures before every commit, `mix format`, `mix credo --strict`, no attribution trailers, never force-push). In every command below, `$DB_PORT` and `$LANE` are your lane's values from the orchestration table (e.g. `export DB_PORT=5444 LANE=_bphoto`).
- Every test that sets S3 config with `Application.put_env` is `async: false` and restores the previous env in `on_exit`.
- Presigned URLs: `start_datetime` = start of the current UTC hour; default `expires_in: 7200` (B1).
- CSP log line, verbatim: `Failed to build S3 CSP img-src: <message>` (B5).
- Avatar ids, verbatim: `merge-member-avatar-<member id>` (chips) and `merge-avatar-choice-<index>` (choices) (B11).
- Avatar choice `aria-label`, verbatim format: `Photo N of M, from <holders>` (B10).
- Do not touch Immich code or `IMMICH_BASE_URL` handling (issue #41).

## Review Focus

1. **The refreshed URL is identical to the failed one** (a missing file, or an expiry inside the same signing hour) — with B1 there is no `src` change and no LiveView patch; the hook must still reach "failed" instead of sitting in "retrying". Pinned in Task B3 (`refresh_url` replies `%{changed: false}`).
2. **An `<img>` that fails before the hook mounts** (cached 404) — must still enter the retry/failed path. Pinned in Task B3 (hook test via Playwright in Task B7).
3. **An avatar with `src` rendered without an `id`** — must fail loudly in dev/test (ArgumentError), not silently drop the fallback. Pinned in Task B4.
4. **`_live_referer` pointing at `/contacts/<id>` of a contact in another account or a deleted id** — must fall back, never leak a name. Pinned in Task B5.
5. **`_live_referer` with a query string on `/contacts`** — the list's search/filter must survive the round trip. Pinned in Task B5.

---

## Lane B-photo (wave 1: B1–B3; wave 2: B4)

### Task B1: One `PhotoThumbComponent.render/1` (B6)

**Files:**
- Modify: `lib/kith_web/live/contact_live/photo_thumb_component.ex:44-101`
- Test: `test/kith_web/live/contact_live/activity_stream_component_test.exs` (existing, must stay green)

**Interfaces:**
- Produces: `render/1` + private `variant_classes(:tile | :timeline) :: %{root, box, syncing, gap, icon, badge_text}`. No markup change a test can see: the `<img>` class still starts with `size-[72px] rounded-lg object-cover` (timeline) / `w-full h-full object-cover` (tile).

- [ ] **Step 1: Run the existing tests to record the baseline**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/activity_stream_component_test.exs`
Expected: PASS.

- [ ] **Step 2: Replace both `render/1` clauses**

```elixir
  @impl true
  def render(assigns) do
    assigns = assign(assigns, :c, variant_classes(assigns.variant))

    ~H"""
    <div id={@id} phx-hook="ImgFallback" class={["group", @c.root]}>
      <div
        :if={@pending_sync}
        class={[
          @c.box,
          "bg-gradient-to-br from-stone-100 to-stone-200 flex-col items-center justify-center text-[var(--color-text-tertiary)]",
          @c.syncing,
          @c.gap
        ]}
      >
        <.icon name="hero-photo" class={@c.icon} />
        <span class="text-[10px]">Syncing…</span>
      </div>
      <img
        :if={!@pending_sync}
        data-fallback-img
        src={@url}
        alt={@alt}
        loading="lazy"
        class={[@c.box, "object-cover group-data-[img-failed]:hidden"]}
      />
      <div
        :if={!@pending_sync}
        class={[
          "hidden group-data-[img-failed]:flex",
          @c.box,
          "bg-amber-50 border border-amber-200 flex-col items-center justify-center text-amber-600",
          @c.gap
        ]}
      >
        <.icon name="hero-exclamation-triangle" class={@c.icon} />
        <span class={@c.badge_text}>Image unavailable</span>
      </div>
    </div>
    """
  end

  defp variant_classes(:tile),
    do: %{
      root: "w-full h-full",
      box: "w-full h-full",
      syncing: "flex",
      gap: "gap-1",
      icon: "size-6",
      badge_text: "text-[10px] font-medium"
    }

  defp variant_classes(:timeline),
    do: %{
      root: "mt-2 inline-block",
      box: "size-[72px] rounded-lg",
      syncing: "inline-flex",
      gap: "gap-0.5",
      icon: "size-5",
      badge_text: "text-[9px] font-medium leading-tight text-center"
    }
```

- [ ] **Step 3: Run the tests**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/activity_stream_component_test.exs`
Expected: PASS (same count as Step 1).

- [ ] **Step 4: Full suite, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/live/contact_live/photo_thumb_component.ex
git commit -m "refactor(contacts): one render for both photo thumbnail variants"
```

### Task B2: Stable hourly signing and logged CSP failures (B1, B5)

**Files:**
- Modify: `lib/kith/storage/s3.ex` (moduledoc, `@presign_expiry`, `presigned_url/2`, `csp_img_src/0`)
- Create: `test/kith/storage/s3_test.exs`, `test/kith_web/plugs/csp_test.exs`

**Interfaces:**
- Produces: `Kith.Storage.S3.presigned_url(key, opts)` accepts `:now` (`NaiveDateTime`, default `NaiveDateTime.utc_now()`) and `:expires_in` (default 7200); same key + same UTC hour → identical URL.

- [ ] **Step 1: Write the failing tests**

`test/kith/storage/s3_test.exs`:

```elixir
defmodule Kith.Storage.S3Test do
  # Global app env (S3 config): must not run alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kith.Storage.S3

  setup do
    saved = for key <- [{:kith, Kith.Storage}, {:ex_aws, :s3}, {:ex_aws, :access_key_id}, {:ex_aws, :secret_access_key}, {:ex_aws, :region}],
                do: {key, Application.fetch_env(elem(key, 0), elem(key, 1))}

    Application.put_env(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")
    Application.put_env(:ex_aws, :region, "us-east-1")
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)

    on_exit(fn ->
      for {{app, key}, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(app, key, v)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  describe "presigned_url/2" do
    test "is identical within one UTC hour and changes in the next" do
      a = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 10:05:00])
      b = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 10:59:59])
      c = S3.presigned_url("avatars/a.png", now: ~N[2026-10-15 11:00:00])

      assert a == b
      refute a == c
      assert a =~ "X-Amz-Date=20261015T100000Z"
      assert a =~ "X-Amz-Expires=7200"
    end
  end

  describe "csp_img_src/0" do
    test "scheme and host, default port omitted" do
      assert S3.csp_img_src() == "https://s3.example.com"
    end

    test "a custom port is kept" do
      Application.put_env(:ex_aws, :s3, scheme: "http://", host: "minio.local", port: 9000)
      assert S3.csp_img_src() == "http://minio.local:9000"
    end

    test "a config error returns an empty origin and logs" do
      # A non-keyword :s3 config makes ExAws.Config.new/1 raise. If this shape
      # stops raising on a future ExAws, pick another one that does.
      Application.put_env(:ex_aws, :s3, "not a keyword list")

      log = capture_log(fn -> assert S3.csp_img_src() == "" end)
      assert log =~ "Failed to build S3 CSP img-src:"
    end
  end
end
```

`test/kith_web/plugs/csp_test.exs`:

```elixir
defmodule KithWeb.Plugs.CSPTest do
  use KithWeb.ConnCase, async: false

  setup do
    saved = {Application.fetch_env(:kith, Kith.Storage), Application.fetch_env(:ex_aws, :s3)}
    Application.put_env(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)

    on_exit(fn ->
      {storage, s3} = saved
      for {app, key, v} <- [{:kith, Kith.Storage, storage}, {:ex_aws, :s3, s3}] do
        case v do
          {:ok, val} -> Application.put_env(app, key, val)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  test "img-src includes the S3 origin", %{conn: conn} do
    conn = KithWeb.Plugs.CSP.call(conn, KithWeb.Plugs.CSP.init([]))
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ ~r/img-src [^;]*https:\/\/s3\.example\.com/
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/storage/s3_test.exs test/kith_web/plugs/csp_test.exs`
Expected: FAIL (`a != b`; `X-Amz-Expires=3600`; no log line).

- [ ] **Step 3: Implement**

In `lib/kith/storage/s3.ex`:
- Change `@presign_expiry 3600` to `@presign_expiry 7200`.
- Moduledoc line "Generates presigned GET URLs with 1-hour expiry for secure file access." → "Generates presigned GET URLs signed from the start of the current UTC hour and valid for 2 hours, so a key has one URL per hour (LiveView diffs nothing, browsers cache) and every URL handed out stays valid for at least an hour."
- Replace `presigned_url/2` (doc + body):

```elixir
  @doc """
  Generates a presigned GET URL for an S3 object, signed from the start of the
  current UTC hour (`:now` overrides the clock) and valid for `:expires_in`
  seconds (default 7200). Same key, same hour → same URL.
  """
  def presigned_url(storage_key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, @presign_expiry)
    start = opts |> Keyword.get(:now, NaiveDateTime.utc_now()) |> hour_floor()

    config = ExAws.Config.new(:s3)

    case ExAws.S3.presigned_url(config, :get, bucket(), storage_key,
           expires_in: expires_in,
           start_datetime: start
         ) do
      {:ok, url} ->
        url

      {:error, reason} ->
        Logger.error("S3 presigned URL generation failed: #{inspect(reason)}")
        "#error"
    end
  end

  defp hour_floor(%NaiveDateTime{} = t), do: %{t | minute: 0, second: 0, microsecond: {0, 0}}
```

- Replace the `rescue` in `csp_img_src/0`:

```elixir
  rescue
    e ->
      Logger.error("Failed to build S3 CSP img-src: " <> Exception.message(e))
      ""
```

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith/storage/s3_test.exs test/kith_web/plugs/csp_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith/storage/s3.ex test/kith/storage/s3_test.exs test/kith_web/plugs/csp_test.exs
git commit -m "fix(storage): hourly-stable S3 presigned URLs; log CSP origin failures"
```

### Task B3: One-shot refresh and listener cleanup (B2, B3, B4)

**Files:**
- Modify: `assets/js/hooks/img_fallback.js` (whole file)
- Modify: `lib/kith_web/live/contact_live/photo_thumb_component.ex` (retrying placeholder, `data-refreshable`, `handle_event("refresh_url", …)`)
- Test: `test/kith_web/live/contact_live/activity_stream_component_test.exs`

**Interfaces:**
- Consumes: B1 (single render), B2 (stable signing — why the reply carries `changed`).
- Produces: hook root attributes `data-img-retrying` / `data-img-failed`; `data-refreshable="true"` opts a hook root into one `refresh_url` push; component replies `%{changed: boolean}`.

- [ ] **Step 1: Write the failing LiveView test**

In `activity_stream_component_test.exs`, reuse the file's existing photo setup (the test that asserts `phx-hook="ImgFallback"`), then add:

```elixir
  test "refresh_url re-signs and replies whether the URL changed", ctx do
    # `ctx.photo` / `ctx.conn` / `ctx.contact`: use the names from the file's setup.
    {:ok, view, _html} = live(ctx.conn, ~p"/contacts/#{ctx.contact.id}")

    view |> element("#photo-#{ctx.photo.id}") |> render_hook("refresh_url", %{})

    # Local storage: same key → same URL → nothing to retry.
    assert_reply(view, %{changed: false})
    assert has_element?(view, ~s(#photo-#{ctx.photo.id}[data-refreshable="true"]))
  end
```

(If the timeline and gallery both render the same photo id, target the one with `data-refreshable`; ids are `photo-<entry id>` per the component's caller.)

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/activity_stream_component_test.exs`
Expected: FAIL (no `handle_event/3` for `"refresh_url"`; no `data-refreshable`).

- [ ] **Step 3: Component changes**

In `photo_thumb_component.ex`:
- Root: `<div id={@id} phx-hook="ImgFallback" data-refreshable="true" class={["group", @c.root]}>`.
- `<img>` class: `[@c.box, "object-cover group-data-[img-failed]:hidden group-data-[img-retrying]:invisible"]`.
- Add after the `<img>` (neutral placeholder while retrying):

```heex
      <div
        :if={!@pending_sync}
        class={[
          "hidden group-data-[img-retrying]:flex absolute inset-0",
          @c.box,
          "bg-gradient-to-br from-stone-100 to-stone-200"
        ]}
      />
```

  and add `relative` to the root classes: `class={["group relative", @c.root]}`.
- Add the handler:

```elixir
  # One-shot refresh from ImgFallback after a load error (design B2). The reply
  # tells the hook whether a new URL is coming; with hourly-stable signing an
  # unchanged URL means retrying is pointless, so the hook shows "unavailable".
  @impl true
  def handle_event("refresh_url", _params, socket) do
    url = Storage.url(socket.assigns.storage_key)
    {:reply, %{changed: url != socket.assigns.url}, assign(socket, :url, url)}
  end
```

- Update the moduledoc's state list: add `` * `:retrying` — the first load failed; a fresh URL was requested once (neutral placeholder, the broken `<img>` hidden) ``.

- [ ] **Step 4: Rewrite the hook**

`assets/js/hooks/img_fallback.js`:

```js
// Image load-failure handling for <img data-fallback-img> inside the hook root.
//
// CSP here is `script-src 'self' 'nonce-...'` with no `unsafe-inline`, so an
// inline `onerror=""` attribute is blocked -- this hook is the CSP-safe path.
//
// State machine (design B2/B3): "ok" -> first error -> "retrying" (only when
// the root has data-refreshable="true": ask the component for a fresh URL
// once) -> a second error, or a reply saying the URL did not change ->
// "failed". A load at any point -> "ok". The state lives here and is
// re-applied on every LiveView patch, never re-derived from naturalWidth.
// It is exposed as data-img-retrying / data-img-failed on the root; Tailwind
// group-data-[...] variants in the markup do the show/hide.
const ImgFallback = {
  mounted() {
    this.state = "ok"
    this.bind()
  },

  updated() {
    this.bind()
    this.apply()
  },

  destroyed() {
    this.unbind()
  },

  // (Re)bind to the current <img>. A patch can replace the node (e.g. the
  // syncing placeholder turns into the image); listeners on the old node are
  // removed so a late error from it cannot fail the new one (design B4).
  bind() {
    const img = this.el.querySelector("img[data-fallback-img]")
    if (img === this.img) return

    this.unbind()
    this.img = img
    this.state = "ok"
    this.apply()
    if (!img) return

    this.onError = () => this.handleError()
    this.onLoad = () => this.setState("ok")
    img.addEventListener("error", this.onError)
    img.addEventListener("load", this.onLoad)

    // Failed before we were listening (cached 404).
    if (img.complete && img.naturalWidth === 0 && img.getAttribute("src")) this.handleError()
  },

  unbind() {
    if (!this.img) return
    this.img.removeEventListener("error", this.onError)
    this.img.removeEventListener("load", this.onLoad)
    this.img = null
  },

  handleError() {
    if (this.state === "ok" && this.el.dataset.refreshable === "true") {
      this.setState("retrying")
      this.pushEventTo(this.el, "refresh_url", {}, (reply) => {
        if (!reply || !reply.changed) this.setState("failed")
      })
    } else {
      this.setState("failed")
    }
  },

  setState(state) {
    this.state = state
    this.apply()
  },

  apply() {
    this.el.toggleAttribute("data-img-retrying", this.state === "retrying")
    this.el.toggleAttribute("data-img-failed", this.state === "failed")
  },
}

export default ImgFallback
```

(Keep the existing export form; check the old file's last line and match it.)

- [ ] **Step 5: Build assets and run tests**

```bash
mix assets.build
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/activity_stream_component_test.exs
```

Expected: assets build cleanly (copy `assets/vendor/heroicons.js` from the main checkout first if the worktree lacks it — it is gitignored); tests PASS. Browser behaviour (retry once, hidden while retrying, node swap) is verified in Task B7.

- [ ] **Step 6: Full suite, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add assets/js/hooks/img_fallback.js lib/kith_web/live/contact_live/photo_thumb_component.ex test/kith_web/live/contact_live/activity_stream_component_test.exs
git commit -m "fix(contacts): retry a failed photo once with a fresh URL; clean up stale listeners"
```

### Task B4 (wave 2, after Task B6 is merged): Avatar initials fallback with required ids (B7)

**Files:**
- Modify: `lib/kith_web/components/kith_ui.ex` (`avatar/1`, `contact_badge/1` — **not** `reminder_icon_name/1`, which Lane A edits)
- Modify: `lib/kith_web/live/contact_live/show.html.heex:42`, `lib/kith_web/live/contact_live/index.html.heex:412`, `lib/kith_web/live/contact_live/about_component.ex` (lines ~158, ~184, ~278-285)
- Create: `test/kith_web/components/kith_ui_avatar_test.exs`

**Interfaces:**
- Consumes: B3 (hook semantics; avatars have no `data-refreshable`, so first error → failed). `cluster_merge.ex` already passes ids (Task B6, merged in wave 1).
- Produces: `KithUI.avatar/1` raises `ArgumentError` when `src` is set without `id`; with `src`, renders `phx-hook="ImgFallback"`, `data-fallback-img`, and a hidden initials span shown on `data-img-failed`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule KithWeb.KithUIAvatarTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KithWeb.KithUI

  test "with src: hooked image plus hidden initials fallback" do
    html = render_component(&KithUI.avatar/1, id: "a1", src: "/uploads/x.png", name: "Mona Vale")

    assert html =~ ~s(id="a1")
    assert html =~ ~s(phx-hook="ImgFallback")
    assert html =~ "data-fallback-img"
    assert html =~ "group-data-[img-failed]:inline-flex"
    assert html =~ "MV"
  end

  test "without src: initials only, no hook" do
    html = render_component(&KithUI.avatar/1, name: "Mona Vale")
    refute html =~ "phx-hook"
    assert html =~ "MV"
  end

  test "src without id raises" do
    assert_raise ArgumentError, ~r/needs an :id/, fn ->
      render_component(&KithUI.avatar/1, src: "/uploads/x.png", name: "Mona Vale")
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/components/kith_ui_avatar_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement `avatar/1`**

```elixir
  attr :id, :string,
    default: nil,
    doc: "required when `src` is set: the ImgFallback hook needs a unique DOM id"

  attr :src, :string, default: nil
  attr :name, :string, default: nil
  attr :size, :atom, default: :md, values: [:sm, :md, :lg, :xl]
  attr :class, :string, default: nil

  def avatar(assigns) do
    if assigns.src && is_nil(assigns.id),
      do: raise(ArgumentError, "KithUI.avatar/1 needs an :id when :src is set")

    assigns =
      assigns
      |> assign(:initials_text, initials(assigns.name))
      |> assign(:bg_color, name_to_color(assigns.name))
      |> assign(:size_classes, avatar_size_classes(assigns.size))

    ~H"""
    <div
      id={@id}
      phx-hook={@src && "ImgFallback"}
      class={[
        "group inline-flex items-center justify-center rounded-full shrink-0 font-semibold text-white select-none ring-0 hover:ring-2 ring-[var(--color-accent)]/30 transition-shadow duration-200",
        @size_classes,
        !@src && @bg_color,
        @class
      ]}
    >
      <img
        :if={@src}
        data-fallback-img
        src={@src}
        alt={@name || "Avatar"}
        class={["rounded-full object-cover group-data-[img-failed]:hidden", @size_classes]}
      />
      <span
        :if={@src}
        class={[
          "hidden group-data-[img-failed]:inline-flex items-center justify-center rounded-full",
          @size_classes,
          @bg_color
        ]}
      >
        {@initials_text}
      </span>
      <span :if={!@src}>{@initials_text}</span>
    </div>
    """
  end
```

In `contact_badge/1`: make its `attr :id` `required: true` and pass `id={"#{@id}-avatar"}` to the inner `<.avatar>`; update its doc example to pass an `id`.

- [ ] **Step 4: Give every remaining `src` call site an id**

- `show.html.heex:42`: `<KithUI.avatar id={"contact-avatar-#{@contact.id}"} name=… src=… size={:xl} />`
- `index.html.heex:412` (duplicates list; clusters are disjoint, so a contact appears once): `id={"dup-avatar-#{contact.id}"}`
- `about_component.ex` ~184 (search results, rendered once per About instance — mobile and desktop are both on the page): `id={"#{@id}-search-avatar-#{c.id}"}`
- `about_component.ex` `selected_contact_badge/1` (~278): add `attr`-style `id` to its call (~158) as `id={"#{@id}-through-avatar"}` and pass `id={@id}` to its inner `KithUI.avatar`.

Then confirm nothing is missed:

Run: `grep -rn "avatar" lib/kith_web --include=*.ex --include=*.heex | grep "src=" | grep -v "id="`
Expected: only the `@doc` example lines in `kith_ui.ex`, if any.

- [ ] **Step 5: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/components/kith_ui_avatar_test.exs test/kith_web/live/
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/components/kith_ui.ex lib/kith_web/live/contact_live/show.html.heex lib/kith_web/live/contact_live/index.html.heex lib/kith_web/live/contact_live/about_component.ex test/kith_web/components/kith_ui_avatar_test.exs
git commit -m "fix(ui): avatars fall back to initials when the image fails; ids required with src"
```

---

## Lane B-wizard (wave 1: B5, B6)

### Task B5: Back link, Cancel and tab (B8, B9)

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex` (`mount/3` line 68, header comment and link lines 909–929, Cancel line 1314)
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs` (extend `describe "section nav and back link (#1)"`)

**Interfaces:**
- Produces: assign `:referer_back :: %{path: String.t(), label: String.t()} | nil`; private `back_link(assigns) :: %{path, label}`.

- [ ] **Step 1: Write the failing tests**

Add inside `describe "section nav and back link (#1)"`:

```elixir
    @origin KithWeb.Endpoint.url()

    defp live_from(conn, path, referer),
      do: conn |> Phoenix.LiveViewTest.put_connect_params(%{"_live_referer" => referer}) |> live(path)

    defp manual_pair(ctx) do
      c = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Cleo", last_name: "Ng"})
      d = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Dov", last_name: "Ng"})
      [lead, other] = Enum.sort([c.id, d.id])
      {c, "/contacts/duplicates/cluster/#{lead}?with=#{other}"}
    end

    test "from a contact page the link goes back to that contact", ctx do
      {:ok, live, _} = live_from(ctx.conn, cluster_path(ctx.a, ctx.b), "#{@origin}/contacts/#{ctx.a.id}")
      assert live |> element("a", "Back to #{ctx.a.display_name}") |> render() =~ ~s(href="/contacts/#{ctx.a.id}")
    end

    test "from the contact list the query string is kept", ctx do
      {_c, path} = manual_pair(ctx)
      {:ok, live, _} = live_from(ctx.conn, path, "#{@origin}/contacts?search=ng&sort=name")
      assert live |> element("a", "Back to contacts") |> render() =~ ~s(href="/contacts?search=ng&amp;sort=name")
    end

    test "from the duplicates list the link goes back there", ctx do
      {_c, path} = manual_pair(ctx)
      {:ok, live, _} = live_from(ctx.conn, path, "#{@origin}/contacts/duplicates")
      assert live |> element("a", "Back to duplicates") |> render() =~ ~s(href="/contacts/duplicates")
    end

    test "a foreign host, unknown path, other account's contact or missing id falls back", ctx do
      {_c, path} = manual_pair(ctx)
      other = AccountsFixtures.user_fixture()
      stranger = ContactsFixtures.contact_fixture(other.account_id, %{first_name: "Zed"})

      for referer <- ["https://evil.example/contacts/#{ctx.a.id}", "#{@origin}/settings",
                      "#{@origin}/contacts/#{stranger.id}", "#{@origin}/contacts/999999999", "not a url"] do
        {:ok, live, _} = live_from(ctx.conn, path, referer)
        assert live |> element("a", "Back to contacts") |> render() =~ ~s(href="/contacts"), referer
        refute render(live) =~ "Back to Zed"
      end
    end

    test "Cancel goes where the back link goes", ctx do
      {c, path} = manual_pair(ctx)
      {:ok, live, _} = live_from(ctx.conn, path, "#{@origin}/contacts/#{c.id}")
      assert has_element?(live, ~s(a[href="/contacts/#{c.id}"]), "Cancel")
    end

    test "a manual merge highlights Duplicates, not All", ctx do
      {_c, path} = manual_pair(ctx)
      {:ok, live, _} = live(ctx.conn, path)
      assert live |> element(~s(nav a[href="/contacts/duplicates"])) |> render() =~ "text-[var(--color-accent)]"
      refute live |> element(~s(nav a[href="/contacts"])) |> render() =~ "text-[var(--color-accent)]"
    end
```

(If `nav a[href="/contacts"]` matches more than one link, scope it with the section nav's container selector from `SectionNav`.)

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: the new tests FAIL; the existing ones PASS.

- [ ] **Step 3: Implement**

Replace `mount/3` (line 68):

```elixir
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:error, nil) |> assign(:referer_back, referer_back(socket))}
  end

  # Where "Back" and Cancel go (design B8): the page the user live-navigated
  # from, read once from LiveView's `_live_referer` connect param. Only our own
  # host and three known paths count; a contact path is looked up through the
  # account scope, so a foreign or missing id can never leak a name. Anything
  # else (reload, direct URL, other pages) → nil → the `synthetic?` fallback.
  defp referer_back(socket) do
    with true <- connected?(socket),
         ref when is_binary(ref) <- get_connect_params(socket)["_live_referer"],
         %URI{host: host, path: path, query: query} when is_binary(path) <- URI.parse(ref),
         true <- host == URI.parse(KithWeb.Endpoint.url()).host do
      back_for_path(path, query, socket.assigns.current_scope.account.id)
    else
      _ -> nil
    end
  end

  defp back_for_path("/contacts/duplicates", _query, _account_id),
    do: %{path: ~p"/contacts/duplicates", label: "Back to duplicates"}

  defp back_for_path("/contacts", query, _account_id) do
    path = if query in [nil, ""], do: ~p"/contacts", else: "/contacts?" <> query
    %{path: path, label: "Back to contacts"}
  end

  defp back_for_path("/contacts/" <> raw, _query, account_id) do
    with id when is_integer(id) <- parse_contact_id(raw),
         %Kith.Contacts.Contact{} = contact <- Kith.Contacts.get_contact(account_id, id) do
      %{path: ~p"/contacts/#{contact.id}", label: "Back to #{contact.display_name}"}
    else
      _ -> nil
    end
  end

  defp back_for_path(_path, _query, _account_id), do: nil

  defp back_link(%{referer_back: %{} = back}), do: back
  defp back_link(%{synthetic?: true}), do: %{path: ~p"/contacts", label: "Back to contacts"}
  defp back_link(_assigns), do: %{path: ~p"/contacts/duplicates", label: "Back to duplicates"}
```

(`parse_contact_id/1` already exists right below `mount/3`. Confirm `Kith.Contacts.get_contact/2` excludes soft-deleted contacts; if it doesn't, add `nil <- contact.deleted_at` to the `with`.)

Header (lines 909–929): replace the comment with

```heex
      <%!--
        Section header + sub-nav. The wizard is its own LiveView, so it renders
        the shared Contacts tab bar itself, always with Duplicates active (the
        page is "Merge duplicates"). The back link returns to the page the user
        came from (`_live_referer`: a contact, the list with its query, or the
        duplicates list); on a reload or direct URL it falls back to the
        duplicates list for a detected cluster and the contact list otherwise.
      --%>
```

the link with

```heex
        <.link
          navigate={back_link(assigns).path}
          class="inline-flex items-center gap-1.5 text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          {back_link(assigns).label}
        </.link>
```

and `active={if @synthetic?, do: :index, else: :duplicates}` with `active={:duplicates}`.

Cancel (line 1314): `<UI.button :if={@synthetic?} variant="secondary" navigate={back_link(assigns).path}>`.

- [ ] **Step 4: Run, then the mutation check**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/cluster_merge_test.exs` → PASS.

Mutation check (do not commit these): (M1) make `back_link/1` always return the fallback; (M2) set `active={:index}`; (M3) point Cancel at `~p"/contacts"`. After each, re-run the file and confirm at least one new test FAILS; restore with `git checkout -- lib/kith_web/live/contact_live/cluster_merge.ex` only if you committed nothing else in it, otherwise undo by hand. Record "M1/M2/M3 caught" in the commit body.

- [ ] **Step 5: Full suite, commit**

```bash
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "fix(duplicates): merge wizard goes back where the user came from; Duplicates tab always active" -m "Mutation check: M1 back link, M2 tab, M3 Cancel each caught by the new tests."
```

### Task B6: Accessible choices and unique avatar ids (B10, B11)

**Files:**
- Modify: `lib/kith_web/live/contact_live/cluster_merge.ex` (delete `candidate_name/2` ~764–773; choice buttons ~1078–1121; member chip ~975)
- Test: `test/kith_web/live/contact_live/cluster_merge_test.exs` (extend `describe "avatar values (#3)"`)

**Interfaces:**
- Produces: avatar ids `merge-member-avatar-<id>` and `merge-avatar-choice-<index>` (consumed by Task B4's required-id rule); `aria-pressed` on every `choose-field` button; `aria-label` on avatar choices.

- [ ] **Step 1: Write the failing tests**

Inside `describe "avatar values (#3)"` (reuse the Mona/e/f setup from the existing test by extracting it into a `defp mona_pair(ctx)` helper):

```elixir
    test "avatar choices have distinct accessible names and expose the selection", ctx do
      {e, f} = mona_pair(ctx)
      {:ok, live, _} = live(ctx.conn, cluster_path(e, f))
      row = live |> element(~s(div[data-field="avatar"])) |> render()

      assert row =~ ~s(aria-label="Photo 1 of 2, from Mona Vale")
      assert row =~ ~s(aria-label="Photo 2 of 2, from Mona Vale")
      assert length(Regex.scan(~r/aria-pressed="true"/, row)) == 1
      assert row =~ ~s(aria-pressed="false")
    end

    test "chips and choices get unique avatar ids", ctx do
      {e, f} = mona_pair(ctx)
      {:ok, live, _} = live(ctx.conn, cluster_path(e, f))

      assert has_element?(live, "#merge-member-avatar-#{e.id}")
      assert has_element?(live, "#merge-member-avatar-#{f.id}")
      assert has_element?(live, "#merge-avatar-choice-0")
      assert has_element?(live, "#merge-avatar-choice-1")
    end

    test "the same avatar file as chip and choice renders without duplicate ids", ctx do
      e = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Mona", last_name: "Vale", avatar: "avatars/same.jpg"})
      f = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Mona", last_name: "Vale", avatar: "avatars/same.jpg"})
      candidate!(ctx.account_id, e, f)

      # LiveViewTest raises on duplicate DOM ids.
      assert {:ok, _live, _} = live(ctx.conn, cluster_path(e, f))
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/cluster_merge_test.exs`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement**

- Delete `candidate_name/2` (both clauses and its comment).
- Choice button (`:for={{candidate, index} <- …}`): add

```heex
                aria-pressed={to_string(effective(assigns, field) == candidate.value)}
                aria-label={field == :avatar && avatar_choice_label(assigns, candidate, index)}
```

- Avatar inside it:

```heex
                <KithUI.avatar
                  :if={field == :avatar}
                  id={"merge-avatar-choice-#{index}"}
                  name={member_name(assigns, hd(candidate.member_ids))}
                  src={Storage.url(candidate.value)}
                  size={:md}
                />
```

- "Leave empty" button: add `aria-pressed={to_string(effective(assigns, field) == :clear)}`.
- Member chip (~975): `<KithUI.avatar id={"merge-member-avatar-#{member.id}"} name={member.display_name} src={avatar_url(member)} size={:sm} />`.
- Add near `member_name/2`:

```elixir
  # "Photo 2 of 3, from Mona Vale, M. Vale" — distinct names for otherwise
  # identical avatar buttons (design B10).
  defp avatar_choice_label(assigns, candidate, index) do
    holders =
      candidate.member_ids
      |> Enum.map(&member_name(assigns, &1))
      |> Enum.uniq()
      |> Enum.join(", ")

    "Photo #{index + 1} of #{length(candidates(assigns, :avatar))}, from #{holders}"
  end
```

`aria-label={false}` renders no attribute for non-avatar rows.

- [ ] **Step 4: Run, full suite, commit**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test test/kith_web/live/contact_live/cluster_merge_test.exs
mix format && mix credo --strict && DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add lib/kith_web/live/contact_live/cluster_merge.ex test/kith_web/live/contact_live/cluster_merge_test.exs
git commit -m "fix(duplicates): accessible avatar choices, aria-pressed, unique avatar ids"
```

---

## Wave 3 (integration branch, single agent)

### Task B7: S3 regression test and browser checks

**Files:**
- Create: `test/kith_web/live/contact_live/cluster_merge_s3_test.exs` (its own module, because it needs `async: false` for global S3 config)
- Create: `test/playwright/image-fallback.spec.ts`, `test/playwright/fixtures/s3/seed.exs`, `test/playwright/fixtures/s3/fake_s3.py` (copy of `stack-40-reviews/tools/fake_s3.py`), `test/playwright/fixtures/s3/README.md`

**Interfaces:**
- Consumes: everything in this plan, merged.

- [ ] **Step 1: S3 regression (#36-1)**

`test/kith_web/live/contact_live/cluster_merge_s3_test.exs`:

```elixir
defmodule KithWeb.ContactLive.ClusterMergeS3Test do
  # Sets global S3 config.
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    saved = for {app, key} <- [{:kith, Kith.Storage}, {:ex_aws, :s3}, {:ex_aws, :access_key_id}, {:ex_aws, :secret_access_key}, {:ex_aws, :region}],
                do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")
    Application.put_env(:ex_aws, :region, "us-east-1")
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)

    on_exit(fn ->
      for {app, key, v} <- saved do
        case v do
          {:ok, val} -> Application.put_env(app, key, val)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), account_id: user.account_id}
  end

  test "an avatar's URL is unchanged after toggling a member off and on", ctx do
    e = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Mona", last_name: "Vale", avatar: "avatars/a.png"})
    f = ContactsFixtures.contact_fixture(ctx.account_id, %{first_name: "Mona", last_name: "Vale", avatar: "avatars/b.png"})

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: ctx.account_id, contact_id: min(e.id, f.id), duplicate_contact_id: max(e.id, f.id),
      score: 1.0, reasons: ["name_match"], status: "pending"
    })

    {:ok, live, _} = live(ctx.conn, "/contacts/duplicates/cluster/#{min(e.id, f.id)}")
    src = fn -> live |> element("#merge-avatar-choice-0 img") |> render() |> then(&Regex.run(~r/src="([^"]+)"/, &1)) |> List.last() end

    before = src.()
    live |> element("input[phx-click='toggle-member'][phx-value-id='#{f.id}']") |> render_click()
    live |> element("input[phx-click='toggle-member'][phx-value-id='#{f.id}']") |> render_click()
    assert src.() == before
  end
end
```

(Copy the `DuplicateCandidate` fields from `candidate!/3` in `cluster_merge_test.exs` if they differ from the ones above.) Run it; expected PASS. A run that straddles an hour boundary can flake once; note that in a comment above the test.

- [ ] **Step 2: Browser harness**

`test/playwright/fixtures/s3/seed.exs` (run with `REVIEW_S3=1 mix run test/playwright/fixtures/s3/seed.exs`; prints JSON with ids to stdout):

```elixir
# Seeds one confirmed user with: a contact whose photo file is missing, a
# contact whose photo is still syncing, two duplicates with different avatars
# (one missing), for test/playwright/image-fallback.spec.ts. Requires the
# fake S3 (fake_s3.py) and REVIEW_S3=1 dev config (see README).
alias Kith.{Accounts, Contacts, Repo}

email = "img-#{System.unique_integer([:positive])}@test.local"
{:ok, %{user: user}} = Accounts.register_user(%{email: email, password: "ValidP@ssword123!"})
user = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second)) |> Repo.update!()
acc = user.account_id

{:ok, photo_contact} = Contacts.create_contact(acc, %{first_name: "Photo", last_name: "Missing"})

photo = fn contact, key ->
  %Contacts.Photo{}
  |> Contacts.Photo.changeset(%{file_name: "p.png", storage_key: key, file_size: 100, content_type: "image/png",
                                 contact_id: contact.id, account_id: acc})
  |> Repo.insert!()
end

missing = photo.(photo_contact, "#{acc}/photos/missing-1.png")
syncing = photo.(photo_contact, "pending_sync:immich-1")

{:ok, a} = Contacts.create_contact(acc, %{first_name: "Mona", last_name: "Vale", avatar: "#{acc}/avatars/avatar-a.png"})
{:ok, b} = Contacts.create_contact(acc, %{first_name: "Mona", last_name: "Vale", avatar: "#{acc}/avatars/missing-b.png"})

Repo.insert!(%Contacts.DuplicateCandidate{account_id: acc, contact_id: min(a.id, b.id), duplicate_contact_id: max(a.id, b.id),
                                          score: 1.0, reasons: ["name_match"], status: "pending"})

IO.puts(Jason.encode!(%{email: email, password: "ValidP@ssword123!", photo_contact: photo_contact.id,
                         missing_photo: missing.id, syncing_photo: syncing.id, a: a.id, b: b.id,
                         ok_key: "#{acc}/photos/ok-1.png"}))
```

README: start `python fake_s3.py <windows path>\s3.log`; add the **uncommitted** `REVIEW_S3` block from `stack-40-reviews/code-review-high-2026-09-25/pr-36-handoff.md` §2 to `config/dev.exs`; `REVIEW_S3=1 mix phx.server` on :4000; run the seed; export `IMG_SEED_JSON='<printed json>'`.

- [ ] **Step 3: Playwright spec**

`test/playwright/image-fallback.spec.ts`:

```ts
import { test, expect, type Page } from "@playwright/test";

const seed = process.env.IMG_SEED_JSON ? JSON.parse(process.env.IMG_SEED_JSON) : null;
test.skip(!seed, "IMG_SEED_JSON not set (see test/playwright/fixtures/s3/README.md)");

async function login(page: Page) {
  await page.goto("/users/log-in");
  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.getByRole("textbox", { name: /email/i }).fill(seed.email);
  await page.locator('input[type="password"]').fill(seed.password);
  await page.getByRole("button", { name: /log in/i }).click();
  await page.waitForURL(/\/(dashboard|contacts)/);
}

test("a missing photo retries once, never shows the broken image, then says unavailable", async ({ page }) => {
  await login(page);
  const refreshes: string[] = [];
  page.on("websocket", (ws) => ws.on("framesent", (f) => { if (String(f.payload).includes("refresh_url")) refreshes.push("x"); }));

  // Record whether the broken <img> is ever visible while the root is retrying.
  await page.addInitScript(() => {
    (window as any).__brokenVisible = false;
    new MutationObserver(() => {
      document.querySelectorAll("[data-img-retrying] img[data-fallback-img]").forEach((img) => {
        if (getComputedStyle(img).visibility !== "hidden") (window as any).__brokenVisible = true;
      });
    }).observe(document, { subtree: true, attributes: true, childList: true });
  });

  await page.goto(`/contacts/${seed.photo_contact}`);
  const root = page.locator(`[id^="photo-"][data-refreshable="true"]`).first();
  await expect(root).toHaveAttribute("data-img-failed", "", { timeout: 10_000 });
  await expect(root.getByText("Image unavailable")).toBeVisible();
  await page.waitForTimeout(1500);
  expect(refreshes.length).toBe(1);
  expect(await page.evaluate(() => (window as any).__brokenVisible)).toBe(false);
});

test("a missing avatar shows initials as chip and as choice, with no duplicate-id errors", async ({ page }) => {
  const errors: string[] = [];
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await login(page);
  await page.goto(`/contacts/duplicates/cluster/${Math.min(seed.a, seed.b)}`);

  await expect(page.locator(`#merge-member-avatar-${seed.b}`)).toHaveAttribute("data-img-failed", "");
  await expect(page.locator(`#merge-member-avatar-${seed.b}`).getByText("MV")).toBeVisible();
  const choices = page.locator('[id^="merge-avatar-choice-"][data-img-failed]');
  await expect(choices).toHaveCount(1);
  expect(errors.filter((e) => /duplicate id/i.test(e))).toEqual([]);
});
```

Third test (#35-6, node swap). Add `import { execSync } from "node:child_process";` at the top, then:

```ts
test("a syncing photo that becomes an image is judged on its new node only", async ({ page }) => {
  await login(page);
  await page.goto(`/contacts/${seed.photo_contact}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  await expect(page.getByText("Syncing…").first()).toBeVisible();

  // Give the syncing photo a real (fake-S3 200) key, in the dev DB.
  execSync(
    `mix run -e 'Kith.Repo.get!(Kith.Contacts.Photo, ${seed.syncing_photo}) |> Ecto.Changeset.change(storage_key: "${seed.ok_key}") |> Kith.Repo.update!()'`,
    { env: { ...process.env, REVIEW_S3: "1" }, stdio: "inherit" },
  );

  // Make the activity stream re-query its entries (filter-clear → load_entries),
  // so LiveView swaps the syncing placeholder for an <img> in place.
  await page.evaluate(() => {
    const target = "button[phx-value-type='note']";
    (window as any).liveSocket.execJS(
      document.querySelector(target),
      JSON.stringify([["push", { event: "filter-clear", target }]]),
    );
  });

  const img = page.locator(`img[data-fallback-img][src*="ok-1.png"]`).first();
  await expect(img).toBeVisible();
  await page.waitForTimeout(1500);
  const root = img.locator("xpath=ancestor::*[@phx-hook='ImgFallback'][1]");
  await expect(root).not.toHaveAttribute("data-img-failed", "");
});
```

- [ ] **Step 4: Run headless**

Run: `IMG_SEED_JSON='…' npx playwright test --project=e2e test/playwright/image-fallback.spec.ts` (headless is the default). Expected: all pass. Without `IMG_SEED_JSON`: all skipped.

- [ ] **Step 5: Commit and clean up**

```bash
DB_PORT=$DB_PORT MIX_TEST_PARTITION=$LANE mix test
git add test/kith_web/live/contact_live/cluster_merge_s3_test.exs test/playwright/image-fallback.spec.ts test/playwright/fixtures/s3
git commit -m "test: S3 avatar URL stability and image-fallback browser checks"
```

Revert the `config/dev.exs` `REVIEW_S3` block, stop the fake S3 and the dev server (by named node / verified PID), and delete Playwright artifacts (`test-results/`, traces).
