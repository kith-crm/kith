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
  retries: 0,
  reporter: "list",
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4000",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "smoke",
      testDir: "./e2e",
      use: chromium,
    },
    {
      name: "e2e",
      testDir: "./test/playwright",
      testMatch: "**/*.spec.ts",
      use: chromium,
    },
  ],
});
