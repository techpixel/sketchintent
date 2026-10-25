import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, isAbsolute, join } from "node:path";

/// Files `open` would run instead of show. The agent cannot run commands, so these stay closed.
const runnable = new Set([
  ".app", ".command", ".sh", ".zsh", ".bash", ".csh", ".tool", ".terminal", ".pkg", ".mpkg",
  ".workflow", ".action", ".scpt", ".scptd", ".applescript", ".osax", ".prefpane", ".mobileconfig",
]);

/// The `open` arguments for an app name, a web link, or a file or folder.
/// `with` names the app that should open the link or file. Null when the target is not allowed.
export function openArguments(target: string, withApp?: string): { args: string[] } | { error: string } {
  const value = target.trim();
  const app = withApp?.trim();
  if (!value || value.includes("\0") || app?.includes("\0")) return { error: "Name an app, a web link, or a file." };
  const via = app ? ["-a", app] : [];
  if (/^https?:\/\//i.test(value)) return { args: [...via, value] };
  if (/^[a-z][a-z0-9+.-]*:/i.test(value)) return { error: "Only http and https links can be opened." };
  if (value.startsWith("/") || value.startsWith("~")) {
    if (runnable.has(extname(value.replace(/\/+$/, "")).toLowerCase())) {
      return { error: "That file would run as a program. Open its folder instead." };
    }
    return { args: [...via, expandHome(value)] };
  }
  if (app) return { error: "A relative path cannot be opened. Use a full path." };
  return { args: ["-a", value] };
}

function expandHome(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}

/// Opens a target in front on the Mac. macOS moves to a desktop with the app's windows.
export async function openOnMac(target: string, withApp?: string): Promise<string | null> {
  const parsed = openArguments(target, withApp);
  if ("error" in parsed) return parsed.error;
  const path = parsed.args.at(-1) ?? "";
  if (isAbsolute(path)) {
    try {
      const info = await stat(path);
      // An executable file in a folder of its own would still run when opened.
      if (info.isFile() && (info.mode & 0o111) !== 0) return "That file would run as a program. Open its folder instead.";
    } catch {
      return `Nothing is at ${path}.`;
    }
  }
  return new Promise((resolve) => {
    execFile("/usr/bin/open", parsed.args, { timeout: 15_000 }, (error, _stdout, stderr) => {
      if (!error) resolve(null);
      else resolve(stderr.trim() || error.message);
    });
  });
}
