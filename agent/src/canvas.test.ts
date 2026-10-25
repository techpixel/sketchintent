import assert from "node:assert/strict";
import { test } from "node:test";
import { imageByteLimit, makeImage, toDocument } from "./canvas.ts";

test("a whole HTML document is kept as written", () => {
  const page = "<!doctype html><html><body><p>Hi</p></body></html>";
  assert.equal(toDocument(page, "html"), page);
});

test("a fragment gets a white page that fills the image", () => {
  const page = toDocument("<button>Save</button>", "html");
  assert.match(page, /^<!doctype html>/);
  assert.match(page, /background:#fff/);
  assert.match(page, /<body><button>Save<\/button><\/body>/);
});

test("an SVG without a size is stretched to the image", () => {
  assert.match(toDocument('<svg viewBox="0 0 10 10"></svg>', "svg"), /<svg width="100%" height="100%" viewBox/);
  assert.match(toDocument('<svg width="40" viewBox="0 0 10 10"></svg>', "svg"), /<svg width="40" viewBox/);
});

test("coordinates are rounded and a zero size is refused", () => {
  const image = makeImage("<p>x</p>", "html", "sketch", { x: 10.04, y: -5.06, width: 200, height: 120.55 });
  assert.deepEqual([image?.x, image?.y, image?.width, image?.height], [10, -5.1, 200, 120.6]);
  assert.equal(makeImage("<p>x</p>", "html", "sketch", { x: 0, y: 0, width: 0, height: 10 }), null);
});

test("code too large for one reply is refused", () => {
  const huge = "x".repeat(imageByteLimit);
  assert.equal(makeImage(huge, "html", "sketch", { x: 0, y: 0, width: 10, height: 10 }), null);
});
