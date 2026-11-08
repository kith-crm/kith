import { test, expect, type Locator, type Page } from "@playwright/test";
import { registerUser, TEST_PASSWORD } from "./helpers/auth";
import { createContact } from "./helpers/contacts";
import { passwordLogin } from "./helpers/password-login";

// Independent signup/login quotas can each require up to 60s in the full harness.
test.setTimeout(150_000);

async function authenticate(page: Page) {
  if (process.env.MOBILE_LAYOUT_EMAIL) {
    await passwordLogin(page, process.env.MOBILE_LAYOUT_EMAIL, process.env.MOBILE_LAYOUT_PASSWORD ?? TEST_PASSWORD);
  } else {
    await registerUser(page);
  }
  // Login/registration flashes float above the header and would obscure logout.
  for (const alert of await page.getByRole("alert").all()) {
    if (await alert.isVisible()) {
      await alert.getByRole("button", { name: "close", exact: true }).click();
      await expect(alert).toBeHidden();
    }
  }
}

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
}

function mobileNavigation(page: Page) {
  return page.locator("nav").filter({ has: page.getByRole("link", { name: "Home", exact: true }) });
}

// toBeVisible alone does not catch controls hidden by an overflow ancestor.
// Check horizontal clipping BEFORE Playwright can auto-pan to the target.
async function expectUnclipped(control: Locator) {
  await expect(control).toBeVisible();
  const horizontal = await control.evaluate((element) => {
    const box = element.getBoundingClientRect();
    let left = 0;
    let right = document.documentElement.clientWidth;
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      if (getComputedStyle(parent).overflowX !== "visible") {
        const bounds = parent.getBoundingClientRect();
        left = Math.max(left, bounds.left);
        right = Math.min(right, bounds.right);
      }
    }
    return { left: box.left, right: box.right, clipLeft: left, clipRight: right };
  });
  expect(horizontal.left, JSON.stringify(horizontal)).toBeGreaterThanOrEqual(horizontal.clipLeft - 1);
  expect(horizontal.right, JSON.stringify(horizontal)).toBeLessThanOrEqual(horizontal.clipRight + 1);
  await control.scrollIntoViewIfNeeded();
  await expect(control).toBeInViewport({ ratio: 1 });
  expect(await control.evaluate((element) => {
    const box = element.getBoundingClientRect();
    const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
    return hit !== null && (element === hit || element.contains(hit));
  }), "Control center must receive pointer input").toBe(true);
}

async function expectNoPageHorizontalOverflow(page: Page) {
  await expect.poll(() => page.evaluate(() => {
    const main = document.querySelector("main")!;
    return Math.max(
      document.documentElement.scrollWidth - document.documentElement.clientWidth,
      main.scrollWidth - main.clientWidth,
    );
  })).toBeLessThanOrEqual(1);
}

test.describe("Mobile navigation", () => {
  test.use({ isMobile: true, hasTouch: true });

  for (const width of [320, 375, 393]) {
    test(`four primary destinations and accessible More menu fit at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await authenticate(page);
      const nav = mobileNavigation(page);
      await expect(nav.getByRole("link")).toHaveText(["Home", "Contacts", "Settings"]);
      await expect(nav.getByText("Jobs", { exact: true })).toHaveCount(0);
      const more = nav.getByRole("button", { name: "More", exact: true });
      for (const name of ["Home", "Contacts", "Settings"]) {
        await expectUnclipped(nav.getByRole("link", { name, exact: true }));
      }
      await expectUnclipped(more);
      await expect(more).toHaveAttribute("aria-expanded", "false");
      const logout = page.locator("header").getByRole("link", { name: "Log out", exact: true });
      await expectUnclipped(logout);

      await more.focus();
      await more.press("Enter");
      const menu = nav.getByRole("menu", { name: "More destinations" });
      await expect(menu).toBeVisible();
      await expect(more).toHaveAttribute("aria-expanded", "true");
      await expect(menu.getByRole("menuitem")).toHaveText(["Reminders", "Journal"]);
      await expect(menu.getByRole("menuitem").first()).toBeFocused();
      await page.keyboard.press("ArrowDown");
      await expect(menu.getByRole("menuitem").last()).toBeFocused();
      await page.keyboard.press("Home");
      await expect(menu.getByRole("menuitem").first()).toBeFocused();
      await page.keyboard.press("End");
      await expect(menu.getByRole("menuitem").last()).toBeFocused();
      for (const name of ["Reminders", "Journal"]) {
        await expectUnclipped(menu.getByRole("menuitem", { name, exact: true }));
      }
      await page.keyboard.press("Escape");
      await expect(menu).toBeHidden();
      await expect(more).toBeFocused();
      await more.click();
      await page.locator("main").first().click({ position: { x: 10, y: 10 } });
      await expect(menu).toBeHidden();

      for (const [name, route] of [["Reminders", "/reminders/upcoming"], ["Journal", "/journal"]]) {
        await more.click();
        await menu.getByRole("menuitem", { name, exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`${route}$`));
        await connected(page);
        await expect(more).toHaveAttribute("aria-expanded", "false");
        await expect(more).toHaveAttribute("aria-current", "page");
        await more.click();
        await expect(menu.getByRole("menuitem", { name, exact: true })).toHaveAttribute("aria-current", "page");
        await page.keyboard.press("Escape");
      }
      for (const route of ["/users/settings", "/settings/account"]) {
        await page.goto(route);
        await connected(page);
        await expect(nav.getByRole("link", { name: "Settings", exact: true })).toHaveAttribute("aria-current", "page");
        await expectNoPageHorizontalOverflow(page);
      }
      if (width === 320) {
        await logout.click();
        await expect(page).toHaveURL(/\/users\/log-in$/);
      }
    });
  }

  test("contact actions, section tabs and mood filters remain reachable at 320px", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 844 });
    await authenticate(page);
    await createContact(page, { firstName: "Mobile", lastName: "Regression" });
    const stream = page.locator("#activity-stream");
    const filterMenu = stream.getByRole("button", { name: "Filter", exact: true });
    await expectUnclipped(filterMenu);
    await filterMenu.click();
    await expectUnclipped(stream.getByRole("button", { name: "Note", exact: true }));
    await filterMenu.click();
    await expect(stream.getByRole("button", { name: "+ Event", exact: true })).toHaveCount(0);
    for (const [name, heading] of [["+ Note", "New Note"], ["+ Call", "Log Call"]]) {
      const action = stream.getByRole("button", { name, exact: true });
      await expectUnclipped(action);
      await action.click();
      const dialog = page.getByRole("dialog");
      await expect(dialog.getByRole("heading", { name: heading, exact: true })).toBeVisible();
      await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
      await expect(dialog).toBeHidden();
    }
    const add = stream.getByRole("button", { name: "Add timeline entry", exact: true });
    await expectUnclipped(add);
    for (const [name, heading] of [["+ Life Event", "New Life Event"], ["+ Task", "New Task"]]) {
      await add.click();
      const action = stream.getByRole("button", { name, exact: true });
      await expectUnclipped(action);
      await action.click();
      await expect(page.getByRole("dialog").getByRole("heading", { name: heading, exact: true })).toBeVisible();
      await page.getByRole("dialog").getByRole("button", { name: "Cancel", exact: true }).click();
      await expect(page.getByRole("dialog")).toBeHidden();
    }
    await expectNoPageHorizontalOverflow(page);

    for (const [name, route] of [["All", "/contacts"], ["Archived", "/contacts/archived"], ["Duplicates", "/contacts/duplicates"], ["Trash", "/contacts/trash"]]) {
      await page.goto("/contacts");
      await connected(page);
      const tab = page.getByRole("link", { name, exact: true });
      await expectUnclipped(tab);
      await tab.click();
      await expect(page).toHaveURL(new RegExp(`${route}$`));
      await expectNoPageHorizontalOverflow(page);
    }
    await page.goto("/journal");
    await connected(page);
    for (const [name, mood] of [["Great", "great"], ["Good", "good"], ["Neutral", "neutral"], ["Bad", "bad"], ["Awful", "awful"]]) {
      const filter = page.getByRole("button", { name: new RegExp(name) });
      await expectUnclipped(filter);
      await filter.click();
      await expect(page).toHaveURL(new RegExp(`/journal\\?mood=${mood}$`));
      await expectNoPageHorizontalOverflow(page);
    }
    await page.getByRole("button", { name: "All", exact: true }).click();
    await expect(page).toHaveURL(/\/journal$/);
  });
});

for (const width of [1366, 1440]) {
  test(`desktop navigation and responsive round trip at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await authenticate(page);
    const sidebar = page.locator("aside").first();
    await expect(sidebar).toBeVisible();
    const jobsVisible = await sidebar.getByRole("link", { name: "Jobs", exact: true }).isVisible();
    for (const [name, route] of [["Contacts", "/contacts"], ["Reminders", "/reminders/upcoming"], ["Journal", "/journal"], ["Settings", "/users/settings"]]) {
      await sidebar.getByRole("link", { name, exact: true }).click();
      await expect(page).toHaveURL(new RegExp(`${route}$`));
      await connected(page);
      if (name === "Settings") {
        await expect(sidebar.getByRole("link", { name, exact: true })).toHaveAttribute("aria-current", "page");
      }
      await expectNoPageHorizontalOverflow(page);
    }
    await page.setViewportSize({ width: 320, height: 844 });
    await expect(sidebar).toBeHidden();
    await expect(mobileNavigation(page).getByRole("button", { name: "More", exact: true })).toBeVisible();
    await page.setViewportSize({ width, height: 900 });
    await expect(sidebar).toBeVisible();
    await expect(mobileNavigation(page)).toBeHidden();
    expect(await sidebar.getByRole("link", { name: "Jobs", exact: true }).isVisible()).toBe(jobsVisible);
    await expectNoPageHorizontalOverflow(page);
  });
}

test("login helper honors HTTP Retry-After", async ({ page }) => {
  let loginPosts = 0;
  // Keep this HTTP-contract test independent of the real shared login quota.
  // The other scenarios exercise real registration and authentication.
  await page.route("**/users/log-in*", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    loginPosts++;
    if (loginPosts === 1) {
      return route.fulfill({
        status: 429,
        headers: { "retry-after": "1" },
        contentType: "text/html",
        body: "Too many login attempts. Please try again later.",
      });
    }
    return route.fulfill({ status: 303, headers: { location: "/users/log-in?retry_complete=1" }, body: "" });
  });

  await passwordLogin(page, "retry-contract@test.local", TEST_PASSWORD, /\/users\/log-in\?retry_complete=1$/);
  expect(loginPosts).toBe(2);
  await expect(page.getByRole("button", { name: /log in/i })).toBeVisible();
});
