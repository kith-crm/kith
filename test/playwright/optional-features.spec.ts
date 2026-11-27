import { expect, test } from "@playwright/test";
import { registerUser } from "./helpers/auth";
import { createContact } from "./helpers/contacts";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY1kAAAAASUVORK5CYII=",
  "base64",
);

for (const width of [1440, 375]) {
  test(`optional features and the all-off timeline at ${width}px`, async ({ page }) => {
    test.setTimeout(150_000);
    await page.setViewportSize({ width, height: 900 });
    await registerUser(page);

    const journal = page.locator('a[href="/journal"]');
    await expect(journal).toHaveCount(0);
    await page.goto("/journal");
    await expect(page.getByRole("heading", { name: "Journal is unavailable" })).toBeVisible();
    await page.getByRole("link", { name: "Optional features", exact: true }).click();
    const section = page.locator("#optional-features");
    await expect(section.getByRole("switch", { checked: false })).toHaveCount(7);
    const journalSwitch = section.getByRole("switch", { name: "Journal" });
    await journalSwitch.click();
    await expect(journalSwitch).toBeChecked();
    if (width < 768) {
      await page.getByRole("button", { name: "More", exact: true }).click();
      await expect(page.getByRole("menuitem", { name: "Journal" })).toBeVisible();
      await page.keyboard.press("Escape");
    } else {
      await expect(page.getByRole("link", { name: "Journal", exact: true })).toBeVisible();
    }
    await journalSwitch.click();
    await expect(journalSwitch).not.toBeChecked();
    await expect(journal).toHaveCount(0);

    await createContact(page, { firstName: "Optional Features" });
    const timeline = page.locator("#activity-stream");
    await expect(timeline.locator('[phx-click="open-entry-modal"]')).toHaveCount(2);
    await timeline.getByRole("button", { name: "+ Note", exact: true }).click();
    await page.locator("trix-editor").fill("Note with all optional features off");
    await page.getByRole("button", { name: "Save", exact: true }).click();
    await expect(timeline.getByText("Note with all optional features off", { exact: true }).first()).toBeVisible();

    await timeline.getByRole("button", { name: "Add timeline entry" }).click();
    await timeline.getByRole("button", { name: "+ Photo", exact: true }).click();
    const upload = page.locator("#photo-upload-form");
    await upload.locator('input[type="file"]').setInputFiles({ name: "timeline.png", mimeType: "image/png", buffer: png });
    await upload.locator('button[type="submit"]').click();
    await expect(timeline.locator('[id^="activity-photo-"]')).toBeVisible();
  });
}
