import { test, expect } from "@playwright/test";
import { prepare, loginOidc, control, logout } from "./helpers/oidc";

test.beforeEach(async ({ page }) => {
  const viewer = await prepare({ role: "viewer" });
  await loginOidc(page, viewer);
});
test.afterEach(async ({ page }) => { await page.close(); });

test("mobile settings select navigates to personal sync", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto("/settings/security");
  await page.getByLabel("Settings", { exact: true }).selectOption("/settings/contact-sync");
  await expect(page).toHaveURL(/\/settings\/contact-sync$/);
  await expect(page.getByRole("heading", { name: "Contact sync", exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

for (const width of [1366, 1440, 320, 393]) {
  test(`settings destinations, role boundaries and responsive history at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/settings/security");
    const mobile = page.getByLabel("Settings", { exact: true });
    const nav = page.getByRole("navigation", { name: "Settings sections", exact: true });
    const destinations = [
      ["Profile", "/users/settings"], ["Security", "/settings/security"], ["Contact sync", "/settings/contact-sync"],
      ["Tags", "/settings/tags"], ["Emotions", "/settings/emotions"], ["Activity Types", "/settings/activity-types"],
      ["Life Event Types", "/settings/life-event-types"], ["Import History", "/settings/imports"], ["Export", "/settings/export"],
    ];
    for (const [label, path] of destinations) {
      if (width < 768) {
        await expect(mobile).toBeVisible(); await mobile.focus(); await expect(mobile).toBeFocused(); await mobile.selectOption(path);
        await expect(mobile).toHaveValue(path);
      } else {
        const link = nav.getByRole("link", { name: label, exact: true }); await link.focus(); await link.press("Enter");
        await expect(link).toHaveAttribute("aria-current", "page");
      }
      await expect(page).toHaveURL(new RegExp(path + "$"));
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    }
    await page.goto("/users/settings");
    await expect(page.locator("#email_form")).toBeVisible(); await expect(page.locator("#password_form")).toHaveCount(0);
    for (const path of ["/settings/account", "/settings/integrations", "/settings/audit-log", "/settings/import"]) {
      await page.goto(path); await expect(page).not.toHaveURL(new RegExp(path + "$"));
    }
    await page.goto("/settings/contact-sync");
    await page.setViewportSize({ width: 1440, height: 900 });
    await expect(nav).toBeVisible(); await expect(nav.getByRole("heading")).toHaveText(["Personal", "Workspace", "Data"]);
    await expect(nav.getByRole("link", { name: "Integrations", exact: true })).toHaveCount(0);
    await expect(nav.getByRole("link", { name: "Import", exact: true })).toHaveCount(0);
    await expect(nav.getByRole("link", { name: "Contact sync", exact: true })).toHaveAttribute("aria-current", "page");
    await page.setViewportSize({ width: 375, height: 812 }); await expect(mobile).toBeVisible();
    await mobile.selectOption("/settings/security"); await expect(page).toHaveURL(/\/settings\/security$/);
    await page.goBack(); await expect(page).toHaveURL(/\/settings\/contact-sync$/);
    await page.setViewportSize({ width: 1440, height: 900 }); await expect(nav).toBeVisible();
  });
}

test("administrator retains Integrations and its Immich permission boundary", async ({ page }) => {
  await logout(page);
  const admin = await prepare(); await loginOidc(page, admin);
  await page.setViewportSize({ width: 1440, height: 900 });
  for (const [label, path] of [["Import", "/settings/import"], ["Account", "/settings/account"], ["Audit Log", "/settings/audit-log"], ["Integrations", "/settings/integrations"]]) {
    await page.goto(path);
    await expect(page).toHaveURL(new RegExp(path + "$"));
    await expect(page.getByRole("navigation", { name: "Settings sections", exact: true }).getByRole("link", { name: label, exact: true })).toHaveAttribute("aria-current", "page");
  }
  await expect(page.getByRole("navigation", { name: "Settings sections", exact: true }).getByRole("link", { name: "Integrations", exact: true })).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("heading", { name: "Immich Photo Integration", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Contact sync", exact: true }).last()).toBeVisible();
});

test("email confirmation returns to Profile and password form remains in Security", async ({ page }) => {
  await logout(page);
  const viewer = await prepare(); await loginOidc(page, viewer);
  await page.goto("/users/settings");
  const email = `updated-${Date.now()}@example.test`;
  await page.locator("#email_form").getByLabel("Email", { exact: true }).fill(email);
  await page.getByRole("button", { name: "Change Email", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: /link to confirm your email/i })).toBeVisible();
  const { url } = await control("email_confirmation", { user_id: viewer.user_id, email });
  try { await page.goto(url); } catch { throw new Error("Email confirmation navigation failed"); }
  await expect(page).toHaveURL(/\/users\/settings$/);
  await expect(page.locator("#email_form").getByLabel("Email", { exact: true })).toHaveValue(email);
  await expect(page.locator("#password_form")).toHaveCount(0);
});
