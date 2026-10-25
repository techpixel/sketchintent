import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { execFileSync } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createSdkMcpServer, query, tool, type McpServerConfig, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { makeImage, type CanvasImage } from "./canvas.ts";
import { buildPrompt, systemPrompt, toolStatus, type Memory, type SketchNote } from "./prompt.ts";

const port = Number(process.env.SKETCHINTENT_AI_PORT ?? 2347);
const root = fileURLToPath(new URL("..", import.meta.url));
const debugPngPath = join(root, "debug", "latest.png");
const debugScreenPath = join(root, "debug", "screen.png");
const bodyLimit = 12_000_000;
const imageLimit = 8_000_000;
// Skills often point at reference files, so the agent can read but not change files or run commands.
const memoryLimit = 12;
const memoryIdleMs = 30 * 60_000;
const agentTools = ["Skill", "ToolSearch", "Read", "Glob", "Grep", "ListMcpResourcesTool", "ReadMcpResourceTool"];

interface ScreenImage {
  png: string;
  width: number;
  height: number;
}

interface SeenSketch {
  turn: number;
  width: number;
  height: number;
  notes: SketchNote[];
  png: Buffer;
  screen: { width: number; height: number; png: Buffer } | null;
  folder: string;
  prompt: string;
}

let seen: SeenSketch | null = null;

/// Follow-up sketches see these summaries instead of the earlier images.
/// A different folder, a long pause, or POST /v1/intent/reset starts over.
let memory: { folder: string; at: number; turns: Memory[] } = { folder: "", at: 0, turns: [] };

function earlierTurns(folder: string): Memory[] {
  if (memory.folder !== folder || Date.now() - memory.at > memoryIdleMs) {
    memory = { folder, at: Date.now(), turns: [] };
  }
  return memory.turns;
}

function rememberTurn(folder: string, turn: Memory) {
  if (memory.folder !== folder) memory = { folder, at: 0, turns: [] };
  memory.turns = [...memory.turns, turn].slice(-memoryLimit);
  memory.at = Date.now();
}

function fallbackSummary(notes: SketchNote[]): string {
  if (notes.length === 0) return "A sketch with no voice notes.";
  return `A sketch with the notes: ${notes.map((note) => `"${note.text}"`).join(", ")}.`;
}

interface IntentBody {
  imagePng: string;
  width: number;
  height: number;
  notes: SketchNote[];
  screen: ScreenImage | null;
  folder: string;
}

type ClientEvent =
  | { type: "status"; lead: string; name: string; tone?: "canvas" }
  | { type: "text"; text: string }
  | ({ type: "canvas" } & CanvasImage)
  | { type: "done" }
  | { type: "error"; message: string };

let active: AbortController | null = null;
let nextTurn = 0;
const loggedLines = new Map<number, Set<string>>();

function logTurn(turn: number, message: string) {
  const line = `#${turn} ${message}`;
  let seen = loggedLines.get(turn);
  if (!seen) {
    seen = new Set();
    loggedLines.set(turn, seen);
  }
  if (seen.has(line)) return;
  seen.add(line);
  console.log(`[sketchintent-ai] ${line}`);
}

function preview(value: unknown): string {
  const text = typeof value === "string" ? value : JSON.stringify(value) ?? "";
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > 2000 ? `${flat.slice(0, 2000)}…` : flat;
}

function writeEvent(response: ServerResponse, turn: number, event: ClientEvent) {
  if (event.type === "status") logTurn(turn, `→ ${event.lead}${event.name}`);
  else if (event.type === "error") logTurn(turn, `→ error ${event.message}`);
  else if (event.type === "done") logTurn(turn, "→ done");
  else if (event.type === "canvas") {
    logTurn(turn, `→ canvas image ${event.width}×${event.height} at (${event.x}, ${event.y}) in ${event.space}, ${event.html.length} chars`);
  }
  if (response.writableEnded || response.destroyed) return;
  response.write(`${JSON.stringify(event)}\n`);
}

function readBody(request: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > bodyLimit) {
        reject(new Error("The sketch is too large."));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function parseIntent(raw: Buffer): IntentBody {
  const value: unknown = JSON.parse(raw.toString("utf8"));
  if (typeof value !== "object" || value === null) throw new Error("Expected a JSON object.");
  const body = value as Record<string, unknown>;
  if (typeof body.imagePng !== "string" || body.imagePng.length === 0) {
    throw new Error("The sketch image is missing.");
  }
  if (Math.ceil(body.imagePng.length * 0.75) > imageLimit) {
    throw new Error("The sketch is too large.");
  }
  const width = body.width;
  const height = body.height;
  if (typeof width !== "number" || typeof height !== "number" || width < 1 || height < 1) {
    throw new Error("The sketch size is missing.");
  }
  if (!Array.isArray(body.notes)) throw new Error("Voice notes are missing.");
  const notes: SketchNote[] = [];
  for (const note of body.notes.slice(0, 50)) {
    if (typeof note !== "object" || note === null) continue;
    const item = note as Record<string, unknown>;
    if (typeof item.text !== "string" || typeof item.x !== "number" || typeof item.y !== "number") continue;
    const text = item.text.trim().slice(0, 2000);
    if (!text) continue;
    notes.push({ text, x: item.x, y: item.y });
  }
  return { imagePng: body.imagePng, width, height, notes, screen: parseScreen(body), folder: parseFolder(body.folder) };
}

function parseFolder(value: unknown): string {
  if (typeof value !== "string" || !value.startsWith("/") || value.includes("\0") || value.length > 1024) return "";
  return value;
}

function parseScreen(body: Record<string, unknown>): ScreenImage | null {
  if (typeof body.screenPng !== "string" || body.screenPng.length === 0) return null;
  if (Math.ceil(body.screenPng.length * 0.75) > imageLimit) {
    throw new Error("The screen image is too large.");
  }
  const width = body.screenWidth;
  const height = body.screenHeight;
  if (typeof width !== "number" || typeof height !== "number" || width < 1 || height < 1) {
    throw new Error("The screen size is missing.");
  }
  return { png: body.screenPng, width, height };
}

async function loadMcpServers(): Promise<Record<string, McpServerConfig>> {
  const configured = process.env.SKETCHINTENT_MCP_CONFIG;
  const path = configured && configured.length > 0 ? configured : fileURLToPath(new URL("../mcp.json", import.meta.url));
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("mcp.json must be an object of server names.");
    }
    return parsed as Record<string, McpServerConfig>;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return {};
    throw error;
  }
}

async function* oneTurn(message: SDKUserMessage, closed: AbortSignal): AsyncGenerator<SDKUserMessage> {
  yield message;
  await new Promise<void>((resolve) => {
    if (closed.aborted) {
      resolve();
      return;
    }
    closed.addEventListener("abort", () => resolve(), { once: true });
  });
}

function logInput(turn: number, body: IntentBody, prompt: string) {
  const padding = body.imagePng.endsWith("==") ? 2 : body.imagePng.endsWith("=") ? 1 : 0;
  const bytes = Math.max(0, Math.floor(body.imagePng.length * 0.75) - padding);
  const notes = body.notes.length === 1 ? "1 note" : `${body.notes.length} notes`;
  logTurn(turn, `← ${body.width}×${body.height}, image ${bytes} bytes, ${notes}`);
  for (const note of body.notes) {
    logTurn(turn, `← (${Math.round(note.x)}, ${Math.round(note.y)}) ${note.text}`);
  }
  if (body.folder) logTurn(turn, `← folder ${body.folder}`);
  if (body.screen) {
    const padding = body.screen.png.endsWith("==") ? 2 : body.screen.png.endsWith("=") ? 1 : 0;
    const screenBytes = Math.max(0, Math.floor(body.screen.png.length * 0.75) - padding);
    logTurn(turn, `← screen ${body.screen.width}×${body.screen.height}, image ${screenBytes} bytes`);
  }
  logTurn(turn, `← sketch http://127.0.0.1:${port}/debug/latest`);
  logTurn(turn, `← prompt\n${prompt}`);
}

async function rememberSketch(turn: number, body: IntentBody, prompt: string) {
  const png = Buffer.from(body.imagePng, "base64");
  const screen = body.screen
    ? { width: body.screen.width, height: body.screen.height, png: Buffer.from(body.screen.png, "base64") }
    : null;
  seen = { turn, width: body.width, height: body.height, notes: body.notes, png, screen, folder: body.folder, prompt };
  try {
    await mkdir(join(root, "debug"), { recursive: true });
    await writeFile(debugPngPath, png);
    if (screen) await writeFile(debugScreenPath, screen.png);
    logTurn(turn, `← file ${debugPngPath}`);
  } catch (error) {
    console.error(`[sketchintent-ai] #${turn} could not save the sketch: ${errorMessage(error)}`);
  }
}

async function workingDirectory(turn: number, folder: string): Promise<string> {
  if (!folder) return root;
  try {
    const info = await stat(folder);
    if (!info.isDirectory()) throw new Error("not a directory");
    return folder;
  } catch {
    logTurn(turn, `← folder unavailable, using ${root}`);
    return root;
  }
}

const spaceField = z
  .enum(["sketch", "screen"])
  .optional()
  .describe("sketch: pixels of the cropped sketch image, where the voice notes are. screen: pixels of the whole-screen image. Defaults to sketch.");

async function runIntent(turn: number, body: IntentBody, prompt: string, response: ServerResponse, abort: AbortController) {
  const inputClosed = new AbortController();
  let sawText = false;
  let loggedText = false;
  let blockText = "";
  let blockIsText = false;
  let summary = "";
  const memoryServer = createSdkMcpServer({
    name: "sketchintent",
    tools: [
      tool(
        "remember",
        "Save a summary of this sketch for follow-up sketches, which will not see its images.",
        { summary: z.string().describe("What the screen showed, what the ink marked, what the notes asked, and what you did.") },
        async (args) => {
          summary = args.summary.trim().slice(0, 2000);
          return { content: [{ type: "text", text: "Saved." }] };
        },
        { alwaysLoad: true },
      ),
      tool(
        "show_image",
        [
          "Render code to an image and place it on the person's iPad canvas, under their ink, to get their feedback.",
          "Use it for anything you want them to check: your reading of a sketch you are not confident about, a design you are proposing, or a result to approve before you act.",
          "Build it in HTML, CSS, SVG, or a canvas script, and place it beside the part of the sketch it interprets.",
          "The person corrects it by sketching and adding notes on top, then sends again, and you see the image with their marks in the next sketch.",
          "The page is rendered at the image's size in points, with no scrolling and no network wait, so inline everything it needs.",
        ].join(" "),
        {
          code: z.string().min(1).describe("A full HTML document, an HTML fragment, or an SVG element."),
          format: z.enum(["html", "svg"]).optional().describe("Defaults to html."),
          x: z.number().describe("Left edge, in pixels of the chosen space."),
          y: z.number().describe("Top edge, in pixels of the chosen space."),
          width: z.number().positive(),
          height: z.number().positive(),
          space: spaceField,
        },
        async (args) => {
          const fail = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });
          const space = args.space ?? "sketch";
          if (space === "screen" && !body.screen) return fail("No whole-screen image came with this sketch. Use the sketch space.");
          const image = makeImage(args.code, args.format ?? "html", space, args);
          if (!image) return fail("That image is too large for the iPad, or its size is zero. Use smaller code or a real size.");
          if (response.writableEnded || response.destroyed) return fail("The iPad is no longer connected.");
          writeEvent(response, turn, { type: "canvas", ...image });
          return {
            content: [
              {
                type: "text" as const,
                text: "The iPad is rendering it on the canvas. The person will mark it up and send it back if it is wrong.",
              },
            ],
          };
        },
        { alwaysLoad: true },
      ),
    ],
  });
  const message: SDKUserMessage = {
    type: "user",
    parent_tool_use_id: null,
    client_composed: true,
    message: {
      role: "user",
      content: [
        ...(body.screen
          ? [
              {
                type: "image" as const,
                source: { type: "base64" as const, media_type: "image/png" as const, data: body.screen.png },
              },
            ]
          : []),
        {
          type: "image" as const,
          source: { type: "base64" as const, media_type: "image/png" as const, data: body.imagePng },
        },
        { type: "text" as const, text: prompt },
      ],
    },
  };

  const mcpServers = await loadMcpServers();
  const mcpNames = Object.keys(mcpServers);
  logTurn(turn, mcpNames.length === 0 ? "← mcp.json none" : `← mcp.json ${mcpNames.join(", ")}`);
  try {
    const stream = query({
      prompt: oneTurn(message, inputClosed.signal),
      options: {
        cwd: await workingDirectory(turn, body.folder),
        abortController: abort,
        persistSession: false,
        // Load the same settings, plugins, MCP servers and skills as the claude CLI on this Mac.
        settingSources: ["user", "project", "local"],
        skills: "all",
        includePartialMessages: true,
        maxTurns: 24,
        tools: agentTools,
        systemPrompt,
        mcpServers: { ...mcpServers, sketchintent: memoryServer },
        permissionMode: "default",
        ...(process.env.SKETCHINTENT_MODEL ? { model: process.env.SKETCHINTENT_MODEL } : {}),
        canUseTool: async (toolName, input) => {
          if (toolName.startsWith("mcp__") || agentTools.includes(toolName)) {
            return { behavior: "allow", updatedInput: input };
          }
          logTurn(turn, `→ deny ${toolName}`);
          return {
            behavior: "deny",
            message: "This agent can only use MCP tools, skills, and read-only file tools.",
          };
        },
        stderr: (line) => {
          process.stderr.write(`[sketchintent-ai] ${line}`);
        },
      },
    });

    for await (const event of stream) {
      if (event.type === "stream_event") {
        const raw = event.event;
        if (raw.type === "content_block_start" && raw.content_block.type === "tool_use") {
          blockIsText = false;
          const status = toolStatus(raw.content_block.name);
          if (!status) continue;
          writeEvent(response, turn, { type: "status", ...status });
        } else if (raw.type === "content_block_start" && raw.content_block.type === "text") {
          blockIsText = true;
          blockText = "";
        } else if (raw.type === "content_block_delta" && raw.delta.type === "text_delta") {
          blockText += raw.delta.text;
          sawText = true;
          writeEvent(response, turn, { type: "text", text: blockText });
        } else if (raw.type === "content_block_stop" && blockIsText && blockText) {
          logTurn(turn, `→ ${blockText}`);
          loggedText = true;
          blockIsText = false;
        }
      } else if (event.type === "system" && event.subtype === "init") {
        const servers = event.mcp_servers.map((server) => `${server.name} (${server.status})`);
        logTurn(turn, `← mcp ${servers.length === 0 ? "none" : servers.join(", ")}`);
        logTurn(turn, `← skills ${event.skills.length === 0 ? "none" : event.skills.join(", ")}`);
      } else if (event.type === "assistant") {
        if (event.error) {
          writeEvent(response, turn, { type: "error", message: agentError(event.error) });
        }
        for (const block of event.message.content) {
          if (block.type === "tool_use") {
            const status = toolStatus(block.name);
            if (status) writeEvent(response, turn, { type: "status", ...status });
            logTurn(turn, `→ tool ${block.name} ${preview(block.input)}`);
          } else if (block.type === "thinking") {
            logTurn(turn, `→ thinking ${preview(block.thinking)}`);
          }
        }
      } else if (event.type === "user") {
        logToolResults(turn, event);
      } else if (event.type === "result") {
        // The in-process memory server keeps the SDK reading input, so end the input to finish the turn.
        inputClosed.abort();
        if (event.subtype === "success") {
          if (event.is_error) {
            writeEvent(response, turn, { type: "error", message: event.result || "The agent stopped." });
          } else {
            if (!sawText && event.result) {
              writeEvent(response, turn, { type: "text", text: event.result });
              logTurn(turn, `→ ${event.result}`);
              loggedText = true;
            }
            rememberTurn(body.folder, {
              summary: summary || fallbackSummary(body.notes),
              reply: (event.result || blockText).trim().slice(0, 500),
            });
            if (!summary) logTurn(turn, "→ no summary saved, keeping the notes instead");
            writeEvent(response, turn, { type: "done" });
          }
        } else {
          writeEvent(response, turn, {
            type: "error",
            message: event.errors[0] ?? "The agent stopped.",
          });
        }
      }
    }
  } finally {
    if (!loggedText && blockText) logTurn(turn, `→ ${blockText}`);
    if (abort.signal.aborted) logTurn(turn, "→ cancelled");
    inputClosed.abort();
  }
}

function logToolResults(turn: number, event: SDKUserMessage) {
  const content = event.message.content;
  if (!Array.isArray(content)) return;
  for (const block of content) {
    if (typeof block !== "object" || block === null || !("type" in block) || block.type !== "tool_result") continue;
    const id = "tool_use_id" in block ? String(block.tool_use_id) : "";
    const text = "content" in block ? preview(block.content) : "";
    logTurn(turn, `← tool result ${id} ${text}`.trim());
  }
}

function sendJSON(response: ServerResponse, status: number, payload: unknown) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

const server = createServer((request, response) => {
  void handle(request, response);
});

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function debugPage(): string {
  const sketch = seen;
  const picture = sketch
    ? `<p class="meta">Turn ${sketch.turn}</p>
${
  sketch.screen
    ? `<p class="meta">Whole screen · ${sketch.screen.width}×${sketch.screen.height}</p>
<img class="screen" src="/debug/screen.png?turn=${sketch.turn}" alt="Whole Mac screen sent to the agent">`
    : ""
}
<p class="meta">Sketch · ${sketch.width}×${sketch.height}</p>
<div class="stage">
  <img src="/debug/latest.png?turn=${sketch.turn}" alt="Cropped sketch sent to the agent">
  ${sketch.notes
    .map((note) => {
      const left = (note.x / sketch.width) * 100;
      const top = (note.y / sketch.height) * 100;
      return `<div class="note" style="left:${left}%;top:${top}%"><span>${escapeHTML(note.text)}</span></div>`;
    })
    .join("")}
</div>
<p class="caption">The dots are the voice-note points. They are drawn on this page only. The images sent to the agent do not include the dots.</p>
<pre>${escapeHTML(sketch.prompt)}</pre>`
    : `<p class="meta">No sketch yet. Send one from the iPad, then refresh.</p>`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sketch the agent sees</title>
  <style>
    body { margin: 24px; font: 15px/1.4 ui-sans-serif, system-ui, sans-serif; color: #1c1c1e; background: #f2f2f7; }
    h1 { font-size: 20px; font-weight: 600; margin: 0 0 8px; }
    .meta, .caption { color: #636366; }
    .screen { display: block; max-width: min(100%, 960px); height: auto; background: white; box-shadow: 0 1px 4px rgba(0,0,0,0.12); margin-bottom: 16px; }
    .stage { position: relative; display: inline-block; max-width: 100%; background: white; box-shadow: 0 1px 4px rgba(0,0,0,0.12); }
    .stage img { display: block; width: ${sketch ? sketch.width : 0}px; max-width: 100%; height: auto; }
    .note { position: absolute; width: 14px; height: 14px; margin: -7px 0 0 -7px; border-radius: 50%; background: #ff3b30; border: 2px solid white; box-shadow: 0 0 0 1px rgba(0,0,0,0.25); }
    .note span { position: absolute; left: 18px; top: -4px; max-width: 280px; padding: 2px 8px; border-radius: 6px; background: rgba(0,0,0,0.78); color: white; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    pre { white-space: pre-wrap; background: white; padding: 12px 16px; border-radius: 8px; }
  </style>
</head>
<body>
  <h1>What the agent sees</h1>
  ${picture}
</body>
</html>`;
}

function sendHTML(response: ServerResponse, html: string) {
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": Buffer.byteLength(html),
    "Cache-Control": "no-store",
  });
  response.end(html);
}

function sendPng(response: ServerResponse, png: Buffer | undefined) {
  if (!png) {
    sendJSON(response, 404, { error: "No sketch yet." });
    return;
  }
  response.writeHead(200, {
    "Content-Type": "image/png",
    "Content-Length": png.length,
    "Cache-Control": "no-store",
  });
  response.end(png);
}

async function handle(request: IncomingMessage, response: ServerResponse) {
  const pathname = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
  if (request.method === "GET" && request.url === "/health") {
    sendJSON(response, 200, { ok: true });
    return;
  }
  if (request.method === "GET" && (pathname === "/debug" || pathname === "/debug/latest")) {
    sendHTML(response, debugPage());
    return;
  }
  if (request.method === "GET" && pathname === "/debug/latest.png") {
    sendPng(response, seen?.png);
    return;
  }
  if (request.method === "GET" && pathname === "/debug/screen.png") {
    sendPng(response, seen?.screen?.png);
    return;
  }
  if (request.method === "POST" && pathname === "/v1/intent/reset") {
    memory = { folder: "", at: 0, turns: [] };
    console.log("[sketchintent-ai] ← reset, the next sketch starts a new conversation");
    sendJSON(response, 200, { ok: true });
    return;
  }
  if (request.method !== "POST" || request.url !== "/v1/intent") {
    sendJSON(response, 404, { error: "Not found." });
    return;
  }
  let body: IntentBody;
  try {
    body = parseIntent(await readBody(request));
  } catch (error) {
    const message = error instanceof SyntaxError ? "The sketch could not be read." : errorMessage(error);
    console.log(`[sketchintent-ai] ← rejected ${message}`);
    sendJSON(response, 400, { error: message });
    return;
  }

  const turn = ++nextTurn;
  const earlier = earlierTurns(body.folder);
  const prompt = buildPrompt(body.width, body.height, body.notes, body.screen ?? undefined, body.folder || undefined, earlier);
  await rememberSketch(turn, body, prompt);
  logInput(turn, body, prompt);
  if (earlier.length > 0) logTurn(turn, `← follow-up to ${earlier.length} earlier ${earlier.length === 1 ? "sketch" : "sketches"}`);
  active?.abort();
  const abort = new AbortController();
  active = abort;
  response.writeHead(200, {
    "Content-Type": "application/x-ndjson",
    "Cache-Control": "no-cache",
  });
  response.flushHeaders();
  response.on("close", () => {
    if (!response.writableEnded) abort.abort();
  });

  try {
    await runIntent(turn, body, prompt, response, abort);
  } catch (error) {
    if (!abort.signal.aborted) {
      writeEvent(response, turn, { type: "error", message: errorMessage(error) });
    }
  } finally {
    if (active === abort) active = null;
    if (!response.writableEnded) response.end();
    loggedLines.delete(turn);
  }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return agentError(error.message);
  return "The agent could not answer.";
}

function agentError(error: string): string {
  if (error === "authentication_failed") {
    return "Claude isn't signed in for this server. Run claude in Terminal and sign in, or set ANTHROPIC_API_KEY.";
  }
  return error;
}

function credentialNote(): string {
  if (process.env.ANTHROPIC_API_KEY) return "Using ANTHROPIC_API_KEY.";
  if (process.env.CLAUDE_CODE_OAUTH_TOKEN) return "Using CLAUDE_CODE_OAUTH_TOKEN.";
  const home = homedir();
  for (const file of [`${home}/.claude/.credentials.json`, `${home}/.claude/credentials.json`]) {
    try {
      accessSync(file, constants.R_OK);
      return "Using the Claude Code login on this Mac.";
    } catch {
      // This file is not where the login lives.
    }
  }
  try {
    execFileSync("security", ["find-generic-password", "-s", "Claude Code-credentials"], {
      stdio: "ignore",
      timeout: 3000,
    });
    return "Using the Claude Code login on this Mac.";
  } catch {
    return "No Claude login found. Run claude in Terminal and sign in, or set ANTHROPIC_API_KEY.";
  }
}

server.on("error", (error) => {
  console.error(`[sketchintent-ai] ${error.message}`);
  process.exit(1);
});

server.listen(port, "127.0.0.1", () => {
  console.log(`[sketchintent-ai] Listening on 127.0.0.1:${port}.`);
  console.log(`[sketchintent-ai] ${credentialNote()}`);
  console.log(`[sketchintent-ai] system ${systemPrompt}`);
  console.log(`[sketchintent-ai] Open http://127.0.0.1:${port}/debug/latest to see the sketch the agent received.`);
  console.log("[sketchintent-ai] The iPad reaches this through the SketchIntent USB connection.");
  console.log("[sketchintent-ai] Follow-up sketches remember earlier ones. POST /v1/intent/reset starts over.");
  console.log("[sketchintent-ai] Uses the MCP servers, plugins and skills of your Claude Code setup. Extra MCP servers go in agent/mcp.json.");
});

function shutdown() {
  active?.abort();
  server.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
