import { test, expect, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { passwordLogin } from "./helpers/password-login";

process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";

test.skip(process.env.KITH_E2E !== "1", "Requires the local regression harness in fixtures/regressions/README.md");
test.describe.configure({ mode: "default" });
// One-time credentials must never be captured by browser artifacts.
test.use({ trace: "off", screenshot: "off", video: "off" });

let email: string;

test.beforeAll(() => {
  const output = execFileSync("mix", ["run", "--no-start", "--no-compile", "test/playwright/fixtures/regressions/control.exs", "prepare", JSON.stringify({ scenario: "import" })], {
    env: { ...process.env, MIX_ENV: "test", KITH_E2E: "1", KITH_TEST_SERVER: "0" },
    encoding: "utf8", timeout: 120_000,
  });
  const result = output.split(/\r?\n/).findLast(line => line.startsWith("KITH_TEST_RESULT="));
  if (!result) throw new Error(`Missing account fixture: ${output}`);
  email = JSON.parse(result.slice("KITH_TEST_RESULT=".length)).email;
});

test.afterEach(async ({ page }) => {
  // Remove visible credentials before Playwright collects failure context.
  await page.close();
});

test.beforeEach(async ({ page }) => {
  process.env.PLAYWRIGHT_NO_COPY_PROMPT = "1";
  await page.addInitScript(() => {
    const state = { mode: "resolve", writes: [] as string[], finish: () => {} };
    (window as any).clipboardTest = state;
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText(value: string) {
        state.writes.push(value);
        if (state.mode === "reject") return Promise.reject(new Error("Clipboard permission denied"));
        if (state.mode === "pending") return new Promise<void>(resolve => { state.finish = resolve; });
        return Promise.resolve();
      } },
    });
  });
  await passwordLogin(page, email, "ValidP@ssword123!");
  await page.goto("/settings/contact-sync");
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
});

function copyButton(page: Page) {
  return page.locator('[x-data="copyText"]').getByRole("button");
}

async function expectManualCopy(page: Page) {
  await expect(page.getByRole("status").filter({ hasText: /copy.*manually/i })).toBeVisible();
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeHidden();
  const input = page.locator("#carddav-url");
  await expect(input).toHaveAttribute("readonly", "");
  await input.focus();
  await page.keyboard.press("ControlOrMeta+A");
  await expect(input).toBeFocused();
  expect(await input.evaluate((element: HTMLInputElement) => element.value.slice(element.selectionStart!, element.selectionEnd!))).toBe(await input.inputValue());
}

test("copies the displayed URL, including after LiveView navigation", async ({ page }) => {
  const expected = await page.locator("#carddav-url").inputValue();
  await copyButton(page).click();
  await expect.poll(() => page.evaluate(() => (window as any).clipboardTest.writes)).toEqual([expected]);
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeVisible();

  // This sentinel survives LiveView navigation but disappears on a full reload.
  await page.evaluate(() => { (window as any).liveNavigationSentinel = true; });
  await page.locator('a[data-phx-link="redirect"][href="/settings/account"]').first().click();
  await expect(page).toHaveURL(/\/settings\/account$/);
  await page.locator('a[data-phx-link="redirect"][href="/settings/contact-sync"]').first().click();
  await expect(page.locator("#carddav-url")).toBeVisible();
  expect(await page.evaluate(() => (window as any).liveNavigationSentinel)).toBe(true);
  await copyButton(page).click();
  await expect.poll(() => page.evaluate(() => (window as any).clipboardTest.writes)).toEqual([expected, await page.locator("#carddav-url").inputValue()]);
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeVisible();
});

test("shows success only after the clipboard write fulfills", async ({ page }) => {
  await page.evaluate(() => { (window as any).clipboardTest.mode = "pending"; });
  await copyButton(page).click();
  await expect.poll(() => page.evaluate(() => (window as any).clipboardTest.writes.length)).toBe(1);
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeHidden();
  await page.evaluate(() => (window as any).clipboardTest.finish());
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeVisible();
});

test("handles rejected writes and resets feedback on the next attempt", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await copyButton(page).click();
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeVisible();
  await page.evaluate(() => { (window as any).clipboardTest.mode = "reject"; });
  await copyButton(page).click();
  await expectManualCopy(page);
  expect(errors).toEqual([]);
  await page.evaluate(() => { (window as any).clipboardTest.mode = "pending"; });
  await copyButton(page).click();
  await expect(page.getByRole("status").filter({ hasText: /copy.*manually/i })).toBeHidden();
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeHidden();
  await page.evaluate(() => (window as any).clipboardTest.finish());
  await expect(copyButton(page).locator('span[x-show="copied"]')).toBeVisible();
});

test("offers manual copying when the Clipboard API is missing", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { value: undefined }));
  await copyButton(page).click();
  await expectManualCopy(page);
  expect(errors).toEqual([]);
});

for (const viewport of [{width: 1280, height: 900}, {width: 390, height: 844}]) {
  test(`focused one-time credential lifecycle at ${viewport.width}px`, async ({ page }) => {
    try {
      const browserErrors: string[] = [];
      page.on("pageerror", error => browserErrors.push(error.message));
      await page.setViewportSize(viewport);
      await expect(page.locator("#dav-password-form")).toHaveCount(0);
      const selector = page.locator("#settings-destination");
      if (viewport.width < 600) await expect(selector).toBeVisible();
      await page.getByRole("link", {name: "Create app password", exact: true}).click();
      await page.getByLabel("Device name").fill(`Phone ${viewport.width} ${"x".repeat(60)}`);
      await page.getByRole("button", {name: "Create app password", exact: true}).click();
      const secret = page.locator("#dav-secret");
      await expect(secret).toBeVisible();
      expect((await secret.inputValue()).startsWith("kith_dav_")).toBe(true);
      expect(await secret.locator('..').getAttribute('data-copy-value')).toBeNull();
      expect(await page.evaluate(() => Object.values({...localStorage, ...sessionStorage}).some(value => String(value).includes('kith_dav_')))).toBe(false);
      await page.evaluate(() => { (window as any).clipboardTest.mode = "reject"; });
      await copyButton(page).click();
      expect(browserErrors).toEqual([]);
      await expect(page.getByRole("status").filter({hasText: /copy.*manually/i})).toBeVisible();
      await secret.focus();
      await page.keyboard.press("ControlOrMeta+A");
      expect(await secret.evaluate((input: HTMLInputElement) => input.selectionEnd! - input.selectionStart! === input.value.length)).toBe(true);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.getByRole("link", {name: "Done", exact: true}).click();
      await expect(secret).toHaveCount(0);
      await page.getByRole("link", {name: "Create app password", exact: true}).click();
      await page.getByLabel("Device name").fill("Reload test");
      await page.getByRole("button", {name: "Create app password", exact: true}).click();
      await expect(secret).toBeVisible();
      await page.reload();
      await expect(secret).toHaveCount(0);
      await page.getByLabel("Device name").fill("Reconnect test");
      await page.getByRole("button", {name: "Create app password", exact: true}).click();
      await expect(secret).toBeVisible();
      await page.evaluate(() => (window as any).liveSocket.disconnect());
      await page.evaluate(() => (window as any).liveSocket.connect());
      await expect(secret).toHaveCount(0);
      await page.getByRole("link", {name: "Cancel", exact: true}).click();
      await page.getByRole('link', {name: 'Revoke', exact: true}).last().click();
      await expect(page.getByRole('button', {name: 'Revoke app password', exact: true})).toBeVisible();
      await page.getByRole('button', {name: 'Revoke app password', exact: true}).click();
      await expect(page.locator('#dav-app-passwords')).toBeVisible();
      await expect(page.getByText('App password revoked', {exact: true})).toBeVisible();
    } finally {
      await page.close();
    }
  });
}
