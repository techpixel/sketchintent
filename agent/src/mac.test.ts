import assert from "node:assert/strict";
import { homedir } from "node:os";
import { test } from "node:test";
import { openArguments } from "./mac.ts";

test("an app name opens that app", () => {
  assert.deepEqual(openArguments("Safari"), { args: ["-a", "Safari"] });
});

test("a web link opens in the default browser or the named app", () => {
  assert.deepEqual(openArguments("https://example.com"), { args: ["https://example.com"] });
  assert.deepEqual(openArguments("https://example.com", "Safari"), { args: ["-a", "Safari", "https://example.com"] });
});

test("paths open, and ~ is the home folder", () => {
  assert.deepEqual(openArguments("/Users/me/Notes"), { args: ["/Users/me/Notes"] });
  assert.deepEqual(openArguments("~/Desktop"), { args: [`${homedir()}/Desktop`] });
});

test("other link schemes and runnable files are refused", () => {
  assert.ok("error" in openArguments("file:///tmp/x"));
  assert.ok("error" in openArguments("x-apple.systempreferences:"));
  assert.ok("error" in openArguments("/tmp/run.command"));
  assert.ok("error" in openArguments("/Applications/Calculator.app"));
  assert.ok("error" in openArguments("/tmp/install.pkg", "Finder"));
  assert.ok("error" in openArguments("notes.txt", "TextEdit"));
});
