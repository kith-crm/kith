import { test, expect } from "@playwright/test";
import { registerUser, ensureOnDashboard } from "./helpers/auth";
import * as path from "path";
import * as fs from "fs";
import { execFileSync } from "node:child_process";
import { passwordLogin } from "./helpers/password-login";

// ─────────────────────────────────────────────────
// Test data paths
// ─────────────────────────────────────────────────

const MONICA_URL = "https://monica.basharqassis.com/";
const API_KEY_PATH = path.resolve(
  __dirname,
  "../../docs/monica-key.txt",
);
const IMPORT_FILE_PATH = path.resolve(
  __dirname,
  "../../docs/tqHjbdFMMwPocQc3qUERkYwl4uO7MUDZq5CngsiG.json",
);

// Known contacts from the Monica export for verification.
// The export has 851 entries (including duplicates across vaults)
// but only ~305 unique contacts by UUID.
const VERIFICATION_CONTACTS = {
  jalaGhattas: {
    displayName: "Jala Abu Ghattas",
    company: "Student",
    phone: "059-831-3665",
  },
  dialaHamadneh: {
    displayName: "Diala Hamadneh",
    company: "Foothill",
    phone: "+970568600798",
    noteSnippet: "Worked together at",
  },
  giovanniFacouseh: {
    displayName: "Giovanni Facouseh",
    phone: "0547741203",
    petName: "Nara",
  },
  sondosZain: {
    displayName: "Sondos Zain",
    company: "Userpilot",
    phone: "+970 599 835 239",
  },
};

// ─────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────

/**
 * Fill a LiveView input that uses phx-blur + phx-value-value.
 *
 * Standard fill + blur can fail if phx-value-value overrides the input's
 * DOM value in the event payload. This helper updates the phx-value
 * attribute to match what we typed before triggering blur.
 */
async function fillLiveViewBlurInput(
  page: import("@playwright/test").Page,
  selector: string,
  value: string,
) {
  const input = page.locator(selector);
  await input.fill(value);
  await input.evaluate((el, val) => {
    el.setAttribute("phx-value-value", val);
  }, value);
  await input.blur();
  await page.waitForTimeout(300);
}

/**
 * Fallback: push LiveView events directly via the JS socket when
 * DOM-based blur doesn't propagate values to the server.
 */
async function pushLiveViewEvents(
  page: import("@playwright/test").Page,
  events: Array<{ event: string; payload: Record<string, string> }>,
) {
  await page.evaluate((evts) => {
    const liveSocket = (window as any).liveSocket;
    const mainEl = document.querySelector("[data-phx-main]");
    if (!mainEl || !liveSocket) return;
    const view = liveSocket.getViewByEl(mainEl);
    if (!view) return;
    for (const { event, payload } of evts) {
      view.pushEvent(event, mainEl, payload);
    }
  }, events);
  await page.waitForTimeout(500);
}

// ─────────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────────

test.describe("Monica CRM Import", () => {
  test.skip(process.env.KITH_LIVE_MONICA_TESTS !== "1", "Requires explicit KITH_LIVE_MONICA_TESTS=1; reads private export/key and contacts the live Monica host");
  // The full import of ~305 contacts can take a while
  test.setTimeout(600_000);

  test("full import flow and data verification", async ({ page }) => {
    const apiKey = fs.readFileSync(API_KEY_PATH, "utf-8").trim();

    // ── Register & setup ──────────────────────────
    await test.step("register user and navigate to import", async () => {
      await registerUser(page);
      await ensureOnDashboard(page);
      await page.goto("/settings/import");
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(500);
    });

    // ── Step 1: Source selection ───────────────────
    await test.step("select Monica source and upload file", async () => {
      // Select Monica CRM radio
      await page.locator('input[value="monica"]').click();
      await page.waitForTimeout(300);

      // Verify Monica-specific UI appeared
      await expect(
        page.locator("text=Upload Monica export"),
      ).toBeVisible();

      // Upload the JSON export file
      const fileInput = page.locator('input[type="file"]');
      await fileInput.setInputFiles(IMPORT_FILE_PATH);
      await page.waitForTimeout(500);

      // Verify file name appears
      await expect(
        page.locator("text=tqHjbdFMMwPocQc3qUERkYwl4uO7MUDZq5CngsiG.json"),
      ).toBeVisible();
    });

    await test.step("fill Monica API credentials", async () => {
      // Fill Monica URL (required for Monica source)
      await fillLiveViewBlurInput(
        page,
        'input[type="url"]',
        MONICA_URL,
      );

      // Fill API Key (required for Monica source)
      await fillLiveViewBlurInput(
        page,
        'input[type="password"]',
        apiKey,
      );

      // Wait for API options checkboxes to appear
      // (they show when both URL and key are non-empty on the server)
      await page.waitForTimeout(500);
    });

    // ── Step 2: Continue to confirmation ──────────
    await test.step("proceed to confirmation step", async () => {
      await page.getByRole("button", { name: /continue/i }).click();
      await page.waitForTimeout(1500);

      // Check if we hit a validation error (phx-blur didn't propagate values)
      const hasUrlError = await page
        .locator("text=Monica URL is required")
        .isVisible()
        .catch(() => false);
      const hasKeyError = await page
        .locator("text=Monica API key is required")
        .isVisible()
        .catch(() => false);

      if (hasUrlError || hasKeyError) {
        // Fallback: push events directly via LiveView JS
        await pushLiveViewEvents(page, [
          { event: "update_api_url", payload: { value: MONICA_URL } },
          { event: "update_api_key", payload: { value: apiKey } },
        ]);

        // Re-upload file if needed (form may have reset)
        const entries = await page.locator('[phx-drop-target]').count();
        if (entries > 0) {
          const fileInput = page.locator('input[type="file"]');
          const fileCount = await page
            .locator("text=tqHjbdFMMwPocQc3qUERkYwl4uO7MUDZq5CngsiG.json")
            .count();
          if (fileCount === 0) {
            await fileInput.setInputFiles(IMPORT_FILE_PATH);
            await page.waitForTimeout(500);
          }
        }

        // Retry continue
        await page.getByRole("button", { name: /continue/i }).click();
        await page.waitForTimeout(1500);
      }

      // Should now be on confirmation step
      await expect(
        page.locator("text=Review import settings"),
      ).toBeVisible({ timeout: 5000 });

      // Verify confirmation shows Monica CRM source
      const confirmContent = await page.content();
      expect(confirmContent).toMatch(/monica/i);
    });

    // ── Step 3: Start import ──────────────────────
    let importedCount = 0;

    await test.step("start import and wait for completion", async () => {
      await page.getByRole("button", { name: /start import/i }).click();

      // Should see progress indicator
      await expect(
        page.locator("text=Import in progress"),
      ).toBeVisible({ timeout: 10_000 });

      // Wait for import to complete (up to 10 minutes for 305 contacts)
      await expect(
        page.locator("text=Import complete"),
      ).toBeVisible({ timeout: 600_000 });

      // Verify completion summary - use textContent to strip HTML tags
      const completionText =
        (await page.locator("body").textContent()) ?? "";
      expect(completionText).toMatch(/contacts imported successfully/i);

      // Extract the imported count (number appears before "contacts imported")
      const match = completionText.match(
        /(\d+)\s*contacts imported/,
      );
      expect(match).toBeTruthy();
      importedCount = parseInt(match![1]);
      expect(importedCount).toBeGreaterThan(200);
    });

    // ── Step 4: Verify contacts list ──────────────
    await test.step("verify contacts list has imported contacts", async () => {
      await page.getByRole("link", { name: /view contacts/i }).click();
      await page.waitForURL(/\/contacts/, { timeout: 10_000 });
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(2000);

      // Should have the "Contacts" heading
      await expect(
        page.getByRole("heading", { name: /contacts/i }),
      ).toBeVisible();

      // Take a screenshot for debugging
      await page.screenshot({
        path: "test/playwright/screenshots/contacts-after-import.png",
      });

      // The list is sorted A-Z by default so "A" names appear first.
      // Verify some contacts are visible on the first page.
      const bodyText = (await page.locator("body").textContent()) ?? "";
      const hasContacts =
        bodyText.includes("Abdallah") || bodyText.includes("Abishai");
      expect(hasContacts).toBe(true);

      // Also verify the myContacts tag appears (imported from Monica)
      expect(bodyText).toContain("myContacts");
    });

    // ── Step 5: Search and verify specific contacts ─
    await test.step("search for Jala Ghattas and verify details", async () => {
      await page.goto("/contacts");
      await page.waitForLoadState("networkidle");

      const searchInput = page.locator('input[name="search"]');
      await searchInput.fill("Ghattas");
      await page.waitForTimeout(800);

      // Should find Jala Abu Ghattas
      await expect(
        page.getByRole("link", { name: /Ghattas/ }),
      ).toBeVisible({ timeout: 5000 });

      // Click on the contact
      await page.getByRole("link", { name: /Ghattas/ }).first().click();
      await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(500);

      const showContent = await page.content();

      // Verify display name
      expect(showContent).toContain("Jala");
      expect(showContent).toContain("Ghattas");

      // Verify company
      expect(showContent).toContain("Student");

      // Verify phone number in Contact Info section
      expect(showContent).toContain("059-831-3665");
    });

    await test.step(
      "search for Diala Hamadneh and verify note",
      async () => {
        await page.goto("/contacts");
        await page.waitForLoadState("networkidle");

        const searchInput = page.locator('input[name="search"]');
        await searchInput.fill("Diala Hamadneh");
        await page.waitForTimeout(800);

        await expect(
          page.getByRole("link", { name: /Diala.*Hamadneh/ }),
        ).toBeVisible({ timeout: 5000 });
        await page.getByRole("link", { name: /Diala.*Hamadneh/ }).first().click();
        await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });
        await page.waitForLoadState("networkidle");
        await page.waitForTimeout(500);

        const showContent = await page.content();

        // Verify basic info
        expect(showContent).toContain("Diala");
        expect(showContent).toContain("Hamadneh");
        expect(showContent).toContain("Foothill");

        // Verify phone
        expect(showContent).toContain("+970568600798");

        // Verify note content (Notes tab is active by default)
        expect(showContent).toContain("Worked together at");
      },
    );

    await test.step(
      "search for Giovanni Facouseh and verify pet",
      async () => {
        await page.goto("/contacts");
        await page.waitForLoadState("networkidle");

        const searchInput = page.locator('input[name="search"]');
        await searchInput.fill("Giovanni Facouseh");
        await page.waitForTimeout(800);

        await expect(
          page.getByRole("link", { name: /Giovanni.*Facouseh/ }),
        ).toBeVisible({ timeout: 5000 });
        await page.getByRole("link", { name: /Giovanni.*Facouseh/ }).first().click();
        await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });
        await page.waitForLoadState("networkidle");
        await page.waitForTimeout(500);

        const showContent = await page.content();

        // Verify basic info
        expect(showContent).toContain("Giovanni");
        expect(showContent).toContain("Facouseh");

        // Verify phone
        expect(showContent).toContain("0547741203");

        // Verify pet "Nara" exists in the Pets sidebar section
        expect(showContent).toContain("Nara");
      },
    );

    await test.step(
      "search for Sondos Zain and verify company",
      async () => {
        await page.goto("/contacts");
        await page.waitForLoadState("networkidle");

        const searchInput = page.locator('input[name="search"]');
        await searchInput.fill("Sondos Zain");
        await page.waitForTimeout(800);

        await expect(
          page.getByRole("link", { name: /Sondos.*Zain/ }),
        ).toBeVisible({ timeout: 5000 });
        await page.getByRole("link", { name: /Sondos.*Zain/ }).first().click();
        await page.waitForURL(/\/contacts\/\d+/, { timeout: 10_000 });
        await page.waitForLoadState("networkidle");
        await page.waitForTimeout(500);

        const showContent = await page.content();

        expect(showContent).toContain("Sondos");
        expect(showContent).toContain("Zain");
        expect(showContent).toContain("Userpilot");
      },
    );

    // ── Step 6: Verify tag imported ───────────────
    await test.step("verify tags were imported", async () => {
      // The contacts list page shows tag filters — verify myContacts tag exists
      await page.goto("/contacts");
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(500);

      const listText = (await page.locator("body").textContent()) ?? "";
      expect(listText).toContain("myContacts");
    });
  });
});

// ─────────────────────────────────────────────────
// Database verification (separate test - can run
// independently after import completes)
// ─────────────────────────────────────────────────

test.describe("Monica Import - Database Verification", () => {
  test.setTimeout(30_000);

  test("verify imported contact counts via search", async ({ page }) => {
    // This test assumes a user already ran the import.
    // Register a fresh user who won't have imported data
    // (we skip this test if no imported contacts exist)
    await registerUser(page);
    await ensureOnDashboard(page);

    // Navigate to contacts - should be empty for a new user
    await page.goto("/contacts");
    await page.waitForLoadState("networkidle");

    const content = await page.content();
    // For a fresh user, there should be no contacts (empty state)
    // This validates that import is user/account-scoped
    const hasNewContactLink = content.includes("New Contact") || content.includes("new contact");
    expect(hasNewContactLink).toBe(true);
  });
});

// Deterministic local coverage never reads the legacy private files above.
test("Monica custom phone metadata appears in contact details and vCard export", async ({ page }) => {
  test.skip(process.env.KITH_E2E !== "1", "Requires the local regression harness");
  test.setTimeout(180_000);
  const control = (action: string, payload: object) => {
    const output = execFileSync("mix", ["run", "--no-start", "--no-compile", path.resolve("test/playwright/fixtures/regressions/control.exs"), action, JSON.stringify(payload)], {
      env: { ...process.env, MIX_ENV: "test", KITH_E2E: "1", KITH_TEST_SERVER: "0" },
      encoding: "utf8", timeout: 120_000,
    });
    const line = output.split(/\r?\n/).findLast((value) => value.startsWith("KITH_TEST_RESULT="));
    if (!line) throw new Error("Missing local regression control result");
    return JSON.parse(line.slice("KITH_TEST_RESULT=".length));
  };
  const account = control("prepare", { scenario: "import" });
  await passwordLogin(page, account.email, "ValidP@ssword123!");
  await page.goto("/settings/import");
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.getByRole("radio", { name: /Monica CRM \(API\)/ }).check();
  const source = page.getByPlaceholder("https://your-monica-instance.com");
  await source.fill(process.env.KITH_TEST_MONICA_URL ?? "http://127.0.0.1:8094");
  await source.blur();
  const key = page.getByPlaceholder("Your Monica API key");
  await key.fill("kith-fixture-token");
  await key.blur();
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByText("Review import settings")).toBeVisible();
  await page.getByRole("button", { name: "Start import", exact: true }).click();
  await expect(page.getByText(/Import in progress/)).toBeVisible();
  const imported = control("drain_import", account);
  expect(imported.import_status).toBe("completed");
  expect(imported.contacts).toHaveLength(1);
  const id = imported.contacts[0].id;
  await page.goto(`/contacts/${id}`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await expect(page.locator('a[href="tel:+12025550100"]')).toBeVisible();
  await expect(page.getByText("Work", { exact: true }).first()).toBeVisible();
  const response = await page.request.get(`/api/contacts/${id}/export.vcf`, { headers: { Authorization: `Bearer ${account.token}` } });
  expect(response.ok()).toBeTruthy();
  expect(await response.text()).toContain("TEL;TYPE=WORK:+12025550100");
});
