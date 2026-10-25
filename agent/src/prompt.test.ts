import assert from "node:assert/strict";
import { test } from "node:test";
import { buildPrompt, imageToolName, rememberToolName, systemPrompt, toolLabel, toolStatus } from "./prompt.ts";

test("tool labels use the MCP server name", () => {
  assert.equal(toolLabel("mcp__figma-mcp__get_design_context"), "figma-mcp");
  assert.equal(toolLabel("WebSearch"), "WebSearch");
});

test("the canvas tool gets its own status line, and remember stays hidden", () => {
  assert.deepEqual(toolStatus(imageToolName), { lead: "Rendering on ", name: "the canvas", tone: "canvas" });
  assert.equal(toolStatus(rememberToolName), null);
  assert.deepEqual(toolStatus("mcp__figma-mcp__get_design_context"), { lead: "Calling ", name: "figma-mcp" });
});

test("the system prompt sends feedback and uncertain readings to the canvas", () => {
  assert.match(systemPrompt, /canvas is where you ask for feedback/);
  assert.match(systemPrompt, /show_image/);
  assert.match(systemPrompt, /render your best reading instead of guessing silently/);
});

test("the prompt lists each note with its point", () => {
  const prompt = buildPrompt(800, 600, [{ text: "make this blue", x: 12.4, y: 40.6 }]);
  assert.match(prompt, /800 by 600/);
  assert.match(prompt, /Mac screen/);
  assert.match(prompt, /\(12, 41\): make this blue/);
});

test("a chosen folder is named in the prompt", () => {
  const prompt = buildPrompt(800, 600, [], undefined, "/Users/me/Notes");
  assert.match(prompt, /working folder on the Mac is \/Users\/me\/Notes/);
});

test("a whole screen is named as the first image", () => {
  const prompt = buildPrompt(800, 600, [{ text: "summarize this", x: 10, y: 20 }], { width: 1920, height: 1080 });
  assert.match(prompt, /first image is the whole Mac screen, 1920 by 1080/);
  assert.match(prompt, /second image is that screen cropped/);
  assert.match(prompt, /second image/);
  assert.match(prompt, /\(10, 20\): summarize this/);
});

test("a follow-up lists the earlier summaries before the new sketch", () => {
  const prompt = buildPrompt(800, 600, [{ text: "now make it bigger", x: 5, y: 5 }], undefined, undefined, [
    { summary: "Figma frame Card (node 12:34) was selected; I made its fill blue.", reply: "I made the card blue." },
  ]);
  assert.match(prompt, /1\. Figma frame Card \(node 12:34\)/);
  assert.match(prompt, /You replied: I made the card blue\./);
  assert.ok(prompt.indexOf("node 12:34") < prompt.indexOf("now make it bigger"));
});

test("words said through the dictation button are the main request", () => {
  const prompt = buildPrompt(800, 600, [], undefined, undefined, [], "open the settings page");
  assert.match(prompt, /said this to you directly/);
  assert.match(prompt, /"open the settings page"/);
  assert.doesNotMatch(buildPrompt(800, 600, []), /said this to you directly/);
});

test("a first sketch has no history", () => {
  assert.doesNotMatch(buildPrompt(800, 600, []), /earlier/);
});
