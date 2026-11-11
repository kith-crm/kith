import { defineConfig, devices } from "@playwright/test";

// Machines whose Playwright-managed Chromium is missing or incomplete can point
// at any compatible Chromium build (e.g. a cached chrome-headless-shell) with
// PLAYWRIGHT_CHROMIUM_EXECUTABLE. Unset, Playwright's own browser is used.
const chromium = {
  ...devices["Desktop Chrome"],
  channel: "chromium",
  ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
    ? { launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } }
    : {}),
};

export default defineConfig({
  timeout: 30_000,
  outputDir: process.env.PLAYWRIGHT_OUTPUT_DIR ?? "test-results",
  expect: { timeout: 5_000 },
  fullyParallel: true,
  // Live DAV specs share seeded accounts and compare collection-wide mutations.
  workers: process.env.DAV_SERVER_PID_FILE ? 1 : undefined,
  retries: 0,
  reporter: "list",
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4000",
    // Auth fixtures and generated credentials must not enter retained traces.
    trace: "off",
  },
  projects: [
    {
      name: "oidc",
      testDir: "./test/playwright",
      testMatch: /(?:oidc|dav-app-passwords|settings-navigation)\.spec\.ts/,
      use: {
        ...chromium,
        // Authentication and one-time credentials must never enter artifacts.
        trace: "off",
        screenshot: "off",
        video: "off",
        launchOptions: {
          ...chromium.launchOptions,
          args: [
            "--host-resolver-rules=MAP kith.test 127.0.0.1, MAP issuer.test 127.0.0.1",
            "--no-proxy-server",
            `--ignore-certificate-errors-spki-list=${process.env.KITH_OIDC_SPKI ?? ""}`,
          ],
        },
      },
    },
    {
      name: "smoke",
      testDir: "./e2e",
      use: chromium,
    },
    {
      name: "e2e",
      testDir: "./test/playwright",
      testMatch: "**/*.spec.ts",
      testIgnore: /(?:oidc|dav-app-passwords|settings-navigation)\.spec\.ts/,
      use: chromium,
    },
  ],
});
