import { test, expect } from "@playwright/test";
import { registerUser } from "./helpers/auth";

test.skip(process.env.KITH_E2E !== "1", "Requires the local regression harness in fixtures/regressions/README.md");

for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
  test.describe(`${viewport.width}px birthdate picker`, () => {
    test.use({ viewport });
    test("yearless birthday calendar survives validation, editing, and precision changes", async ({ page }) => {
      await registerUser(page);
      await page.goto("/contacts/new");
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
      await page.getByLabel("First Name", { exact: true }).fill("Calendar regression");
      const picker = page.locator("[phx-hook=BirthdatePicker]");
      // Browsing an invalid year without choosing a birthday must not make an
      // optional field block contact submission after its panel is dismissed.
      await picker.locator("[data-trigger]").click();
      await picker.getByRole("spinbutton", { name: "Birth year" }).fill("0");
      await picker.locator("[data-trigger]").click();
      expect(await page.locator("#contact-form").evaluate(form => (form as HTMLFormElement).checkValidity())).toBe(true);
      await expect(picker.locator("[data-birthdate]")).toHaveValue("");
      await picker.getByRole("checkbox", { name: "Year unknown" }).check();
      await expect(picker.locator("[data-year]")).toBeHidden();
      await expect(picker.locator("[data-weekdays]")).toBeHidden();
      await expect(picker.locator("[data-calendar]")).toBeVisible();
      expect(await picker.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
      await picker.getByRole("combobox", { name: "Birth month" }).selectOption("1");
      await picker.getByRole("button", { name: "February 29", exact: true }).click();
      await expect(picker.locator("[data-birthdate]")).toHaveValue("2000-02-29");

      // An unrelated LiveView validation patch must preserve the hook's date/precision.
      await page.getByLabel("Occupation", { exact: true }).fill("Engineer");
      await page.getByRole("button", { name: "Create Contact", exact: true }).click();
      await expect(page).toHaveURL(/\/contacts\/\d+$/);
      const profile = page.url();
      await expect(page.locator("dl > div").filter({ has: page.locator("dt", { hasText: /^Birthday$/ }) }).first()).not.toContainText("2000");

      await page.goto(`${profile}/edit`);
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
      await expect(picker.getByRole("checkbox", { name: "Year unknown" })).toBeChecked();
      await picker.getByRole("checkbox", { name: "Year unknown" }).uncheck();
      await expect(picker.getByRole("spinbutton", { name: "Birth year" })).toHaveValue("");
      await expect(picker.locator("[data-error]")).toContainText("Choose a birth year");
      await picker.getByRole("spinbutton", { name: "Birth year" }).fill("2025");
      await expect(picker.locator("[data-error]")).toContainText("not available");
      await expect(picker.getByRole("button", { name: "February 29, 2025", exact: true })).toHaveCount(0);
      await picker.getByRole("button", { name: "February 28, 2025", exact: true }).click();
      await expect(picker.locator("[data-year-unknown-input]")).toHaveValue("false");
      await picker.locator("[data-trigger]").click();
      await picker.getByRole("button", { name: "Next month" }).click();
      await expect(picker.locator("[data-birthdate]")).toHaveValue("2025-02-28");
      await page.keyboard.press("Escape");
      await expect(picker.locator("[data-calendar]")).toBeHidden();
      await expect(picker.locator("[data-trigger]")).toBeFocused();
      await page.getByRole("button", { name: "Save Changes", exact: true }).click();
      await expect(page).toHaveURL(profile);
      await expect(page.locator("dl > div").filter({ has: page.locator("dt", { hasText: /^Birthday$/ }) }).first()).toContainText("2025");

      await page.goto(`${profile}/edit`);
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
      await picker.getByRole("checkbox", { name: "Year unknown" }).check();
      await expect(picker.locator("[data-birthdate]")).toHaveValue("2000-02-28");
      await picker.getByRole("button", { name: "February 29", exact: true }).click();
      await page.getByRole("button", { name: "Save Changes", exact: true }).click();
      await expect(page).toHaveURL(profile);

      await page.goto(`${profile}/edit`);
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
      await expect(picker.locator("[data-birthdate]")).toHaveValue("2000-02-29");
      await picker.getByRole("button", { name: "Clear birthdate", exact: true }).click();
      await expect(picker.locator("[data-birthdate]")).toHaveValue("");
      await expect(picker.getByRole("checkbox", { name: "Year unknown" })).not.toBeChecked();
      await page.getByRole("button", { name: "Save Changes", exact: true }).click();
      await expect(page).toHaveURL(profile);
      await expect(page.locator("dl > div").filter({ has: page.locator("dt", { hasText: /^Birthday$/ }) })).toHaveCount(0);
    });
  });
}
