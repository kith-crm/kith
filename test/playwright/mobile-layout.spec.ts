import { test, expect, type Page } from "@playwright/test";
import { loginUser, registerUser, TEST_PASSWORD } from "./helpers/auth";

// Physical Xiaomi capture: visible height 801.905px, 100vh 859.048px.
// Desktop device emulation alone makes vh === dvh and misses this regression.
const visibleViewport = { width: 411, height: 802 };

test.use({ viewport: visibleViewport, isMobile: true, hasTouch: true });
// Fresh CI accounts may wait for both independent signup and login quotas.
test.setTimeout(150_000);

async function geometry(page: Page) {
  return page.evaluate(() => {
    const main = document.querySelector("main")!;
    const header = document.querySelector("header")!.getBoundingClientRect();
    const nav = [...document.querySelectorAll("nav")]
      .find((element) => element.querySelector('a[href="/dashboard"]') && element.clientHeight)!
      .getBoundingClientRect();
    return {
      viewport: window.visualViewport!.height,
      headerTop: header.top,
      navTop: nav.top,
      navBottom: nav.bottom,
      outerScroll: window.scrollY,
      outerOverflow: document.documentElement.scrollHeight - document.documentElement.clientHeight,
      contentScroll: main.scrollTop,
      contentMax: main.scrollHeight - main.clientHeight,
    };
  });
}

async function expectShellInViewport(page: Page, stage: string) {
  const state = await geometry(page);
  const message = `${stage}: ${JSON.stringify(state)}`;
  expect.soft(Math.abs(state.headerTop), message).toBeLessThanOrEqual(1);
  expect.soft(state.navTop, message).toBeGreaterThanOrEqual(0);
  expect.soft(Math.abs(state.navBottom - state.viewport), message).toBeLessThanOrEqual(1);
  expect.soft(Math.abs(state.outerScroll), message).toBeLessThanOrEqual(1);
  expect.soft(state.outerOverflow, message).toBeLessThanOrEqual(1);
}

for (const toolbarHeight of [0, 57]) {
  test(`mobile shell stays visible through scroll boundaries with ${toolbarHeight}px browser toolbar`, async ({ page }) => {
    if (toolbarHeight) {
      // Browser-environment adapter, not an app-layout override: make legacy vh
      // and lvh use the measured LARGE viewport. dvh/svh retain the browser's
      // actual visible viewport. Apply to all served CSS, without targeting a
      // component/class or changing app markup, JS, or scrolling behavior.
      const largeHeight = visibleViewport.height + toolbarHeight;
      await page.route("**/assets/css/app.css*", async (route) => {
        const response = await route.fetch();
        const css = (await response.text()).replace(
          /(-?(?:\d+(?:\.\d+)?|\.\d+))(?:lvh|vh)\b/g,
          (_, amount: string) => `${Number(amount) * largeHeight / 100}px`,
        );
        await route.fulfill({ response, body: css });
      });
    }

    // The maintained regression harness disables double opt-in. A confirmed
    // local test account can also be supplied when using a dev server.
    if (process.env.MOBILE_LAYOUT_EMAIL) {
      await loginUser(page, process.env.MOBILE_LAYOUT_EMAIL, process.env.MOBILE_LAYOUT_PASSWORD ?? TEST_PASSWORD);
    } else {
      await registerUser(page);
    }
    await page.goto("/settings/account");
    await expect(page.getByRole("heading", { name: "Account Settings", exact: true })).toBeVisible();
    await expect(page.getByLabel("Settings", { exact: true })).toBeEnabled();
    await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);

    const main = page.locator("main");
    const bounds = (await main.boundingBox())!;
    await page.mouse.move(bounds.x + bounds.width / 2, Math.min(bounds.y + bounds.height / 2, 700));
    expect((await geometry(page)).contentMax, "Use a genuinely scrollable settings page").toBeGreaterThan(500);
    await expectShellInViewport(page, "initial top");

    await page.mouse.wheel(0, 10_000);
    await expect.poll(async () => {
      const state = await geometry(page);
      return Math.abs(state.contentScroll - state.contentMax);
    }).toBeLessThanOrEqual(1);
    await expectShellInViewport(page, "content bottom");

    await page.mouse.wheel(0, 400);
    // Wheel delivery precedes compositor scrolling; wait for two painted frames.
    await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
    await expectShellInViewport(page, "extra downward scroll at bottom");

    await page.mouse.wheel(0, -500);
    await expect.poll(async () => (await geometry(page)).contentScroll).toBeLessThan((await geometry(page)).contentMax);
    await expectShellInViewport(page, "scrolling back upward");

    await page.mouse.wheel(0, -10_000);
    await expect.poll(async () => (await geometry(page)).contentScroll).toBeLessThanOrEqual(1);
    await expectShellInViewport(page, "content top");
    await page.mouse.wheel(0, -400);
    await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
    await expectShellInViewport(page, "extra upward scroll at top");

    // Browser toolbar collapsing/expanding must also resize the shell correctly.
    await page.setViewportSize({ width: 411, height: 859 });
    await expectShellInViewport(page, "toolbar collapsed");
    await page.setViewportSize(visibleViewport);
    await expectShellInViewport(page, "toolbar expanded again");
  });
}
