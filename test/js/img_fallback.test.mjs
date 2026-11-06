import assert from "node:assert/strict";
import test from "node:test";
import ImgFallback from "../../assets/js/hooks/img_fallback.js";

// Only browser primitives are simulated. All state transitions and callbacks
// below execute the production hook, with events delivered in explicit order.
class ImageNode extends EventTarget {
  constructor(src = "/photo.png", { complete = false, width = 0 } = {}) {
    super();
    this.src = src;
    this.complete = complete;
    this.naturalWidth = width;
  }

  getAttribute(name) {
    assert.equal(name, "src");
    return this.src;
  }

  emit(type) {
    this.dispatchEvent(new Event(type));
  }
}

function mount({ img = new ImageNode(), refreshable = true } = {}) {
  const attributes = new Set();
  const requests = [];
  const root = {
    img,
    dataset: { refreshable: String(refreshable) },
    querySelector(selector) {
      assert.equal(selector, "img[data-fallback-img]");
      return this.img;
    },
    toggleAttribute(name, present) {
      if (present) attributes.add(name);
      else attributes.delete(name);
    },
  };
  const hook = {
    ...ImgFallback,
    el: root,
    pushEventTo(target, event, payload, reply) {
      assert.equal(target, root);
      assert.equal(event, "refresh_url");
      assert.deepEqual(payload, {});
      requests.push(reply);
    },
  };
  hook.mounted();
  return { hook, root, img, requests, attributes };
}

function expectVisibleState(ctx, state) {
  assert.equal(ctx.attributes.has("data-img-retrying"), state === "retrying");
  assert.equal(ctx.attributes.has("data-img-failed"), state === "failed");
}

test("first failure asks for one refresh; unchanged reply exposes unavailable state", () => {
  const ctx = mount();
  expectVisibleState(ctx, "ok");
  ctx.img.emit("error");
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 1);
  ctx.requests[0]({ changed: false });
  expectVisibleState(ctx, "failed");
  ctx.img.emit("error");
  ctx.hook.updated();
  expectVisibleState(ctx, "failed");
  assert.equal(ctx.requests.length, 1);
});

test("a changed reply waits for image load and load clears both fallback markers", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.requests[0]({ changed: true });
  expectVisibleState(ctx, "retrying");
  ctx.img.emit("load");
  expectVisibleState(ctx, "ok");
  assert.equal(ctx.requests.length, 1);
});

test("a second image failure gives up even while the refresh reply is outstanding", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.img.emit("error");
  expectVisibleState(ctx, "failed");
  assert.equal(ctx.requests.length, 1);
  ctx.requests[0]({ changed: true });
  expectVisibleState(ctx, "failed");
});

test("an absent reply is a failed refresh", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.requests[0](undefined);
  expectVisibleState(ctx, "failed");
});

test("non-refreshable avatars fail directly and recover on load", () => {
  const ctx = mount({ refreshable: false });
  ctx.img.emit("error");
  expectVisibleState(ctx, "failed");
  assert.equal(ctx.requests.length, 0);
  ctx.img.emit("load");
  expectVisibleState(ctx, "ok");
});

test("a cached failure before mounting starts one refresh", () => {
  const ctx = mount({ img: new ImageNode("/missing.png", { complete: true }) });
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 1);
  ctx.hook.updated();
  assert.equal(ctx.requests.length, 1);
});

test("a loaded cached image and an empty src do not start a refresh", () => {
  for (const img of [
    new ImageNode("/loaded.png", { complete: true, width: 12 }),
    new ImageNode("", { complete: true }),
  ]) {
    const ctx = mount({ img });
    expectVisibleState(ctx, "ok");
    assert.equal(ctx.requests.length, 0);
  }
});

test("a syncing placeholder can acquire an image and then handle its failure", () => {
  const ctx = mount({ img: null });
  expectVisibleState(ctx, "ok");
  assert.equal(ctx.requests.length, 0);
  ctx.root.img = new ImageNode();
  ctx.hook.updated();
  ctx.root.img.emit("error");
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 1);
});

test("repeated unchanged patches preserve failure and do not duplicate listeners", () => {
  const ctx = mount();
  ctx.hook.updated();
  ctx.hook.updated();
  ctx.img.emit("error");
  // Duplicated listeners would treat this single error as two failures.
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 1);
  ctx.requests[0]({ changed: false });
  ctx.hook.updated();
  ctx.hook.updated();
  expectVisibleState(ctx, "failed");
  assert.equal(ctx.requests.length, 1);
});

test("node replacement ignores old events and outstanding old refresh replies", () => {
  const ctx = mount();
  ctx.img.emit("error");
  const replacement = new ImageNode("/replacement.png");
  ctx.root.img = replacement;
  ctx.hook.updated();
  ctx.img.emit("error");
  expectVisibleState(ctx, "ok");
  assert.equal(ctx.requests.length, 1);
  replacement.emit("error");
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 2);
  ctx.requests[0]({ changed: false });
  expectVisibleState(ctx, "retrying");
  ctx.img.emit("load");
  expectVisibleState(ctx, "retrying");
});

test("changing src after failure allows the same node to recover", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.requests[0]({ changed: false });
  ctx.img.src = "/new.png";
  ctx.hook.updated();
  expectVisibleState(ctx, "ok");
  ctx.img.emit("error");
  expectVisibleState(ctx, "retrying");
  assert.equal(ctx.requests.length, 2);
  ctx.requests[1]({ changed: true });
  ctx.img.emit("load");
  expectVisibleState(ctx, "ok");
});

test("an old reply cannot fail a new retry on the same image node", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.img.src = "/new.png";
  ctx.hook.updated();
  ctx.img.emit("error");
  assert.equal(ctx.requests.length, 2);
  // Explicitly release attempt one's response after attempt two has started.
  ctx.requests[0]({ changed: false });
  expectVisibleState(ctx, "retrying");
  ctx.requests[1]({ changed: true });
  ctx.img.emit("load");
  expectVisibleState(ctx, "ok");
});

test("a reply from before a successful load cannot fail a later retry", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.img.emit("load");
  ctx.img.emit("error");
  ctx.requests[0]({ changed: false });
  expectVisibleState(ctx, "retrying");
  ctx.requests[1]({ changed: false });
  expectVisibleState(ctx, "failed");
});

test("destroy removes listeners and makes pending callbacks harmless", () => {
  const ctx = mount();
  ctx.img.emit("error");
  ctx.hook.destroyed();
  const before = new Set(ctx.attributes);
  ctx.img.emit("load");
  ctx.img.emit("error");
  ctx.requests[0]({ changed: false });
  assert.deepEqual(ctx.attributes, before);
  assert.equal(ctx.requests.length, 1);
});
