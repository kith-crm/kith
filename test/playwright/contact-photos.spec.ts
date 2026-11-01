import { test, expect, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { passwordLogin } from "./helpers/password-login";

test.skip(process.env.KITH_E2E !== "1", "Requires local regression fixtures");
let fixture: {email: string; contact_id: number};
const hashedName = "MqkbdPlbb5ChW49ifnLKWcchWDhOSQEGwSbIfKvb.jpeg";
const quotedName = `Family's "pic".png`;
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY1kAAAAASUVORK5CYII=", "base64");

test.beforeAll(() => {
  const output = execFileSync("mix", ["run", "--no-start", "--no-compile", "test/playwright/fixtures/regressions/control.exs", "prepare", JSON.stringify({scenario: "editor"})], {
    env: {...process.env, MIX_ENV: "test", KITH_E2E: "1", KITH_TEST_SERVER: "0"}, encoding: "utf8", timeout: 120_000,
  });
  fixture = JSON.parse(output.split(/\r?\n/).findLast(line => line.startsWith("KITH_TEST_RESULT="))!.slice("KITH_TEST_RESULT=".length));
});

async function upload(page: Page, name: string) {
  await page.locator('[phx-click="open-entry-modal"][phx-value-type="photo"]').evaluate((el: HTMLElement) => el.click());
  await page.locator('#photo-upload-form input[type="file"]').setInputFiles({name, mimeType: "image/png", buffer: png});
  await page.locator('#photo-upload-form button[type="submit"]').click();
  await expect(page.locator("#entry-modal")).toHaveCount(0);
}
async function loaded(page: Page) {
  const image = page.locator("#photo-modal img");
  await expect(image).toBeVisible();
  await expect.poll(() => image.evaluate((el: HTMLImageElement) => el.naturalWidth)).toBeGreaterThan(0);
}

test("uploaded timeline photos load in a keyboard accessible viewer across filters and updates", async ({page}) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await passwordLogin(page, fixture.email, "ValidP@ssword123!");
  await page.goto(`/contacts/${fixture.contact_id}`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await upload(page, hashedName);
  const thumb = page.getByRole("button", {name: "View photo", exact: true}).first();
  await expect(thumb.locator("img")).toBeVisible();
  await expect(page.getByText(hashedName, {exact: true})).toHaveCount(0);
  const originalThumb = await thumb.elementHandle();
  await thumb.click();
  await loaded(page);
  expect(await originalThumb!.evaluate(el => el.isConnected)).toBe(true);

  const close = page.locator('#photo-modal button[aria-label="close"]');
  await expect(close).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(close).toBeFocused();
  await page.keyboard.press("Shift+Tab");
  await expect(close).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.locator("#photo-modal")).toHaveCount(0);
  await expect(thumb).toBeFocused();
  await thumb.click();
  await loaded(page);
  await close.click();
  await expect(page.locator("#photo-modal")).toHaveCount(0);
  await expect(thumb).toBeFocused();
  const originalPhotoId = await thumb.getAttribute("phx-value-id");
  await upload(page, quotedName);
  const quotedThumb = page.locator(`button[aria-label="View photo"]:not([phx-value-id="${originalPhotoId}"])`);
  await expect(page.getByRole("button", {name: "View photo", exact: true})).toHaveCount(2);
  await page.locator('[phx-click="filter-toggle"][phx-value-type="photo"]').evaluate((el: HTMLElement) => el.click());
  await expect(page.locator('[phx-click="filter-clear"]').last()).toBeVisible();
  await quotedThumb.click();
  await loaded(page);
  await page.locator('#photo-modal [role="dialog"]').click({position: {x: 5, y: 5}});
  await expect(page.locator("#photo-modal")).toHaveCount(0);
  await expect(quotedThumb).toBeFocused();
  await page.locator('[phx-click="filter-clear"]').last().click();
  await quotedThumb.click();
  await loaded(page);
  await page.keyboard.press("Escape");
  await expect(page.locator("#photo-modal")).toHaveCount(0);
  // Real missing requests exercise the existing one-shot retry and fallback hook.
  const sources = await page.locator('button[aria-label="View photo"] img').evaluateAll(images => images.map(img => (img as HTMLImageElement).src));
  for (const src of sources) await page.route(src, route => route.fulfill({status: 404, body: "missing"}));
  await page.reload();
  await expect(thumb.getByText("Image unavailable")).toBeVisible();
  await expect(thumb).toHaveAccessibleName("View photo");
  await thumb.click();
  await expect(page.locator("#photo-modal").getByText("Image unavailable")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("#photo-modal")).toHaveCount(0);
  expect(errors).toEqual([]);
});
