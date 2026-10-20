import { test, expect, type Page } from "@playwright/test";
import { registerUser, ensureOnDashboard, TEST_PASSWORD } from "./helpers/auth";

const MONICA_URL = process.env.MONICA_URL_FROM_KITH ?? process.env.MONICA_URL;
const MONICA_KEY = process.env.MONICA_API_KEY;
const MAILPIT_URL = process.env.MAILPIT_URL ?? "http://localhost:8025";

test.skip(!MONICA_URL || !MONICA_KEY, "MONICA_URL and MONICA_API_KEY are not set");

async function waitConnected(page: Page) {
  await page.waitForSelector("[data-phx-main].phx-connected");
}

// Registration needs a confirmed email; follow the link Kith mailed to Mailpit.
async function confirmEmail(page: Page, email: string) {
  let path: string | undefined;
  await expect
    .poll(
      async () => {
        const res = await page.request.get(
          `${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`,
        );
        const { messages } = await res.json();
        if (!messages?.length) return undefined;
        const msg = await (
          await page.request.get(`${MAILPIT_URL}/api/v1/message/${messages[0].ID}`)
        ).json();
        path = msg.Text.match(/\/users\/confirm\/[\w-]+/)?.[0];
        return path;
      },
      { timeout: 30_000 },
    )
    .toBeTruthy();
  await page.goto(path!);
  await waitConnected(page);
  await page.getByRole("button", { name: /confirm/i }).click();
  await page.waitForURL(/\/users\/log-in/, { timeout: 15_000 });
  // The login form comes back with the email prefilled and read-only.
  await waitConnected(page);
  await page.locator('input[type="password"]').fill(TEST_PASSWORD);
  await page.getByRole("button", { name: /log in/i }).click();
  await page.waitForURL(/\/(dashboard|users\/settings)/, { timeout: 15_000 });
}

async function reminderLines(page: Page, contactId: string): Promise<string[]> {
  await page.goto(`/contacts/${contactId}`);
  await waitConnected(page);
  await page.getByRole("button", { name: /Reminders, Pets, Debts/ }).click();
  const items = page.locator(`#reminders-${contactId} div.group`);
  await expect(items.first()).toBeVisible();
  return (await items.allInnerTexts()).map((t) => t.replace(/\s*\n\s*/g, " | "));
}

test("Monica 4.1.2 reminders import faithfully", async ({ page }) => {
  test.setTimeout(300_000);
  const email = await registerUser(page);
  await ensureOnDashboard(page);
  await confirmEmail(page, email);

  await page.goto("/settings/import");
  await waitConnected(page);
  await page.getByRole("radio", { name: /Monica CRM \(API\)/ }).check();
  const url = page.getByPlaceholder("https://your-monica-instance.com");
  await url.fill(MONICA_URL!);
  await url.blur();
  const key = page.getByPlaceholder("Your Monica API key");
  await key.fill(MONICA_KEY!);
  await key.blur();
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("button", { name: "Start import" }).click();
  await expect(page.getByText(/Import complete/i)).toBeVisible({ timeout: 240_000 });

  await page.goto("/contacts");
  await waitConnected(page);
  // Dora E2E is deceased; the list hides deceased contacts by default.
  await page.getByLabel("Include deceased").check();
  await expect(page.getByText("Dora E2E").first()).toBeVisible();
  const ids = new Map<string, string>();
  for (const a of await page.locator('a[href^="/contacts/"]').all()) {
    const href = (await a.getAttribute("href")) ?? "";
    const m = href.match(/^\/contacts\/(\d+)$/);
    const name = (await a.innerText()).trim();
    if (m && name) ids.set(name.split("\n")[0], m[1]);
  }
  const id = (name: string): string => {
    const v = ids.get(name);
    expect(v, `contact ${name} imported`).toBeTruthy();
    return v!;
  };

  // Birthdays: exactly one Birthday line, no generic duplicate (spec §8).
  for (const name of ["Mona Vale", "Yara E2E", "Dora E2E", "Fiona E2E"]) {
    const lines = await reminderLines(page, id(name));
    expect(lines.filter((l) => /Birthday · Annually/.test(l))).toHaveLength(1);
    expect(lines.some((l) => /Wish happy birthday|would have celebrated/.test(l))).toBe(false);
  }

  // 29 Feb contact page loads.
  await page.goto(`/contacts/${id("Paul Stone")}`);
  await expect(page.getByText(/Birthday in/)).toBeVisible();

  const gina = await reminderLines(page, id("Gina E2E"));
  expect(gina.some((l) => /Water plants .*Every 2 weeks/.test(l))).toBe(true);
  expect(gina.some((l) => /Quarterly review .*Every 3 months/.test(l))).toBe(true);
  expect(gina.some((l) => /Leap-day thing .*Every 2 years/.test(l))).toBe(true);
  expect(gina.some((l) => /Zero frequency .*One-time/.test(l))).toBe(true);
  expect(gina.some((l) => /Stay in touch .*Every 14 days/.test(l))).toBe(true);
  expect(gina.some((l) => /One-time future .*Has a description/.test(l))).toBe(true);

  const fiona = await reminderLines(page, id("Fiona E2E"));
  expect(fiona.some((l) => /First met/.test(l))).toBe(true);
  expect(fiona.some((l) => /Fiona birthday party/.test(l))).toBe(false);

  // Exact next dates are pinned by ExUnit with a fixed `today` (Task A6/A7);
  // here only the "no date clamped to today" invariant is checked.
  const solo = await reminderLines(page, id("Solo One"));
  const wedding = solo.find((l) => /Wedding anniversary/.test(l))!;
  expect(wedding).toMatch(/Next: Mar 9, \d{4}/);
});
