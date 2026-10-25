import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildAgyPrompt,
  createAgyStreamState,
  executeGeminiTool,
  geminiCredentialNote,
  geminiError,
  handleAgyStreamLine,
  type GeminiEvent,
} from "./gemini.ts";

test("buildAgyPrompt references the sketch and screen images and SketchIntent tools", () => {
  const prompt = buildAgyPrompt("Make the button blue", {
    sketchPath: "/tmp/latest.png",
    screenPath: "/tmp/screen.png",
    toolScriptPath: "/tmp/sketchintent-tool.ts",
    desktops: { index: 0, count: 3 },
  });
  assert.match(prompt, /@\/tmp\/screen\.png/);
  assert.match(prompt, /@\/tmp\/latest\.png/);
  assert.match(prompt, /sketchintent-tool\.ts/);
  assert.match(prompt, /show_image/);
  assert.match(prompt, /open_on_mac/);
  assert.match(prompt, /go_to_desktop/);
  assert.match(prompt, /remember/);
  assert.match(prompt, /Make the button blue/);
});

test("geminiCredentialNote and geminiError report agy state", () => {
  assert.match(geminiCredentialNote({ SKETCHINTENT_AGY_BIN: "/bin/sh" }), /Using the Antigravity \(agy\) login/);
  assert.match(geminiError("not signed in"), /Run agy in Terminal/);
});

test("executeGeminiTool handles remember, show_image, and go_to_desktop", async () => {
  const events: GeminiEvent[] = [];
  const callbacks = {
    isConnected: () => true,
    onEvent: (event: GeminiEvent) => events.push(event),
  };
  let saved = "";
  const body = { imagePng: "aGVsbG8=", screen: null, desktops: { index: 0, count: 3 } };

  const rem = await executeGeminiTool({ name: "remember", args: { summary: "Drew a card" } }, body, callbacks, (text) => {
    saved = text;
  });
  assert.deepEqual(rem, { output: "Saved." });
  assert.equal(saved, "Drew a card");

  const img = await executeGeminiTool(
    { name: "show_image", args: { code: "<div>Hello</div>", x: 10, y: 20, width: 200, height: 100 } },
    body,
    callbacks,
    () => {},
  );
  assert.ok("output" in img);
  assert.deepEqual(events[0], { lead: "Rendering on ", name: "the canvas", tone: "canvas", type: "status" });
  assert.equal(events[1]?.type, "canvas");

  const desk = await executeGeminiTool({ name: "go_to_desktop", args: { desktop: 2 } }, body, callbacks, () => {});
  assert.deepEqual(desk, { output: "Opening desktop 2." });
  assert.deepEqual(events[2], { lead: "Switching ", name: "Mac desktop", type: "status" });
  assert.deepEqual(events[3], { type: "desktop", index: 1 });
});

test("handleAgyStreamLine parses agy stream-json tool calls, text deltas, and result", () => {
  const state = createAgyStreamState();
  const events: GeminiEvent[] = [];
  const logs: string[] = [];
  let finalSummary = "";
  let finalReply = "";
  const callbacks = {
    onEvent: (event: GeminiEvent) => events.push(event),
    onLog: (line: string) => logs.push(line),
    onSummary: (summary: string, reply: string) => {
      finalSummary = summary;
      finalReply = reply;
    },
  };

  handleAgyStreamLine(
    JSON.stringify({
      event: "step_update",
      step_update: {
        step_index: 1,
        state: "ACTIVE",
        step_type: "tool",
        tool_name: "write_to_file",
        tool_info: { name: "write_to_file", parameters: { Path: "/tmp/index.html" } },
      },
    }),
    state,
    callbacks,
    () => "Built index.html",
  );

  handleAgyStreamLine(
    JSON.stringify({
      event: "step_update",
      step_update: {
        step_index: 2,
        state: "ACTIVE",
        step_type: "agent_response",
        text_delta: "I built ",
      },
    }),
    state,
    callbacks,
    () => "Built index.html",
  );

  handleAgyStreamLine(
    JSON.stringify({
      event: "step_update",
      step_update: {
        step_index: 2,
        state: "DONE",
        step_type: "agent_response",
        text_delta: "the page.",
      },
    }),
    state,
    callbacks,
    () => "Built index.html",
  );

  handleAgyStreamLine(
    JSON.stringify({
      event: "result",
      result: {
        status: "SUCCESS",
        response: "I built the page.\n",
      },
    }),
    state,
    callbacks,
    () => "Built index.html",
  );

  assert.deepEqual(events, [
    { type: "status", lead: "Editing ", name: "files" },
    { type: "text", text: "I built" },
    { type: "text", text: "I built the page." },
    { type: "done" },
  ]);
  assert.equal(finalSummary, "Built index.html");
  assert.equal(finalReply, "I built the page.");
  assert.ok(logs.some((line) => line.includes("write_to_file")));
});
