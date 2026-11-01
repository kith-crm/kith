import { type Page, expect } from "@playwright/test";

/**
 * Generate a unique email address for test isolation.
 * Each test run gets its own user to avoid cross-test contamination.
 */
export function uniqueEmail(prefix = "pw"): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}@test.local`;
}

export const TEST_PASSWORD = "ValidP@ssword123!";

/**
 * Register a new user via the LiveView registration form.
 * Returns the email used for subsequent login.
 */
export async function registerUser(
  page: Page,
  email?: string,
): Promise<string> {
  const userEmail = email ?? uniqueEmail();

  await page.goto("/users/register");
  await page.waitForLoadState("networkidle");
  // Small delay for LiveView to fully mount
  await page.waitForTimeout(300);

  await page.getByRole("textbox", { name: /email/i }).fill(userEmail);
  await page.locator('input[type="password"]').fill(TEST_PASSWORD);

  await page.getByRole("button", { name: /create an account/i }).click();

  // Wait for any navigation (registration triggers phx-trigger-action POST)
  await page.waitForTimeout(3000);

  // Phoenix's phx-trigger-action POSTs to /users/log-in?_action=registered,
  // but the password field gets cleared during LiveView re-render before the
  // form submit. If we end up on the login page or still on register,
  // manually log in with the credentials we just registered.
  const currentUrl = page.url();
  const isLoggedIn =
    currentUrl.includes("/dashboard") ||
    currentUrl.includes("/confirm-email");

  if (!isLoggedIn) {
    await page.goto("/users/log-in");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    await page.getByRole("textbox", { name: /email/i }).fill(userEmail);
    // Password inputs don't have textbox ARIA role — use locator
    await page.locator('input[type="password"]').fill(TEST_PASSWORD);
    await page.getByRole("button", { name: /log in/i }).click();

    await page.waitForURL(/\/(dashboard|users\/confirm-email)/, {
      timeout: 15_000,
    });
  }

  return userEmail;
}

/**
 * Log in an existing user via the LiveView login form.
 * Assumes the user is already registered and confirmed.
 */
export async function loginUser(
  page: Page,
  email: string,
  password = TEST_PASSWORD,
): Promise<void> {
  await page.goto("/users/log-in");
  await page.waitForLoadState("networkidle");
  // Fill the connected LiveView, since its initial mount can replace static
  // inputs after network-idle on a busy local database.
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/, {
    timeout: 15_000,
  });

  await page.getByRole("textbox", { name: /email/i }).fill(email);
  await page.locator('input[type="password"]').fill(password);
  await page.getByRole("button", { name: /log in/i }).click();

  // Wait for redirect to dashboard or confirm-email
  await page.waitForURL(/\/(dashboard|users\/confirm-email)/, {
    timeout: 15_000,
  });
}

/**
 * Register a new user and return logged-in state.
 * Combines register + potential email confirmation flow.
 */
export async function registerAndLogin(page: Page): Promise<string> {
  const email = await registerUser(page);
  // After registration, Phoenix auto-logs in — we should already be at
  // /dashboard or /users/confirm-email
  return email;
}

/**
 * Log out the current user.
 */
export async function logoutUser(page: Page): Promise<void> {
  // The logout link uses DELETE method via data-method="delete"
  // We need to find and click it
  const logoutLink = page.locator('a[href="/users/log-out"]');
  if ((await logoutLink.count()) > 0) {
    await logoutLink.first().click();
    await page.waitForURL(/\/users\/log-in/, { timeout: 10_000 });
  }
}

/**
 * Confirm a user's email by directly hitting the database.
 * This uses the API token endpoint to verify the user exists,
 * then directly confirms via a seed script approach.
 *
 * For Playwright tests, we skip email confirmation by registering
 * and relying on the app's auto-login behavior post-registration.
 */
export async function ensureOnDashboard(page: Page): Promise<void> {
  const url = page.url();
  if (
    url.includes("/users/confirm-email") ||
    url.includes("/users/log-in")
  ) {
    // Try navigating to contacts — this works even without email confirmation
    // in most configurations. If it redirects back, we're still authenticated.
    await page.goto("/contacts");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(500);
  }
  // Verify we're on an authenticated page (including confirm-email as valid)
  await expect(page).toHaveURL(
    /\/(dashboard|contacts|reminders|settings|users\/confirm-email)/,
  );
}
