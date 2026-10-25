/// CLI helper that forwards SketchIntent tool calls (remember, show_image, open_on_mac, go_to_desktop)
/// from an agy subprocess to the running SketchIntent AI server on this Mac.

const port = Number(process.env.SKETCHINTENT_AI_PORT ?? 2347);
const [, , toolName, rawArgs] = process.argv;

if (!toolName) {
  console.error("Usage: node sketchintent-tool.ts <remember|show_image|open_on_mac|go_to_desktop> '<json-args>'");
  process.exit(2);
}

let args: Record<string, unknown> = {};
if (rawArgs && rawArgs.trim()) {
  try {
    const parsed: unknown = JSON.parse(rawArgs);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      args = parsed as Record<string, unknown>;
    }
  } catch (error) {
    console.error(`Invalid JSON arguments: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
}

const response = await fetch(`http://127.0.0.1:${port}/v1/tool`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ tool: toolName, args }),
});

const result = (await response.json()) as { output?: string; error?: string };
if (!response.ok || result.error) {
  console.error(result.error ?? `Tool ${toolName} failed with status ${response.status}.`);
  process.exit(1);
}
if (result.output) {
  console.log(result.output);
}

export {};
