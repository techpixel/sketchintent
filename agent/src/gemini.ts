import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { makeImage, type CanvasImage, type CanvasSpace, type ImageFormat } from "./canvas.ts";
import { openOnMac } from "./mac.ts";
import { systemPrompt, toolStatus } from "./prompt.ts";

const stageDir = join(tmpdir(), "sketchintent-ai");
export const defaultToolScriptPath = join(stageDir, "sketchintent-tool.mjs");

const toolScriptSource = `const port = Number(process.env.SKETCHINTENT_AI_PORT ?? 2347);
const [, , toolName, rawArgs] = process.argv;
if (!toolName) {
  console.error("Usage: node sketchintent-tool.mjs <remember|show_image|open_on_mac|go_to_desktop> '<json-args>'");
  process.exit(2);
}
let args = {};
if (rawArgs && rawArgs.trim()) {
  try {
    const parsed = JSON.parse(rawArgs);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) args = parsed;
  } catch (error) {
    console.error("Invalid JSON arguments:", error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}
const response = await fetch(\`http://127.0.0.1:\${port}/v1/tool\`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ tool: toolName, args }),
});
const result = await response.json();
if (!response.ok || result.error) {
  console.error(result.error ?? \`Tool \${toolName} failed with status \${response.status}.\`);
  process.exit(1);
}
if (result.output) console.log(result.output);
`;

export interface GeminiIntentInput {
  imagePng: string;
  screen: { png: string; width: number; height: number } | null;
  desktops: { index: number; count: number } | null;
}

export type GeminiEvent =
  | { type: "status"; lead: string; name: string; tone?: "canvas" }
  | { type: "text"; text: string }
  | ({ type: "canvas" } & CanvasImage)
  | { type: "desktop"; index: number }
  | { type: "screen" }
  | { type: "done" }
  | { type: "error"; message: string };

export interface GeminiRunCallbacks {
  cwd: string;
  port?: number;
  model?: string;
  system?: string;
  sketchPath: string;
  screenPath?: string;
  abort: AbortSignal;
  isConnected: () => boolean;
  onEvent: (event: GeminiEvent) => void;
  onLog: (message: string) => void;
  onSummary: (summary: string, reply: string) => void;
}

export function resolveAgyBinary(env: NodeJS.ProcessEnv = process.env): string | null {
  const candidates = [
    env.SKETCHINTENT_AGY_BIN?.trim(),
    join(homedir(), ".local", "bin", "agy"),
    "/opt/homebrew/bin/agy",
    "/usr/local/bin/agy",
  ].filter((item): item is string => Boolean(item));
  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try next candidate.
    }
  }
  return null;
}

export function geminiCredentialNote(env: NodeJS.ProcessEnv = process.env): string {
  const bin = resolveAgyBinary(env);
  if (bin) return `Using the Antigravity (agy) login on this Mac (${bin}).`;
  return "Antigravity CLI (agy) not found. Install agy or set SKETCHINTENT_AGY_BIN.";
}

export function geminiError(message: string): string {
  if (message.includes("not signed in") || message.includes("auth_revoked") || message.includes("UNAUTHENTICATED")) {
    return "Antigravity isn't signed in for this server. Run agy in Terminal and sign in.";
  }
  return message;
}

function preview(value: unknown): string {
  const text = typeof value === "string" ? value : JSON.stringify(value) ?? "";
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > 2000 ? `${flat.slice(0, 2000)}…` : flat;
}

export function buildAgyPrompt(
  prompt: string,
  options: {
    cwd?: string;
    system?: string;
    sketchPath: string;
    screenPath?: string;
    toolScriptPath?: string;
    desktops: { index: number; count: number } | null;
  },
): string {
  const toolScript = options.toolScriptPath ?? defaultToolScriptPath;
  const desktopLine = options.desktops
    ? `The display has ${options.desktops.count} desktops, numbered 1 to ${options.desktops.count} from left to right. ${options.desktops.index >= 0 ? `Desktop ${options.desktops.index + 1} is on screen now.` : "A fullscreen app is on screen now."}`
    : "The Mac did not say how many desktops it has.";

  const workspaceLine = options.cwd
    ? `IMPORTANT: Your active workspace and working directory is "${options.cwd}". Create, edit, and run all project files strictly inside "${options.cwd}" (never in the temporary image folder).`
    : "";

  const imageLines = options.screenPath
    ? [
        `First image (whole Mac screen): @${options.screenPath} (${options.screenPath})`,
        `Second image (cropped sketch): @${options.sketchPath} (${options.sketchPath})`,
        "Read both images first with read_file so you can see the screen and the sketch.",
      ]
    : [
        `Cropped sketch image: @${options.sketchPath} (${options.sketchPath})`,
        "Read the sketch image first with read_file so you can see what was drawn.",
      ];

  const toolLines = [
    "To interact with the iPad Canvas, the Mac screen, or sketch memory, run these commands with run_command:",
    `- show_image (render HTML or SVG on the iPad Canvas page): node ${JSON.stringify(toolScript)} show_image '{"code":"<html>...</html>","format":"html","x":0,"y":0,"width":400,"height":300,"space":"sketch"}'`,
    `- open_on_mac (open an app, http/https URL, or file/folder on the Mac): node ${JSON.stringify(toolScript)} open_on_mac '{"target":"Safari"}'`,
    `- go_to_desktop (switch Mac Space; ${desktopLine}): node ${JSON.stringify(toolScript)} go_to_desktop '{"desktop":1}'`,
    `- remember (save a summary of this sketch before your final reply): node ${JSON.stringify(toolScript)} remember '{"summary":"..."}'`,
    "Do not include markdown file:// links in your final spoken/text reply to the iPad; reply in one or two short plain sentences.",
  ];

  return [
    options.system ?? systemPrompt,
    ...(workspaceLine ? ["", workspaceLine] : []),
    "",
    ...imageLines,
    "",
    ...toolLines,
    "",
    prompt,
  ].join("\n");
}

export async function executeGeminiTool(
  call: { name?: string; args?: Record<string, unknown> },
  body: GeminiIntentInput,
  callbacks: Pick<GeminiRunCallbacks, "isConnected" | "onEvent">,
  setSummary: (text: string) => void,
): Promise<Record<string, unknown>> {
  const name = call.name ?? "";
  const args = (call.args ?? {}) as Record<string, unknown>;

  if (name === "remember") {
    const text = typeof args.summary === "string" ? args.summary.trim().slice(0, 2000) : "";
    setSummary(text);
    return { output: "Saved." };
  }

  if (name === "show_image") {
    const code = typeof args.code === "string" ? args.code : "";
    const format: ImageFormat = args.format === "svg" ? "svg" : "html";
    const space: CanvasSpace = args.space === "screen" ? "screen" : "sketch";
    const x = Number(args.x ?? 0);
    const y = Number(args.y ?? 0);
    const width = Number(args.width ?? 0);
    const height = Number(args.height ?? 0);
    if (!code) return { error: "The code for the image is missing." };
    if (space === "screen" && !body.screen) {
      return { error: "No whole-screen image came with this sketch. Use the sketch space." };
    }
    const image = makeImage(code, format, space, { x, y, width, height });
    if (!image) {
      return { error: "That image is too large for the iPad, or its size is zero. Use smaller code or a real size." };
    }
    if (!callbacks.isConnected()) return { error: "The iPad is no longer connected." };
    const status = toolStatus("show_image");
    if (status) callbacks.onEvent({ type: "status", ...status });
    callbacks.onEvent({ type: "canvas", ...image });
    return {
      output: "The iPad is adding it to its Canvas page. The person will mark it up there and send it back if it is wrong.",
    };
  }

  if (name === "open_on_mac") {
    const target = typeof args.target === "string" ? args.target : "";
    const app = typeof args.app === "string" ? args.app : undefined;
    const status = toolStatus("open_on_mac");
    if (status) callbacks.onEvent({ type: "status", ...status });
    const failed = await openOnMac(target, app);
    if (failed) return { error: failed };
    callbacks.onEvent({ type: "screen" });
    return { output: "Opened. The iPad is showing the Mac screen." };
  }

  if (name === "go_to_desktop") {
    const desktop = Number(args.desktop);
    if (!Number.isInteger(desktop) || desktop < 1) return { error: "Desktop number must be an integer starting at 1." };
    if (body.desktops && desktop > body.desktops.count) return { error: `There are only ${body.desktops.count} desktops.` };
    if (desktop > 256) return { error: "There is no such desktop." };
    if (!callbacks.isConnected()) return { error: "The iPad is no longer connected." };
    const status = toolStatus("go_to_desktop");
    if (status) callbacks.onEvent({ type: "status", ...status });
    callbacks.onEvent({ type: "desktop", index: desktop - 1 });
    return { output: `Opening desktop ${desktop}.` };
  }

  return { error: `Unknown tool ${name}.` };
}

export interface AgyStreamState {
  currentStepIndex: number | null;
  blockText: string;
  sawText: boolean;
  finished: boolean;
}

export function createAgyStreamState(): AgyStreamState {
  return {
    currentStepIndex: null,
    blockText: "",
    sawText: false,
    finished: false,
  };
}

function isSketchIntentToolCommand(parameters: Record<string, unknown> | undefined): boolean {
  const commandLine = typeof parameters?.CommandLine === "string" ? parameters.CommandLine : "";
  return commandLine.includes("sketchintent-tool.");
}

export function handleAgyStreamLine(
  line: string,
  state: AgyStreamState,
  callbacks: Pick<GeminiRunCallbacks, "onEvent" | "onLog" | "onSummary">,
  getSummary: () => string,
) {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) return;
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(trimmed) as Record<string, unknown>;
  } catch {
    return;
  }

  const eventType = parsed.event;
  if (eventType === "init") {
    const convId = typeof parsed.conversation_id === "string" ? parsed.conversation_id : "";
    const initObj = (parsed.init ?? {}) as Record<string, unknown>;
    const mode = typeof initObj.permission_mode === "string" ? initObj.permission_mode : "default";
    const initCwd = typeof initObj.cwd === "string" ? initObj.cwd : "";
    callbacks.onLog(`← agy conversation ${convId || "started"} (${mode})${initCwd ? ` in ${initCwd}` : ""}`);
    return;
  }

  if (eventType === "step_update") {
    const step = (parsed.step_update ?? {}) as Record<string, unknown>;
    const stepType = step.step_type;
    const stepState = step.state;
    const stepIndex = typeof step.step_index === "number" ? step.step_index : null;

    if (stepType === "agent_response") {
      if (stepIndex !== null && state.currentStepIndex !== stepIndex) {
        state.currentStepIndex = stepIndex;
        state.blockText = "";
      }
      const delta = typeof step.text_delta === "string" ? step.text_delta : "";
      if (delta) {
        state.blockText += delta;
        if (state.blockText.trim()) {
          state.sawText = true;
          callbacks.onEvent({ type: "text", text: state.blockText.trim() });
        }
      }
      if (stepState === "DONE" && state.blockText.trim()) {
        callbacks.onLog(`→ ${state.blockText.trim()}`);
      }
      return;
    }

    if (stepType === "tool") {
      const toolInfo = (step.tool_info ?? {}) as Record<string, unknown>;
      const params = (toolInfo.parameters ?? undefined) as Record<string, unknown> | undefined;
      const rawName = typeof step.tool_name === "string" ? step.tool_name : typeof toolInfo.name === "string" ? toolInfo.name : "tool";

      if (stepState === "ACTIVE") {
        if (!isSketchIntentToolCommand(params)) {
          const mcpServer = rawName === "call_mcp_tool" && typeof params?.ServerName === "string" ? `mcp__${params.ServerName}__call` : rawName;
          const status = toolStatus(mcpServer);
          if (status) callbacks.onEvent({ type: "status", ...status });
        }
        callbacks.onLog(`→ tool ${rawName} ${preview(params ?? {})}`);
      } else if (stepState === "DONE" && toolInfo.output !== undefined) {
        callbacks.onLog(`← tool result ${rawName} ${preview(toolInfo.output)}`);
      }
    }
    return;
  }

  if (eventType === "result") {
    state.finished = true;
    const result = (parsed.result ?? {}) as Record<string, unknown>;
    const status = typeof result.status === "string" ? result.status : "";
    const responseText = typeof result.response === "string" ? result.response.trim() : "";
    const errorText = typeof result.error === "string" ? result.error.trim() : "";

    if (status === "SUCCESS") {
      if (!state.sawText && responseText) {
        callbacks.onEvent({ type: "text", text: responseText });
        callbacks.onLog(`→ ${responseText}`);
      }
      const reply = (responseText || state.blockText).trim();
      callbacks.onSummary(getSummary(), reply);
      callbacks.onEvent({ type: "done" });
    } else {
      callbacks.onEvent({
        type: "error",
        message: geminiError(errorText || responseText || "The agent stopped."),
      });
    }
  }
}

async function stageTurnFiles(sketchPath: string, screenPath?: string): Promise<{ stagedSketch: string; stagedScreen?: string; toolScript: string }> {
  await mkdir(stageDir, { recursive: true });
  const stagedSketch = join(stageDir, "latest.png");
  await copyFile(sketchPath, stagedSketch);
  let stagedScreen: string | undefined;
  if (screenPath) {
    stagedScreen = join(stageDir, "screen.png");
    await copyFile(screenPath, stagedScreen);
  }
  await writeFile(defaultToolScriptPath, toolScriptSource, "utf8");
  return { stagedSketch, stagedScreen, toolScript: defaultToolScriptPath };
}

export async function runGeminiIntent(
  body: GeminiIntentInput,
  prompt: string,
  callbacks: GeminiRunCallbacks,
  getSummary: () => string,
) {
  const agyBin = resolveAgyBinary();
  if (!agyBin) {
    callbacks.onEvent({
      type: "error",
      message: "Antigravity CLI (agy) isn't installed on this Mac. Install agy or set SKETCHINTENT_AGY_BIN.",
    });
    return;
  }

  const { stagedSketch, stagedScreen, toolScript } = await stageTurnFiles(callbacks.sketchPath, callbacks.screenPath);

  const fullPrompt = buildAgyPrompt(prompt, {
    cwd: callbacks.cwd,
    system: callbacks.system,
    sketchPath: stagedSketch,
    screenPath: stagedScreen,
    toolScriptPath: toolScript,
    desktops: body.desktops,
  });

  // Only pass the user's chosen workspace folder (`callbacks.cwd`) and the temp stage folder
  // so `agy` never discovers the SketchIntent server's own git repository.
  const args = [
    "--print",
    fullPrompt,
    "--output-format",
    "stream-json",
    "--dangerously-skip-permissions",
    "--disable-slash-commands",
    "--add-dir",
    callbacks.cwd,
    "--add-dir",
    stageDir,
    ...(callbacks.model ? ["--model", callbacks.model] : []),
  ];

  await new Promise<void>((resolvePromise) => {
    const child = spawn(agyBin, args, {
      cwd: callbacks.cwd,
      env: {
        ...process.env,
        ...(callbacks.port ? { SKETCHINTENT_AI_PORT: String(callbacks.port) } : {}),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    const state = createAgyStreamState();
    let stdoutBuffer = "";
    let stderrText = "";

    const onAbort = () => {
      child.kill("SIGTERM");
    };
    callbacks.abort.addEventListener("abort", onAbort, { once: true });

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutBuffer += chunk.toString("utf8");
      let newline = stdoutBuffer.indexOf("\n");
      while (newline >= 0) {
        const line = stdoutBuffer.slice(0, newline);
        stdoutBuffer = stdoutBuffer.slice(newline + 1);
        handleAgyStreamLine(line, state, callbacks, getSummary);
        newline = stdoutBuffer.indexOf("\n");
      }
    });

    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      stderrText += text;
      process.stderr.write(`[sketchintent-ai] ${text}`);
    });

    child.on("error", (error) => {
      callbacks.abort.removeEventListener("abort", onAbort);
      if (!callbacks.abort.aborted && !state.finished) {
        callbacks.onEvent({ type: "error", message: geminiError(error.message) });
      }
      resolvePromise();
    });

    child.on("close", (code) => {
      callbacks.abort.removeEventListener("abort", onAbort);
      if (stdoutBuffer.trim()) {
        handleAgyStreamLine(stdoutBuffer, state, callbacks, getSummary);
      }
      if (!callbacks.abort.aborted && !state.finished) {
        if (code === 0) {
          callbacks.onSummary(getSummary(), state.blockText.trim());
          callbacks.onEvent({ type: "done" });
        } else {
          const fallback = stderrText.trim().split("\n").at(-1) || `Antigravity exited with code ${code ?? 1}.`;
          callbacks.onEvent({ type: "error", message: geminiError(fallback) });
        }
      }
      resolvePromise();
    });
  });
}
