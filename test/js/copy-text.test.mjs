import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
let factory;
globalThis.__copyAlpine = { data: (_, value) => { factory = value; } };
const source = (await readFile(new URL('../../assets/js/alpine/copy_text.js', import.meta.url), 'utf8')).replace('import Alpine from "@alpinejs/csp";', 'const Alpine = globalThis.__copyAlpine;');
await import(`data:text/javascript,${encodeURIComponent(source)}`);

test('copies sensitive value from visible input without duplicating it in data', async () => {
  const values = [];
  Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {clipboard: {writeText: async value => values.push(value)}}});
  const component = factory();
  component.$root = {dataset: {}, querySelector: () => ({value: 'synthetic-one-time-value'})};
  await component.copy();
  assert.deepEqual(values, ['synthetic-one-time-value']);
  assert.equal(component.copied, true);
  clearTimeout(component.copyTimeout);
});

test('rejected clipboard preserves selectable input and announces failure', async () => {
  Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {clipboard: {writeText: async () => {throw Error('denied')}}}});
  const input = {value: 'synthetic-one-time-value'};
  const component = factory();
  component.$root = {dataset: {}, querySelector: () => input};
  await component.copy();
  assert.equal(component.copyFailed, true);
  assert.equal(component.copied, false);
  assert.equal(input.value, 'synthetic-one-time-value');
});

test('sensitive inputs are cleared before page history restoration and listeners removed', () => {
  const events = new EventTarget();
  globalThis.window = events;
  const input = {value: 'synthetic', setAttribute: (_, value) => {input.attribute = value}};
  const component = factory();
  component.$root = {dataset: {copySensitive: 'true'}, querySelector: () => input};
  component.init();
  events.dispatchEvent(new Event('pagehide'));
  assert.equal(input.value, '');
  assert.equal(input.attribute, '');
  component.destroy();
  input.value = 'removed';
  events.dispatchEvent(new Event('pagehide'));
  assert.equal(input.value, 'removed');
});
