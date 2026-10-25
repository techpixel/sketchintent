export interface SketchNote {
  text: string;
  x: number;
  y: number;
}

/// One earlier sketch, kept as text so a follow-up does not resend its images.
export interface Memory {
  summary: string;
  reply: string;
}

/// The agent saves each sketch's summary through this tool, and the banner does not show it.
export const rememberToolName = "mcp__sketchintent__remember";

/// The agent's own canvas tool on the sketchintent MCP server.
export const imageToolName = "mcp__sketchintent__show_image";

/// The banner shows "Calling figma-mcp..." from an MCP tool named mcp__figma-mcp__….
export function toolLabel(name: string): string {
  const parts = name.split("__");
  if (parts[0] === "mcp" && parts.length >= 3 && parts[1]) return parts[1];
  return name;
}

/// The status line for a tool call, or null for a call the app does not show.
/// The "canvas" tone shows in blue on the iPad, apart from the agent's other work.
export function toolStatus(name: string): { lead: string; name: string; tone?: "canvas" } | null {
  if (name === rememberToolName) return null;
  if (name === imageToolName) return { lead: "Rendering on ", name: "the canvas", tone: "canvas" };
  return { lead: "Calling ", name: toolLabel(name) };
}

export function buildPrompt(
  width: number,
  height: number,
  notes: SketchNote[],
  screen?: { width: number; height: number },
  folder?: string,
  earlier: Memory[] = [],
  spoken = "",
): string {
  const listed =
    notes.length === 0
      ? "There are no voice notes."
      : notes.map((note) => `- (${Math.round(note.x)}, ${Math.round(note.y)}): ${note.text}`).join("\n");
  const intro = screen
    ? [
        `The first image is the whole Mac screen, ${screen.width} by ${screen.height} pixels, for context. The ink is drawn on it.`,
        `The second image is that screen cropped around the ink and the voice notes. It is ${width} by ${height} pixels. The origin is the top left and y points down.`,
        "Voice notes were recorded on the second image. A note refers to the content nearest its point:",
      ]
    : [
        `The image is ${width} by ${height} pixels. The origin is the top left and y points down.`,
        "It shows the Mac screen with the ink drawn on top.",
        "Voice notes were recorded at these pixels. A note refers to the screen content nearest its point:",
      ];
  const lines = [...intro, listed];
  if (spoken) {
    lines.push(
      `The person also held the dictation button and said this to you directly. It is not attached to any point. It is their main request, and it may refer to the ink and the voice notes: "${spoken}"`,
    );
  }
  if (folder) lines.push(`The working folder on the Mac is ${folder}.`);
  if (earlier.length === 0) return lines.join("\n");
  const history = earlier.map((memory, index) => `${index + 1}. ${memory.summary}\n   You replied: ${memory.reply}`);
  return [
    "This sketch follows earlier ones. Their images are gone; these are the summaries you saved, oldest first:",
    ...history,
    "Words like it, that, or again in the new notes may refer to those sketches.",
    "Ink, notes, and images stay on the page after you answer, so the new sketch may still show marks you already acted on. Act on what is new.",
    "",
    "The new sketch:",
    ...lines,
  ].join("\n");
}

export const systemPrompt = [
  "You act on a sketch drawn over a Mac screen on an iPad.",
  "When two images are attached, the first is the whole screen and the second is the cropped sketch. Voice-note points refer to the second image. Read both.",
  "When one image is attached, it is the cropped sketch, and the notes refer to that image.",
  "When a working folder is named, that folder is the project you are acting on.",
  "The person can also speak to you directly, without a sketch. Then the image is the whole page they were looking at, and there may be no ink.",
  "Carry out what the sketch and the notes ask. Use a configured MCP tool when it can do that, and load the matching skill before you use it.",
  "The canvas is where you ask for feedback. Put anything you want the person to check there with show_image, rendered from HTML, CSS, SVG, or a canvas script: your reading of a sketch you are not sure you understood, a layout or design you are proposing, or a result you want approved before you act on it. The image goes on the iPad's Canvas page, a blank page apart from the Mac screen, and the iPad switches to that page so the person can annotate it.",
  "Read the sketch honestly. If any part of it is ambiguous (a rough shape, an unclear arrow, a scribble that could be several things, a size or position you are estimating), render your best reading instead of guessing silently, and do not make changes elsewhere that depend on that reading until the person has seen it.",
  "Coordinates pick where on the iPad's screen the image lands on the Canvas. They are pixels in the cropped sketch image, the space the voice notes use, unless you choose the whole screen image. When the sketch was drawn on the Canvas, place the image beside the part it interprets without covering their ink, unless you are redrawing that part in place. Say in your reply what you rendered and what you want them to check.",
  "The person answers by sketching and adding voice notes on top of your image, then sends again. The next sketch shows your image with their marks, so treat those marks as corrections to it.",
  "Before your final reply, call the remember tool once. Summarize what the screen showed, what the ink marked, what the notes asked, and what you did, with any file paths, URLs, or IDs a follow-up sketch would need. Later sketches see only this summary, not the images.",
  "The app shows tool calls on its own. Reply with one short sentence, in the first person, about what you are doing.",
].join(" ");
