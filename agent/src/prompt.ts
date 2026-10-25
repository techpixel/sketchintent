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

/// The iPad page a sketch was drawn on. `index` is zero-based, and -1 is a fullscreen app.
export type DrawnOn = { page: "canvas" } | { page: "desktop"; index: number; count: number };

function drawnOnLine(drawnOn: DrawnOn): string {
  if (drawnOn.page === "canvas") return "The sketch was drawn on the iPad's Canvas page, not over a Mac desktop.";
  if (drawnOn.index < 0) return "The sketch was drawn over a fullscreen app on the Mac, not on one of its numbered desktops.";
  return `The sketch was drawn over Mac desktop ${drawnOn.index + 1} of ${drawnOn.count}, counted from the left in Mission Control.`;
}

/// The agent saves each sketch's summary through this tool, and the banner does not show it.
export const rememberToolName = "mcp__sketchintent__remember";

/// The agent's own canvas tool on the sketchintent MCP server.
export const imageToolName = "mcp__sketchintent__show_image";

/// The agent's tools that move the Mac screen the iPad is showing.
export const openToolName = "mcp__sketchintent__open_on_mac";
export const desktopToolName = "mcp__sketchintent__go_to_desktop";

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
  if (name === openToolName) return { lead: "Opening on ", name: "the Mac" };
  if (name === desktopToolName) return { lead: "Switching ", name: "Mac desktop" };
  if (name === "Bash") return { lead: "Running ", name: "a command" };
  if (name === "Write" || name === "Edit" || name === "NotebookEdit") return { lead: "Editing ", name: "files" };
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
  drawnOn?: DrawnOn,
  live?: { moment: number },
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
  if (spoken && live) {
    lines.push(
      `Since the last moment the person said this, transcribed as they spoke. It is not attached to any point, and it may refer to the ink and the voice notes: "${spoken}"`,
    );
  } else if (live) {
    lines.push("Nothing was said since the last moment. The person only drew.");
  } else if (spoken) {
    lines.push(
      `The person also held the dictation button and said this to you directly. It is not attached to any point. It is their main request, and it may refer to the ink and the voice notes: "${spoken}"`,
    );
  }
  if (drawnOn) lines.push(drawnOnLine(drawnOn));
  if (folder) lines.push(`The working folder on the Mac is ${folder}.`);
  if (live) lines.unshift(`Live moment ${live.moment}.`);
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
  "The working folder named in the prompt is the project you are acting on, and the current directory. You have the full Claude Code toolset there: read and write files, run commands, install packages, build, and test.",
  "When the sketch asks for an app, a page, or a change to code, build it for real in that folder. If the folder holds unrelated things and the request is a new project, make a new subfolder for it. Build or run it to check it works, then show the result with open_on_mac.",
  "The person can also speak to you directly, without a sketch. Then the image is the whole page they were looking at, and there may be no ink.",
  "Carry out what the sketch and the notes ask. Use a configured MCP tool when it can do that, and load the matching skill before you use it.",
  "The canvas is where you ask for feedback. Put anything you want the person to check there with show_image, rendered from HTML, CSS, SVG, or a canvas script: your reading of a sketch you are not sure you understood, a layout or design you are proposing, or a result you want approved before you act on it. The image goes on the iPad's Canvas page, a blank page apart from the Mac screen, and the iPad switches to that page so the person can annotate it.",
  "Read the sketch honestly. If any part of it is ambiguous (a rough shape, an unclear arrow, a scribble that could be several things, a size or position you are estimating), render your best reading instead of guessing silently, and do not make changes elsewhere that depend on that reading until the person has seen it.",
  "Coordinates pick where on the iPad's screen the image lands on the Canvas. They are pixels in the cropped sketch image, the space the voice notes use, unless you choose the whole screen image. When the sketch was drawn on the Canvas, place the image beside the part it interprets without covering their ink, unless you are redrawing that part in place. Say in your reply what you rendered and what you want them to check.",
  "The person answers by sketching and adding voice notes on top of your image, then sends again. The next sketch shows your image with their marks, so treat those marks as corrections to it.",
  "To show the person something on the Mac, open it with open_on_mac, or move to the desktop it is on with go_to_desktop. Both put the iPad back on the Mac screen. Do not open things the sketch did not ask for.",
  "Before your final reply, call the remember tool once. Summarize what the screen showed, what the ink marked, what the notes asked, and what you did, with any file paths, URLs, or IDs a follow-up sketch would need. Later sketches see only this summary, not the images.",
  "The app shows tool calls on its own. Reply in one or two short sentences, in the first person, about what you did and where it is.",
].join(" ");

/// What a live moment's reply is when the moment needs nothing yet. The iPad shows nothing for it.
export const liveQuietReply = "…";

/// True for a reply, or the start of one, that is only the quiet reply.
export function isQuietReply(text: string): boolean {
  return /^[\s.…]*$/.test(text);
}

/// Appended to the system prompt for live moments.
export const liveSystemLines = [
  "Live mode is on. The person talks and sketches continuously, and you receive a moment each time they pause: what they said since the last moment, transcribed as they spoke, and the page as it is now.",
  "Ink you read is wiped from the page once you answer, so the ink in a moment is new. Your images on the Canvas stay.",
  `Speech may be a fragment, thinking out loud, or talk to someone else in the room. Act when a moment asks for something, or when the ink and the words together make a request clear. When a moment needs nothing from you yet, call no tools and reply with only ${liveQuietReply}; the iPad shows nothing for that reply.`,
  "Moments wait while you work, so keep each turn short.",
].join(" ");
