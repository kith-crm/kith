import { type Page, expect } from "@playwright/test";

/**
 * Create a contact via the UI and return its ID extracted from the URL.
 */
export async function createContact(
  page: Page,
  opts: { firstName: string; lastName?: string },
): Promise<number> {
  await page.goto("/contacts/new");
  await page.waitForLoadState("networkidle");
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);

  await page.getByLabel(/first name/i).fill(opts.firstName);
  if (opts.lastName) {
    await page.getByLabel(/last name/i).fill(opts.lastName);
  }

  await page.getByRole("button", { name: /save|create/i }).click();
  await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });

  const url = page.url();
  const match = url.match(/\/contacts\/(\d+)/);
  if (!match) throw new Error(`Could not extract contact ID from URL: ${url}`);
  return parseInt(match[1], 10);
}

/**
 * Navigate to a contact's detail page.
 */
export async function goToContact(
  page: Page,
  contactId: number,
): Promise<void> {
  await page.goto(`/contacts/${contactId}`);
  await page.waitForLoadState("networkidle");
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
}

/**
 * Add a phone number to the current contact page via the Contact Fields section.
 */
export async function addPhoneToContact(
  page: Page,
  phoneNumber: string,
  label?: string,
): Promise<void> {
  // Find the "Contact Info" section and click the + button to show the form
  const section = page.locator("text=Contact Info").first();
  await section.waitFor({ state: "visible", timeout: 5000 });

  // The + button is next to the "Contact Info" heading
  const addBtn = page.locator(
    'button[phx-click="show-form"]',
  );
  // There may be multiple show-form buttons (addresses, contact fields, etc.)
  // Find the one inside the Contact Info section
  const contactInfoAddBtn = section
    .locator("..")
    .locator('button[phx-click="show-form"]');
  if ((await contactInfoAddBtn.count()) > 0) {
    await contactInfoAddBtn.first().click();
  } else if ((await addBtn.count()) > 0) {
    // Fallback: click any show-form button near Contact Info
    await addBtn.nth(1).click(); // Second one is usually contact fields
  }
  await page.waitForTimeout(500);

  // Select Phone type from the dropdown
  const typeSelect = page.locator(
    'select[name="contact_field[contact_field_type_id]"]',
  );
  await typeSelect.waitFor({ state: "visible", timeout: 5000 });

  // Find and select the Phone option
  const options = await typeSelect.locator("option").all();
  for (const option of options) {
    const text = await option.textContent();
    if (text?.toLowerCase().includes("phone")) {
      const value = await option.getAttribute("value");
      if (value) await typeSelect.selectOption(value);
      break;
    }
  }

  // Fill the value
  const valueInput = page.locator(
    'input[name="contact_field[value]"]',
  );
  await valueInput.fill(phoneNumber);

  if (label) {
    const labelInput = page.locator(
      'input[name="contact_field[label]"]',
    );
    if ((await labelInput.count()) > 0) {
      await labelInput.fill(label);
    }
  }

  // Submit the form — the Save button near the contact field form
  // Use the form that contains our value input
  await page
    .locator('input[name="contact_field[value]"]')
    .locator("..")
    .locator("..")
    .locator("..")
    .locator('button:has-text("Save")')
    .click();
  await page.waitForTimeout(800);
}

/**
 * Navigate to the import wizard.
 */
export async function goToImportWizard(page: Page): Promise<void> {
  await page.goto("/settings/import");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(500);
}

/**
 * Upload a vCard file in the import wizard.
 * Assumes we're already on the import wizard page with vCard source selected.
 */
export async function uploadVcardImport(
  page: Page,
  fixturePath: string,
): Promise<void> {
  // vCard should be selected by default
  const fileInput = page.locator('input[type="file"]');
  await fileInput.setInputFiles(fixturePath);
  await page.waitForTimeout(500);

  // Click continue
  await page.getByRole("button", { name: /continue/i }).click();
  await page.waitForTimeout(500);

  // Click start import
  await page.getByRole("button", { name: /start import/i }).click();

  // Wait for import to complete
  await page.waitForSelector("text=/import complete|completed/i", {
    timeout: 30_000,
  });
}
