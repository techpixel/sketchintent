/// An image the agent puts on the iPad canvas: its own rendering of what it thinks the
/// sketch means. The iPad renders the code to an image at the given place, under the ink,
/// so the person can correct it by sketching on top and sending again.

/// "sketch" is the cropped sketch image, the space the voice notes use.
/// "screen" is the whole Mac screen image, when one was sent.
export type CanvasSpace = "sketch" | "screen";

export type ImageFormat = "html" | "svg";

export interface CanvasImage {
  space: CanvasSpace;
  /// Top left and size, in pixels of the image named by `space`.
  x: number;
  y: number;
  width: number;
  height: number;
  /// A complete HTML document. The iPad renders it in a web view the size of the image.
  html: string;
}

/// The Mac relay passes an image on only while its JSON fits in one reply.
export const imageByteLimit = 400_000;
const coordinateLimit = 100_000;

function round(value: number): number {
  return Math.round(Math.max(-coordinateLimit, Math.min(coordinateLimit, value)) * 10) / 10;
}

/// A whole document is kept as written. A fragment or a bare SVG gets a page that fills
/// the image, on white so it reads on the black canvas.
export function toDocument(code: string, format: ImageFormat): string {
  const trimmed = code.trim();
  if (format === "html" && /<html[\s>]/i.test(trimmed)) return trimmed;
  const body =
    format === "svg"
      ? trimmed.replace(/<svg(?![^>]*\bwidth=)/i, '<svg width="100%" height="100%"')
      : trimmed;
  return [
    "<!doctype html>",
    '<html><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<style>html,body{margin:0;width:100%;height:100%;background:#fff;color:#000;",
    "font-family:-apple-system,system-ui,sans-serif;overflow:hidden}</style>",
    `</head><body>${body}</body></html>`,
  ].join("");
}

/// Null when the size is unusable or the code is too large to reach the iPad in one piece.
export function makeImage(
  code: string,
  format: ImageFormat,
  space: CanvasSpace,
  frame: { x: number; y: number; width: number; height: number },
): CanvasImage | null {
  if (!(frame.width >= 1 && frame.height >= 1)) return null;
  const image: CanvasImage = {
    space,
    x: round(frame.x),
    y: round(frame.y),
    width: round(frame.width),
    height: round(frame.height),
    html: toDocument(code, format),
  };
  return Buffer.byteLength(JSON.stringify(image)) <= imageByteLimit ? image : null;
}
