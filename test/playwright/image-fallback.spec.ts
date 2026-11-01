import { test, expect, type Page, type WebSocketRoute } from "@playwright/test";
import { execSync } from "node:child_process";

const seed = process.env.IMG_SEED_JSON ? JSON.parse(process.env.IMG_SEED_JSON) : null;
// Upper bound we wait before asserting that something did NOT happen (no further
// refresh_url push, no state change). There is no condition to poll for an
// absence, so this is one short bounded wait; every positive wait polls instead.
const NOTHING_HAPPENS_MS = 1500;

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

  // Record whether the broken <img> is visible while the root is retrying. It is checked in the
  // first mutation callback after the attribute appears; __sawRetrying is the positive control
  // proving the retrying state was actually observed (otherwise __brokenVisible=false is vacuous).
  await page.addInitScript(() => {
    (window as any).__brokenVisible = false;
    (window as any).__sawRetrying = false;
    new MutationObserver(() => {
      document.querySelectorAll("[data-img-retrying]").forEach((root) => {
        (window as any).__sawRetrying = true;
        root.querySelectorAll("img[data-fallback-img]").forEach((img) => {
          if (getComputedStyle(img).visibility !== "hidden" && getComputedStyle(img).display !== "none") {
            (window as any).__brokenVisible = true;
          }
        });
      });
    }).observe(document, { subtree: true, attributes: true, childList: true });
  });

  await page.goto(`/contacts/${seed.photo_contact}`);
  const root = page.locator(`[id^="photo-"][data-refreshable="true"]`).first();
  await expect(root).toHaveAttribute("data-img-failed", "", { timeout: 10_000 });
  await expect(root.getByText("Image unavailable")).toBeVisible();
  await page.waitForTimeout(NOTHING_HAPPENS_MS);
  expect(refreshes.length).toBe(1);
  expect(await page.evaluate(() => (window as any).__sawRetrying)).toBe(true);
  expect(await page.evaluate(() => (window as any).__brokenVisible)).toBe(false);
});

test("an img that already failed before the hook mounts still retries once, then fails", async ({ page }) => {
  await login(page);
  const refreshes: string[] = [];
  page.on("websocket", (ws) => ws.on("framesent", (f) => { if (String(f.payload).includes("refresh_url")) refreshes.push("x"); }));

  // Record the <img> error event (non-bubbling, so capture on document) before any script runs.
  await page.addInitScript(() => {
    (window as any).__imgErrored = false;
    document.addEventListener("error", (e) => {
      if ((e.target as Element).tagName === "IMG") (window as any).__imgErrored = true;
    }, true);
  });

  // Hold app.js (which defines the hook and connects the socket) until the img has errored.
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  await page.route("**/assets/js/app.js**", async (route) => { await gate; await route.continue(); });

  await page.goto(`/contacts/${seed.photo_contact}`, { waitUntil: "commit" });
  await page.waitForFunction(() => (window as any).__imgErrored === true);
  // The hook cannot have run: nothing has marked the root yet and no socket exists.
  expect(await page.locator("[data-img-retrying], [data-img-failed]").count()).toBe(0);
  expect(refreshes.length).toBe(0);
  release();

  const root = page.locator(`[id^="photo-"][data-refreshable="true"]`).first();
  await expect(root).toHaveAttribute("data-img-failed", "", { timeout: 10_000 });
  await expect(root.getByText("Image unavailable")).toBeVisible();
  await page.waitForTimeout(NOTHING_HAPPENS_MS);
  expect(refreshes.length).toBe(1);
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
  await expect.poll(() => img.evaluate((i: HTMLImageElement) => i.complete && i.naturalWidth > 0)).toBe(true);
  await page.waitForTimeout(NOTHING_HAPPENS_MS);
  const root = img.locator("xpath=ancestor::*[@phx-hook='ImgFallback'][1]");
  await expect(root).not.toHaveAttribute("data-img-failed", "");
});

// ---------------------------------------------------------------------------
// Carried-over checks. These mutate the dev DB (needs DB_PORT, REVIEW_S3=1) and
// each uses its own seeded contact so tests can run in parallel.

function mix(code: string) {
  execSync(`mix run -e '${code}'`, { env: { ...process.env, REVIEW_S3: "1" }, stdio: "pipe" });
}

function setPhoto(id: number, fields: string) {
  mix(`Kith.Repo.get!(Kith.Contacts.Photo, ${id}) |> Ecto.Changeset.change(${fields}) |> Kith.Repo.update!()`);
}

// Re-query the activity stream (filter-clear -> load_entries), re-rendering the photo components.
async function requery(page: Page) {
  await page.evaluate(
    () => {
      const target = "button[phx-value-type='note']";
      (window as any).liveSocket.execJS(
        document.querySelector(target),
        JSON.stringify([["push", { event: "filter-clear", target }]]),
      );
    },
  );
}

async function expectThreeStates(page: Page) {
  const syncing = page.locator(`#photo-${seed.tile_syncing}`);
  await expect(syncing.getByText("Syncing…")).toBeVisible();

  const ok = page.locator(`#photo-${seed.tile_ok}`);
  await expect(ok.locator("img")).toBeVisible();
  await expect.poll(() => ok.locator("img").evaluate((i: HTMLImageElement) => i.complete && i.naturalWidth > 0)).toBe(true);
  await expect(ok).not.toHaveAttribute("data-img-failed", "");
  await expect(ok).not.toHaveAttribute("data-img-retrying", "");

  const missing = page.locator(`#photo-${seed.tile_missing}`);
  await expect(missing).toHaveAttribute("data-img-failed", "", { timeout: 10_000 });
  await expect(missing.getByText("Image unavailable")).toBeVisible();
  await expect(missing.locator("img")).toBeHidden();
}

test("(a) timeline and tile variants render syncing, loaded and unavailable", async ({ page }) => {
  await login(page);
  await page.goto(`/contacts/${seed.tile_contact}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  await expect(page.locator(`#photo-${seed.tile_ok}`)).toHaveClass(/inline-block/); // timeline variant
  await expectThreeStates(page);

  await page.getByRole("button", { name: /^Filter/ }).click();
  await page.locator("button[phx-click='filter-toggle'][phx-value-type='photo']").click();
  await expect(page.locator(`#photo-${seed.tile_ok}`)).toHaveClass(/w-full/); // tile variant
  await expectThreeStates(page);
});

test("(b) hook-set failed state survives a LiveView patch of the component (updated())", async ({ page }) => {
  await login(page);
  await page.goto(`/contacts/${seed.patch_contact}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  const root = page.locator(`#photo-${seed.patch_photo}`);
  await expect(root).toHaveAttribute("data-img-failed", "", { timeout: 10_000 });
  await page.evaluate((id) => { (window as any).__root = document.getElementById(`photo-${id}`); }, seed.patch_photo);

  // Change the alt text (file_name) so the re-render genuinely patches the component.
  setPhoto(seed.patch_photo, 'file_name: "patch-after.png"');
  await requery(page);
  await expect(root.locator("img")).toHaveAttribute("alt", "patch-after.png");

  expect(await page.evaluate((id) => (window as any).__root === document.getElementById(`photo-${id}`), seed.patch_photo)).toBe(true);
  await expect(root).toHaveAttribute("data-img-failed", "");
  await expect(root.getByText("Image unavailable")).toBeVisible();
});

// Proxies the LiveView websocket so the reply to the hook's refresh_url push can be held and/or rewritten.
// A wire shape that is not what we expect is recorded in st.error and fails the test loudly via waitHeld().
type Held = { ref: string | null; held: string | null; error: string | null; ws: WebSocketRoute | null };

function replyPayload(frame: any): { changed: boolean } {
  const r = frame?.[4]?.response?.diff?.r;
  if (!r || typeof r.changed !== "boolean") {
    throw new Error(`unexpected refresh_url phx_reply wire shape: ${JSON.stringify(frame)}`);
  }
  return r;
}

async function waitHeld(st: Held): Promise<{ changed: boolean }> {
  await expect.poll(() => { if (st.error) throw new Error(st.error); return st.held; }).not.toBeNull();
  return replyPayload(JSON.parse(st.held!));
}

async function interceptRefreshReply(page: Page, rewriteChanged: boolean | null) {
  const st: Held = { ref: null, held: null, error: null, ws: null };
  await page.routeWebSocket(/\/live\/websocket/, (ws) => {
    const server = ws.connectToServer();
    st.ws = ws;
    ws.onMessage((m) => {
      const a = parseFrame(m);
      if (a && a[3] === "event" && a[4]?.event === "refresh_url") st.ref = a[1];
      server.send(m);
    });
    server.onMessage((m) => {
      const a = parseFrame(m);
      if (a && st.ref && a[1] === st.ref && a[3] === "phx_reply") {
        try {
          if (rewriteChanged !== null) replyPayload(a).changed = rewriteChanged;
          replyPayload(a);
          st.held = JSON.stringify(a);
        } catch (e) {
          st.error = String(e);
        }
        return; // hold until released
      }
      ws.send(m);
    });
  });
  return st;
}

function parseFrame(m: string | Buffer): any[] | null {
  try {
    const a = JSON.parse(String(m));
    return Array.isArray(a) ? a : null;
  } catch {
    return null; // not a JSON text frame: forward untouched
  }
}

test("(c) [server reply simulated, hook real] refresh_url changed:true keeps retrying until the new URL loads", async ({ page }) => {
  // The fake S3 / hourly-stable signing cannot make the server answer changed:true within one
  // hour for an unchanged key, so the reply is rewritten to changed:true in the websocket proxy;
  // the follow-up (new key -> new src on the same node -> real load) is genuine.
  const st = await interceptRefreshReply(page, true);
  await login(page);
  await page.goto(`/contacts/${seed.changed_contact}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  const root = page.locator(`#photo-${seed.changed_photo}`);
  expect((await waitHeld(st)).changed).toBe(true);
  await expect(root).toHaveAttribute("data-img-retrying", "");

  st.ws!.send(st.held!); // deliver changed:true
  await page.waitForTimeout(NOTHING_HAPPENS_MS);
  await expect(root).toHaveAttribute("data-img-retrying", ""); // not failed: waiting for the new URL
  await expect(root).not.toHaveAttribute("data-img-failed", "");

  setPhoto(seed.changed_photo, `storage_key: "${seed.ok_key}"`);
  await requery(page);
  const img = root.locator("img");
  await expect(img).toHaveAttribute("src", /ok-1\.png/);
  await expect.poll(() => img.evaluate((i: HTMLImageElement) => i.complete && i.naturalWidth > 0)).toBe(true);
  await expect(root).not.toHaveAttribute("data-img-retrying", "");
  await expect(root).not.toHaveAttribute("data-img-failed", "");
});

test("(d) a late changed:false reply after a node swap does not fail the new img", async ({ page }) => {
  const st = await interceptRefreshReply(page, null);
  await login(page);
  await page.goto(`/contacts/${seed.stale_contact}`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  const root = page.locator(`#photo-${seed.stale_photo}`);
  expect((await waitHeld(st)).changed).toBe(false);
  await expect(root).toHaveAttribute("data-img-retrying", "");

  // Swap the node: img -> syncing placeholder -> a new, good img.
  setPhoto(seed.stale_photo, 'storage_key: "pending_sync:stale"');
  await requery(page);
  await expect(root.getByText("Syncing…")).toBeVisible();
  setPhoto(seed.stale_photo, `storage_key: "${seed.ok_key}"`);
  await requery(page);
  const img = root.locator("img");
  await expect.poll(() => img.evaluate((i: HTMLImageElement) => i.complete && i.naturalWidth > 0)).toBe(true);

  st.ws!.send(st.held!); // the stale changed:false reply arrives late
  await page.waitForTimeout(NOTHING_HAPPENS_MS);
  await expect(root).not.toHaveAttribute("data-img-failed", "");
  await expect(root).not.toHaveAttribute("data-img-retrying", "");
  await expect(img).toBeVisible();
});
