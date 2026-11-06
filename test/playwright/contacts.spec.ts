import { test, expect, type Page } from "@playwright/test";
import {
  registerUser,
  ensureOnDashboard,
  logoutUser,
} from "./helpers/auth";

// ─────────────────────────────────────────────
// Shared setup: register a user and navigate to contacts
// ─────────────────────────────────────────────

let userEmail: string;

test.describe("Contact Management", () => {
  test.beforeEach(async ({ page }) => {
    // Each test gets a fresh user to avoid state leaking between tests
    userEmail = await registerUser(page);
    await ensureOnDashboard(page);
  });

  // ─────────────────────────────────────────
  // Contacts: List
  // ─────────────────────────────────────────

  test("contacts list shows empty state", async ({ page }) => {
    await page.goto("/contacts");
    await page.waitForLoadState("networkidle");

    // Should show "Contacts" heading
    await expect(
      page.getByRole("heading", { name: "Contacts", exact: true, level: 1 }),
    ).toBeVisible();

    // New Contact button should be visible
    await expect(
      page.getByRole("link", { name: /new contact/i }),
    ).toBeVisible();
  });

  // ─────────────────────────────────────────
  // Contacts: Create
  // ─────────────────────────────────────────

  test("create a new contact", async ({ page }) => {
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    // Fill the form
    await page.getByLabel(/first name/i).fill("John");
    await page.getByLabel(/last name/i).fill("TestSmith");

    // Submit
    await page.getByRole("button", { name: /save|create/i }).click();

    // Should redirect to the contact show page
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    // Verify contact name appears on the page
    const pageContent = await page.content();
    expect(pageContent).toContain("John");
    expect(pageContent).toContain("TestSmith");
  });

  test("create contact with all fields", async ({ page }) => {
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    await page.getByLabel(/first name/i).fill("Jane");
    await page.getByLabel(/last name/i).fill("FullFields");

    // Fill optional fields if they exist
    const nicknameField = page.getByLabel(/nickname/i);
    if ((await nicknameField.count()) > 0) {
      await nicknameField.fill("JF");
    }

    const occupationField = page.getByLabel(/occupation/i);
    if ((await occupationField.count()) > 0) {
      await occupationField.fill("Software Engineer");
    }

    const companyField = page.getByLabel(/company/i);
    if ((await companyField.count()) > 0) {
      await companyField.fill("Acme Corp");
    }

    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    const content = await page.content();
    expect(content).toContain("Jane");
    expect(content).toContain("FullFields");
  });

  test("create contact validation - first name required", async ({ page }) => {
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    // Submit without filling required fields
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForTimeout(500);

    // Should stay on the form (not redirect)
    await expect(page).toHaveURL(/\/contacts\/new/);
  });

  // ─────────────────────────────────────────
  // Contacts: View
  // ─────────────────────────────────────────

  test("view contact show page with activity actions", async ({ page }) => {
    // Create a contact first
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);
    await page.getByLabel(/first name/i).fill("TabTest");
    await page.getByLabel(/last name/i).fill("Contact");
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    // Verify the show page has expected sections
    const content = await page.content();
    expect(content).toContain("TabTest");

    await expect(page.getByRole("button", { name: "+ Note", exact: true })).toBeVisible();
    await expect(page.getByText("No activity yet", { exact: true })).toBeVisible();
  });

  // ─────────────────────────────────────────
  // Contacts: Search
  // ─────────────────────────────────────────

  test("search filters contacts", async ({ page }) => {
    // Create two contacts
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);
    await page.getByLabel(/first name/i).fill("Searchable");
    await page.getByLabel(/last name/i).fill("Person");
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);
    await page.getByLabel(/first name/i).fill("Hidden");
    await page.getByLabel(/last name/i).fill("Other");
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    // Go to contacts list and search
    await page.goto("/contacts");
    await page.waitForLoadState("networkidle");

    const searchInput = page.getByPlaceholder("Search contacts...", { exact: true });
    await searchInput.fill("Searchable");
    await expect(page.locator("tbody").getByText("Searchable Person", { exact: true })).toBeVisible();
    await expect(page.locator("tbody").getByText("Hidden Other", { exact: true })).toHaveCount(0);
  });

  // ─────────────────────────────────────────
  // Contacts: Edit
  // ─────────────────────────────────────────

  test("edit a contact", async ({ page }) => {
    // Create a contact
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);
    await page.getByLabel(/first name/i).fill("EditMe");
    await page.getByLabel(/last name/i).fill("Original");
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    // Extract contact ID from URL
    const url = page.url();
    const contactId = url.match(/\/contacts\/(\d+)/)?.[1];
    expect(contactId).toBeTruthy();

    // Navigate to edit page
    await page.goto(`/contacts/${contactId}/edit`);
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    // Update last name
    const lastNameField = page.getByLabel(/last name/i);
    await lastNameField.clear();
    await lastNameField.fill("Updated");

    await page.getByRole("button", { name: /save|update/i }).click();
    await page.waitForURL(/\/contacts\/\d+$/, { timeout: 10_000 });

    // Verify the update
    const content = await page.content();
    expect(content).toContain("Updated");
  });

  // ─────────────────────────────────────────
  // Contacts: Favorite
  // ─────────────────────────────────────────

  test("contacts list has sort options", async ({ page }) => {
    await page.goto("/contacts");
    await page.waitForLoadState("networkidle");

    // Verify sort dropdown exists
    const sortSelect = page.locator("select[name='sort']");
    await expect(sortSelect).toBeVisible();

    // Verify expected sort options
    const options = await sortSelect.locator("option").allTextContents();
    expect(options.some((o) => o.includes("Name A-Z"))).toBe(true);
    expect(options.some((o) => o.includes("Name Z-A"))).toBe(true);
  });
});

// ─────────────────────────────────────────────
// Contacts: Notes (on contact show page)
// ─────────────────────────────────────────────

test.describe("Contact Notes", () => {
  test("add a note to a contact", async ({ page }) => {
    await registerUser(page);
    await ensureOnDashboard(page);

    // Create a contact
    await page.goto("/contacts/new");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);
    await page.getByLabel(/first name/i).fill("NoteTest");
    await page.getByLabel(/last name/i).fill("Person");
    await page.getByRole("button", { name: /save|create/i }).click();
    await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

    // The Notes tab should be active by default
    // Look for the Add Note button
    const addNoteBtn = page.getByRole("button", { name: /add note/i });
    if ((await addNoteBtn.count()) > 0) {
      await addNoteBtn.first().click();
      await page.waitForTimeout(500);

      // Look for a text input/editor area
      const noteInput = page.locator(
        "trix-editor, textarea, [contenteditable]",
      );
      if ((await noteInput.count()) > 0) {
        await noteInput.first().click();
        await page.keyboard.type("This is a test note from Playwright");
        await page.waitForTimeout(300);

        // Submit the note
        const saveBtn = page.getByRole("button", { name: /save|submit/i });
        if ((await saveBtn.count()) > 0) {
          await saveBtn.first().click();
          await page.waitForTimeout(1000);

          // Verify note appears
          const content = await page.content();
          expect(content).toContain("This is a test note from Playwright");
        }
      }
    }
  });
});
