import { test, expect } from "@playwright/test";
import { buildSync } from "esbuild";
import path from "node:path";

// Compile the same unchanged source and alias used by the shipped Mix esbuild profile.
const result = buildSync({
  entryPoints: ["assets/vendor/trix/src/trix/trix.js"],
  alias: {
    trix: path.resolve("assets/vendor/trix/src/trix"),
    trix_editor_element: path.resolve("assets/vendor/trix/src/trix/elements/trix_editor_element.js"),
    trix_toolbar_element: path.resolve("assets/vendor/trix/src/trix/elements/trix_toolbar_element.js"),
  },
  bundle: true,
  write: false,
  metafile: true,
  format: "iife",
});
const bundle = result.outputFiles[0].text;

test.beforeEach(async ({ page }) => {
  await page.setContent('<input id="note" type="hidden">');
  // Exercise the advisory's fallback input controller, including actual drop dispatch.
  await page.addScriptTag({ content: bundle });
  await page.evaluate(() => {
    (window as any).Trix.config.input.level2Enabled = false;
    document.body.insertAdjacentHTML("beforeend", '<trix-editor input="note"></trix-editor>');
  });
  await page.waitForFunction(() => !!(document.querySelector("trix-editor") as any)?.editor);
});

test("source build uses patched standalone sanitizer and preserves formatting", async ({ page }) => {
  expect(Object.keys(result.metafile.inputs).some(p => p.endsWith("assets/node_modules/dompurify/dist/purify.es.mjs"))).toBeTruthy();
  expect(bundle).toContain('3.4.17');
  expect(bundle).not.toContain('DOMPurify 3.4.2');
  await page.evaluate(() => (document.querySelector("trix-editor") as any).editor.loadHTML('<p><strong>Kept bold</strong> <a href="https://example.com/">safe link</a></p>'));
  await expect(page.locator("trix-editor strong")).toHaveText("Kept bold");
  await expect(page.locator("trix-editor a")).toHaveAttribute("href", "https://example.com/");
});

test("paste rejects mock-attachment href injection (GHSA-53g2-mvcc-q9x3)", async ({ page }) => {
  await page.locator("trix-editor").focus();
  await page.evaluate(() => {
    const clipboardData = new DataTransfer();
    clipboardData.setData("text/html", `<span data-trix-attachment='{}' data-trix-attributes='{"href":"javascript:window.editorXSS=1"}'>payload text</span><strong>Kept bold</strong>`);
    document.querySelector("trix-editor")!.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
  });
  await expect(page.locator("trix-editor")).toContainText("payload text");
  await expect(page.locator("trix-editor strong")).toHaveText("Kept bold");
  expect(await page.locator("#note").inputValue()).not.toMatch(/javascript:|editorXSS/);
});

test("fallback drop rejects JSON href bypass (GHSA-53p3-c7vp-4mcc)", async ({ page }) => {
  const controller = await page.evaluate(() => (document.querySelector("trix-editor") as any).editorController.inputController.constructor.name);
  expect(controller).toBe("Level0InputController");
  await page.locator("trix-editor").focus();
  await page.evaluate(() => {
    const dataTransfer = new DataTransfer();
    dataTransfer.setData("application/x-trix-document", JSON.stringify([{ text: [{ type: "string", string: "Dropped text", attributes: { href: "javascript:window.editorXSS=1", bold: true } }], attributes: [] }]));
    document.querySelector("trix-editor")!.dispatchEvent(new DragEvent("drop", { dataTransfer, bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
  });
  await expect(page.locator("trix-editor")).toContainText("Dropped text");
  await expect(page.locator("trix-editor strong")).toHaveText("Dropped text");
  expect(await page.locator("#note").inputValue()).not.toMatch(/javascript:|editorXSS/);
});
