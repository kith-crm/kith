import assert from "node:assert/strict";
import test from "node:test";
import SettingsNavigation from "../../assets/js/hooks/settings_navigation.js";

function mount(options) {
  const el = new EventTarget();
  el.selectedOptions = options;
  const paths = [];
  globalThis.window = { liveSocket: { js: () => ({ navigate: path => paths.push(path) }) } };
  const hook = { ...SettingsNavigation, el };
  hook.mounted();
  return { el, hook, paths };
}

test("native selector changes use LiveView navigation and clean up on removal", () => {
  const { el, hook, paths } = mount([{ value: "/settings/security", dataset: { allowed: "true" } }]);
  el.dispatchEvent(new Event("change"));
  assert.deepEqual(paths, ["/settings/security"]);
  hook.destroyed();
  el.dispatchEvent(new Event("change"));
  assert.deepEqual(paths, ["/settings/security"]);
});

test("missing and non-allowlisted options cannot trigger navigation", () => {
  for (const options of [[], [{ value: "https://example.invalid", dataset: {} }], [{ value: "/settings/account", dataset: { allowed: "false" } }]]) {
    const { el, hook, paths } = mount(options);
    el.dispatchEvent(new Event("change"));
    assert.deepEqual(paths, []);
    hook.destroyed();
  }
});
