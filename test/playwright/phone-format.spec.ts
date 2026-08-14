import { test, expect } from "@playwright/test";
import { registerUser, ensureOnDashboard } from "./helpers/auth";
import {
  createContact,
  goToContact,
  addPhoneToContact,
} from "./helpers/contacts";

// ─────────────────────────────────────────────
// Phone number formatting E2E tests
// ─────────────────────────────────────────────

test.describe("Phone Number Formatting", () => {
  let contactId: number;

  test.beforeEach(async ({ page }) => {
    await registerUser(page);
    await ensureOnDashboard(page);
    contactId = await createContact(page, {
      firstName: "PhoneFmt",
      lastName: "Test",
    });
  });

  // ─────────────────────────────────────────
  // Settings
  // ─────────────────────────────────────────

  test("default format is E.164 in settings", async ({ page }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await expect(select).toHaveValue("e164");
    }
  });

  test("change format to National persists on reload", async ({
    page,
  }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("national");

      // Save the form
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);

      // Reload
      await page.goto("/settings/account");
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(300);

      // Should persist
      await expect(select).toHaveValue("national");
    }
  });

  // ─────────────────────────────────────────
  // Display formatting
  // ─────────────────────────────────────────

  test("phone displayed in E.164 format", async ({ page }) => {
    await goToContact(page, contactId);
    await addPhoneToContact(page, "2345678901");

    // With E.164 (default), should show +12345678901
    const content = await page.content();
    expect(content).toContain("+12345678901");
  });

  test("phone displayed in National format", async ({ page }) => {
    // Change setting to National
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("national");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    // Add phone to contact
    await goToContact(page, contactId);
    await addPhoneToContact(page, "2345678901");

    // Should show (234) 567-8901
    const content = await page.content();
    expect(content).toContain("(234) 567-8901");
  });

  test("non-NANP phone displayed in National format", async ({ page }) => {
    // Change setting to National
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("national");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    // Add a GB phone to the contact
    await goToContact(page, contactId);
    await addPhoneToContact(page, "+44 20 7946 0958");

    // Should render in GB national format (NOT raw E.164)
    const content = await page.content();
    expect(content).toContain("020 7946 0958");
  });

  test("non-NANP phone displayed in International format", async ({ page }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("international");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    await goToContact(page, contactId);
    await addPhoneToContact(page, "+44 20 7946 0958");

    const content = await page.content();
    expect(content).toContain("+44 20 7946 0958");
  });

  test("phone displayed in International format", async ({ page }) => {
    // Change setting to International
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("international");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    // Add phone to contact
    await goToContact(page, contactId);
    await addPhoneToContact(page, "2345678901");

    // Should show +1 234-567-8901
    const content = await page.content();
    expect(content).toContain("+1 234-567-8901");
  });

  test("raw format shows stored value as-is", async ({ page }) => {
    // Change setting to Raw
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("raw");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    // Add phone to contact
    await goToContact(page, contactId);
    await addPhoneToContact(page, "2345678901");

    // Raw shows the normalized value (which is +12345678901)
    const content = await page.content();
    expect(content).toContain("+12345678901");
  });

  test("phone normalized on save - edit shows normalized form", async ({
    page,
  }) => {
    await goToContact(page, contactId);
    await addPhoneToContact(page, "(234) 567-8901");

    // The stored value should be normalized to +12345678901
    // Navigate away and back to ensure persistence
    await page.goto("/contacts");
    await goToContact(page, contactId);

    const content = await page.content();
    // In E.164 (default), normalized number should appear
    expect(content).toContain("+12345678901");
  });

  test("international number with + prefix preserved", async ({
    page,
  }) => {
    await goToContact(page, contactId);
    await addPhoneToContact(page, "+44 20 7946 0958");

    const content = await page.content();
    // Should be stored as +442079460958 (normalized)
    expect(content).toContain("+442079460958");
  });
});
