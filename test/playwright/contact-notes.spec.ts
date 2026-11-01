import { test, expect, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { passwordLogin } from "./helpers/password-login";

test.skip(process.env.KITH_E2E !== "1", "Requires local regression fixtures");
let fixture: {email: string; contact_id: number};
test.beforeAll(() => {
  const output = execFileSync("mix", ["run", "--no-start", "--no-compile", "test/playwright/fixtures/regressions/control.exs", "prepare", JSON.stringify({scenario: "editor"})], {
    env: {...process.env, MIX_ENV: "test", KITH_E2E: "1", KITH_TEST_SERVER: "0"}, encoding: "utf8", timeout: 120_000,
  });
  fixture = JSON.parse(output.split(/\r?\n/).findLast(line => line.startsWith("KITH_TEST_RESULT="))!.slice("KITH_TEST_RESULT=".length));
});

async function open(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.locator('[phx-click="open-entry-modal"][phx-value-type="note"]').click();
  await expect(page.locator("trix-editor")).toBeVisible();
}
async function block(page: Page, attribute: string, text: string) {
  const editor = page.locator("trix-editor");
  await editor.focus();
  await page.locator(`[data-trix-attribute="${attribute}"]`).click();
  await editor.pressSequentially(text);
  if (["bold", "italic", "strike"].includes(attribute)) {
    await page.locator(`[data-trix-attribute="${attribute}"]`).click();
    await editor.press("Enter");
  } else {
    await editor.press("Enter");
    if (attribute !== "heading1") await editor.press("Enter");
  }
}

test("toolbar formatting persists with visible markers, history, and modal lifecycle", async ({page}) => {
  await passwordLogin(page, fixture.email, "ValidP@ssword123!");
  await page.goto(`/contacts/${fixture.contact_id}`);
  await open(page);
  const editor = page.locator("trix-editor");
  await expect(page.locator('[data-trix-action="attachFiles"]')).toBeHidden();
  expect(await page.locator('[data-trix-attribute="bold"]').evaluate(el => getComputedStyle(el, "::before").backgroundImage)).not.toBe("none");
  for (const [attribute, text] of [["bold", "bold text"], ["italic", "italic text"], ["strike", "strike text"]]) {
    await block(page, attribute, text);
  }
  for (const [attribute, text] of [["heading1", "Heading"], ["quote", "Quotation"], ["code", "Code sample"], ["bullet", "Bullet item"], ["number", "Number item"]]) {
    await block(page, attribute, text);
  }
  await editor.focus();
  await page.locator('[data-trix-attribute="bullet"]').click();
  await editor.pressSequentially("Parent item");
  await editor.press("Enter");
  await page.locator('[data-trix-action="increaseNestingLevel"]').click();
  await editor.pressSequentially("Nested child");
  await editor.press("Enter");
  await page.locator('[data-trix-action="decreaseNestingLevel"]').click();
  await page.locator('[data-trix-attribute="bullet"]').click();
  await page.locator('[data-trix-attribute="href"]').click();
  await page.locator('[data-trix-input][name="href"]').fill("https://example.com");
  await page.locator('[data-trix-method="setAttribute"]').click();
  await editor.press("End");
  await editor.pressSequentially(" history");
  await page.locator('[data-trix-action="undo"]').click();
  await expect(editor).not.toContainText("history");
  await page.locator('[data-trix-action="redo"]').click();
  await expect(editor).toContainText("history");
  await page.locator('input[name="entry[is_private]"][type="checkbox"]').check();
  await page.getByRole("button", {name: "Save", exact: true}).click();
  const body = page.locator(".note-body").first();
  for (const selector of ["strong", "em", "del", "pre", "h1", "blockquote", "ul li", "ol li", "ul ul li", "a"]) {
    await expect(body.locator(selector).first()).toBeVisible();
  }
  expect(await body.locator("em").boundingBox().then(box => box!.y)).toBeGreaterThan(await body.locator("strong").boundingBox().then(box => box!.y));
  expect(await body.locator("ul").first().evaluate(el => getComputedStyle(el).listStyleType)).toBe("disc");
  expect(await body.locator("ol").first().evaluate(el => getComputedStyle(el).listStyleType)).toBe("decimal");
  await page.reload();
  await expect(body.locator("strong")).toHaveText("bold text");
  const edit = page.locator('[phx-click="edit-entry"][phx-value-type="note"]').first();
  await edit.locator("..").locator("..").locator(":scope > button").click();
  await edit.click();
  await expect(editor).toContainText("bold text");
  await expect(page.locator('input[name="entry[is_private]"][type="checkbox"]')).toBeChecked();
  await editor.press("ControlOrMeta+End");
  await editor.pressSequentially(" unsaved typing");
  // Force a normal component patch while the ignored editor retains local changes.
  await page.locator('[phx-click="filter-toggle"][phx-value-type="note"]').first().evaluate((el: HTMLElement) => el.click());
  await expect(editor).toContainText("unsaved typing");
  await page.getByRole("button", {name: "Cancel", exact: true}).click();
  await edit.locator("..").locator("..").locator(":scope > button").click();
  await edit.click();
  await expect(editor).not.toContainText("unsaved typing");
  await page.getByRole("button", {name: "Cancel", exact: true}).click();
  await page.setViewportSize({width: 390, height: 844});
  await page.evaluate(() => document.documentElement.dataset.theme = "dark");
  await open(page);
  await expect(editor).not.toContainText("bold text");
  await editor.pressSequentially("Second separate note");
  await page.getByRole("button", {name: "Save", exact: true}).click();
  await expect(page.locator(".note-body")).toHaveCount(2);
  await edit.locator("..").locator("..").locator(":scope > button").click();
  await edit.click();
  await expect(editor).toContainText("Second separate note");
  await expect(editor).not.toContainText("bold text");
  await expect(page.locator('input[name="entry[is_private]"][type="checkbox"]')).not.toBeChecked();
  expect(await page.locator('[data-trix-attribute="bold"]').evaluate(el => getComputedStyle(el, "::before").filter)).toContain("invert(1)");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.getByRole("button", {name: "Cancel", exact: true}).click();
  const olderEdit = page.locator('[phx-click="edit-entry"][phx-value-type="note"]').last();
  await olderEdit.locator("..").locator("..").locator(":scope > button").click();
  await olderEdit.click();
  await expect(editor).toContainText("bold text");
  await expect(editor).not.toContainText("Second separate note");
});

test("delayed invalid submit preserves newer corrections", async ({page}) => {
  let holdReply = false;
  let pendingRef: string | undefined;
  let releaseReply: (() => void) | undefined;
  await page.routeWebSocket("**/live/websocket*", socket => {
    const server = socket.connectToServer();
    socket.onMessage(message => {
      const frame = JSON.parse(message.toString());
      if (holdReply && frame[3] === "event" && frame[4]?.event === "save-entry") {
        pendingRef = frame[1];
      }
      server.send(message);
    });
    server.onMessage(message => {
      const frame = JSON.parse(message.toString());
      if (pendingRef && frame[1] === pendingRef && frame[3] === "phx_reply") {
        pendingRef = undefined;
        holdReply = false;
        releaseReply = () => socket.send(message);
      } else {
        socket.send(message);
      }
    });
  });
  await passwordLogin(page, fixture.email, "ValidP@ssword123!");
  await page.goto(`/contacts/${fixture.contact_id}`);
  await open(page);
  const editor = page.locator("trix-editor");
  await editor.pressSequentially("Original saved body");
  await page.getByRole("button", {name: "Save", exact: true}).click();
  const body = page.locator(".note-body").filter({hasText: "Original saved body"});
  await expect(body).toBeVisible();
  const edit = body.locator("xpath=..").locator('[phx-click="edit-entry"][phx-value-type="note"]');
  await edit.locator("..").locator("..").locator(":scope > button").click();
  await edit.click();
  await expect(editor).toContainText("Original saved body");
  // Click waits for the opening modal to settle before keyboard selection.
  await editor.click();
  await editor.focus();
  await expect(editor).toBeFocused();
  await editor.press("ControlOrMeta+A");
  await editor.press("Backspace");
  await expect(page.locator('input[name="entry[body]"]')).toHaveValue("");
  holdReply = true;
  await page.getByRole("button", {name: "Save", exact: true}).click();
  await expect.poll(() => !!releaseReply).toBe(true);
  await editor.pressSequentially("Correction typed while waiting");
  releaseReply!();
  await expect(page.getByText("body: can't be blank", {exact: true})).toBeVisible();
  await expect(editor).toContainText("Correction typed while waiting");
  await page.getByRole("button", {name: "Save", exact: true}).click();
  await expect(page.locator(".note-body").filter({hasText: "Correction typed while waiting"})).toBeVisible();
});
