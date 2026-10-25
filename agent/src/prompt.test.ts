import assert from "node:assert/strict";
import { test } from "node:test";
import { buildPrompt, desktopToolName, imageToolName, openToolName, parseAgentArgs, rememberToolName, systemPrompt, toolLabel, toolStatus } from "./prompt.ts";

test("tool labels use the MCP server name", () => {
  assert.equal(toolLabel("mcp__figma-mcp__get_design_context"), "figma-mcp");
  assert.equal(toolLabel("WebSearch"), "WebSearch");
});

test("the canvas tool gets its own status line, and remember stays hidden", () => {
  assert.deepEqual(toolStatus(imageToolName), { lead: "Rendering on ", name: "the canvas", tone: "canvas" });
  assert.equal(toolStatus(rememberToolName), null);
  assert.deepEqual(toolStatus("mcp__figma-mcp__get_design_context"), { lead: "Calling ", name: "figma-mcp" });
});

test("the Mac tools get their own status lines", () => {
  assert.deepEqual(toolStatus(openToolName), { lead: "Opening on ", name: "the Mac" });
  assert.deepEqual(toolStatus(desktopToolName), { lead: "Switching ", name: "Mac desktop" });
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

test("the page the sketch was drawn on is named", () => {
  const desktop = buildPrompt(800, 600, [], undefined, undefined, [], "", { page: "desktop", index: 1, count: 4 });
  assert.match(desktop, /drawn over Mac desktop 2 of 4/);
  const canvas = buildPrompt(800, 600, [], undefined, undefined, [], "", { page: "canvas" });
  assert.match(canvas, /drawn on the iPad's Canvas page/);
  const fullscreen = buildPrompt(800, 600, [], undefined, undefined, [], "", { page: "desktop", index: -1, count: 4 });
  assert.match(fullscreen, /fullscreen app/);
  assert.doesNotMatch(buildPrompt(800, 600, []), /sketch was drawn/);
});

test("commands and file edits get plain status lines", () => {
  assert.deepEqual(toolStatus("Bash"), { lead: "Running ", name: "a command" });
  assert.deepEqual(toolStatus("Edit"), { lead: "Editing ", name: "files" });
  assert.deepEqual(toolStatus("Write"), { lead: "Editing ", name: "files" });
  assert.equal(toolStatus("remember"), null);
  assert.deepEqual(toolStatus("show_image"), { lead: "Rendering on ", name: "the canvas", tone: "canvas" });
  assert.deepEqual(toolStatus("open_on_mac"), { lead: "Opening on ", name: "the Mac" });
  assert.deepEqual(toolStatus("go_to_desktop"), { lead: "Switching ", name: "Mac desktop" });
});

test("parseAgentArgs reads launch flags and environment defaults", () => {
  assert.deepEqual(parseAgentArgs([], {}), { agent: "claude", model: "sonnet", port: 2347 });
  assert.deepEqual(parseAgentArgs(["--agent", "gemini"], {}), { agent: "gemini", port: 2347 });
  assert.deepEqual(parseAgentArgs(["--agent=gemini", "--model", "gemini-2.5-flash", "--port", "2400"], {}), {
    agent: "gemini",
    model: "gemini-2.5-flash",
    port: 2400,
  });
  assert.deepEqual(parseAgentArgs(["--gemini"], { GEMINI_MODEL: "gemini-2.5-pro" }), {
    agent: "gemini",
    model: "gemini-2.5-pro",
    port: 2347,
  });
  assert.deepEqual(parseAgentArgs(["--claude"], { SKETCHINTENT_AGENT: "gemini" }), {
    agent: "claude",
    model: "sonnet",
    port: 2347,
  });
  assert.deepEqual(parseAgentArgs(["gemini"], { npm_config_agent: "true" }), {
    agent: "gemini",
    port: 2347,
  });
  assert.deepEqual(parseAgentArgs([], { npm_config_agent: "gemini" }), {
    agent: "gemini",
    port: 2347,
  });
  assert.deepEqual(parseAgentArgs(["--model", "opus"], {}), { agent: "claude", model: "opus", port: 2347 });
  assert.ok("help" in parseAgentArgs(["--help"], {}));
  assert.ok("error" in parseAgentArgs(["--agent", "other"], {}));
  assert.ok("error" in parseAgentArgs(["--unknown"], {}));
});
