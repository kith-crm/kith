import { expect, type Page } from "@playwright/test";

// Independent scenarios share a real loopback peer. Respect the production
// login budget rather than disabling it or treating an unrelated failure as retryable.
export async function passwordLogin(page: Page, email: string, password: string) {
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.goto("/users/log-in");
    await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
    const emailInput = page.getByRole("textbox", { name: /email/i });
    const passwordInput = page.locator('input[type="password"]');
    await emailInput.fill(email);
    await passwordInput.fill(password);
    await expect(emailInput).toHaveValue(email);
    await expect(passwordInput).toHaveValue(password);

    const [response] = await Promise.all([
      page.waitForResponse((response) =>
        response.request().method() === "POST" && new URL(response.url()).pathname === "/users/log-in"),
      page.getByRole("button", { name: /log in/i }).click(),
    ]);

    if (response.status() === 429 && attempt === 0) {
      const delay = Number(response.headers()["retry-after"]);
      expect(Number.isInteger(delay) && delay >= 1 && delay <= 60).toBe(true);
      await page.waitForTimeout(delay * 1000 + 100);
      continue;
    }

    expect([302, 303]).toContain(response.status());
    await expect(page).toHaveURL(/\/(dashboard|contacts)$/);
    return;
  }
}
