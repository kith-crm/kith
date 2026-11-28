import { test, expect } from "@playwright/test";
import { registerUser, ensureOnDashboard } from "./helpers/auth";

test.describe("Settings", () => {
  test.setTimeout(150_000);
  test.beforeEach(async ({ page }) => {
    await registerUser(page);
    await ensureOnDashboard(page);
  });

  // ─────────────────────────────────────────
  // Settings: User Profile
  // ─────────────────────────────────────────

  test("user settings page loads", async ({ page }) => {
    await page.goto("/users/settings");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/users\/settings/);

    await expect(page.locator("#email_form")).toBeVisible();
    await expect(page.locator("#password_form")).toHaveCount(0);
  });

  test("user settings shows email form", async ({ page }) => {
    await page.goto("/users/settings");
    await page.waitForLoadState("networkidle");

    const emailInput = page.locator("#email_form input[type='email']");
    await expect(emailInput).toHaveValue(/@/);
    await expect(page.locator("#password_form")).toHaveCount(0);
  });

  // ─────────────────────────────────────────
  // Settings: Account
  // ─────────────────────────────────────────

  test("account settings page loads", async ({ page }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/account/);

    const content = await page.content();
    expect(content).toMatch(/account|timezone|features/i);
  });

  test("account settings danger zone shows reset and delete sections", async ({
    page,
  }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");

    const content = await page.content();
    expect(content).toMatch(/reset account data/i);
    expect(content).toMatch(/delete account/i);
  });

  test("account reset with wrong confirmation stays disabled", async ({ page }) => {
    await page.goto("/settings/account");
    const form = page.locator("#account-reset-form");
    await form.locator("input[name='confirmation']").fill("WRONG");
    await expect(form.getByRole("button", { name: "Reset Account Data", exact: true })).toBeDisabled();
  });

  test("account reset with correct confirmation enqueues reset job", async ({ page }) => {
    await page.goto("/settings/account");
    const form = page.locator("#account-reset-form");
    await form.locator("input[name='confirmation']").fill("RESET");
    const submit = form.getByRole("button", { name: "Reset Account Data", exact: true });
    await expect(submit).toBeEnabled();
    await submit.click();
    await expect(page.getByRole("alert").filter({ hasText: "Account data reset has been queued." })).toBeVisible();
  });

  test("account delete with wrong confirmation stays disabled", async ({ page }) => {
    await page.goto("/settings/account");
    const form = page.locator("#account-delete-form");
    await form.locator("input[name='confirmation']").fill("WRONG");
    await expect(form.getByRole("button", { name: "Delete Account Permanently", exact: true })).toBeDisabled();
  });

  // ─────────────────────────────────────────
  // Settings: Tags
  // ─────────────────────────────────────────

  test("tags settings page loads", async ({ page }) => {
    await page.goto("/settings/tags");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/tags/);
  });

  test("create a tag", async ({ page }) => {
    await page.goto("/settings/tags");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const form = page.locator("#tag-settings-form");
    await form.locator("input[name='tag[name]']").fill("PlaywrightTag");
    await form.getByRole("button", { name: "Create", exact: true }).click();
    await expect(page.locator(".badge").filter({ hasText: "PlaywrightTag" })).toBeVisible();
  });

  // ─────────────────────────────────────────
  // Settings: Integrations
  // ─────────────────────────────────────────

  test("integrations settings page loads", async ({ page }) => {
    await page.goto("/settings/integrations");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/integrations/);

    const content = await page.content();
    expect(content).toMatch(/immich|integration/i);
  });

  // ─────────────────────────────────────────
  // Settings: Import
  // ─────────────────────────────────────────

  test("import page loads with file upload", async ({ page }) => {
    await page.goto("/settings/import");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/import/);

    const content = await page.content();
    expect(content).toMatch(/import|vcf|vcard|upload/i);
  });

  // ─────────────────────────────────────────
  // Settings: Export
  // ─────────────────────────────────────────

  test("export page loads with download options", async ({ page }) => {
    await page.goto("/settings/export");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/export/);

    const content = await page.content();
    expect(content).toMatch(/export|download|vcard/i);
  });

  // ─────────────────────────────────────────
  // Settings: Audit Log
  // ─────────────────────────────────────────

  test("audit log page loads", async ({ page }) => {
    await page.goto("/settings/audit-log");
    await page.waitForLoadState("networkidle");

    await expect(page).toHaveURL(/\/settings\/audit-log/);

    const content = await page.content();
    expect(content).toMatch(/audit|log|event/i);
  });

  // ─────────────────────────────────────────
  // Settings: Navigation between sections
  // ─────────────────────────────────────────

  test("settings sidebar navigation works", async ({ page }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");

    const nav = page.getByRole("navigation", { name: "Settings sections", exact: true });
    await expect(nav.getByRole("heading")).toHaveText(["Personal", "Workspace", "Data"]);
    for (const [label, path] of [["Tags", "/settings/tags"], ["Integrations", "/settings/integrations"], ["Security", "/settings/security"]]) {
      const link = nav.getByRole("link", { name: label, exact: true });
      await link.focus();
      await link.press("Enter");
      await expect(page).toHaveURL(new RegExp(`${path}$`));
      await expect(link).toHaveAttribute("aria-current", "page");
    }
    await expect(page.locator("#password_form")).toBeHidden();
    await page.getByText("Change password", { exact: true }).click();
    await expect(page.locator("#password_form")).toBeVisible();
    await expect(page.getByRole("link", { name: "Set up authenticator app", exact: true })).toBeVisible();
    await page.goBack();
    await expect(page).toHaveURL(/\/settings\/integrations$/);
    await expect(nav.getByRole("link", { name: "Integrations", exact: true })).toHaveAttribute("aria-current", "page");
  });
});
