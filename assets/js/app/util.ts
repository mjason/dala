export function base64ToBytes(b64: string): Uint8Array {
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

export function humanBytes(size: number): string {
  if (size < 1024) return `${size} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = size;
  let unit = "";
  for (const u of units) {
    value /= 1024;
    unit = u;
    if (value < 1024) break;
  }
  return `${value >= 10 ? Math.round(value) : value.toFixed(1)} ${unit}`;
}

export function shortPath(path: string, max = 34): string {
  if (path.length <= max) return path;
  const parts = path.split("/");
  let tail = parts.pop() ?? "";
  if (tail.length > max - 2) tail = "…" + tail.slice(-(max - 2));
  return `…/${tail}`;
}

export function timeAgo(iso: string | null): string {
  if (!iso) return "";
  const then = new Date(iso).getTime();
  const seconds = Math.max(0, (Date.now() - then) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

/**
 * Session scrollback_limit → emulator history lines. Values above 100k are
 * legacy byte limits from the retired disk cache (~120 bytes/line).
 */
export function historyLines(stored: number): number {
  const lines = stored > 100_000 ? Math.round(stored / 120) : stored;
  return Math.min(Math.max(lines || 10_000, 1_000), 50_000);
}

/**
 * Clipboard write that also works on insecure origins (plain-http LAN
 * access has no navigator.clipboard): falls back to a transient textarea +
 * execCommand("copy"), restoring focus afterwards.
 */
export async function writeClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // fall through to execCommand
  }

  const previous = document.activeElement as HTMLElement | null;
  const scratch = document.createElement("textarea");
  scratch.value = text;
  scratch.style.position = "fixed";
  scratch.style.opacity = "0";
  document.body.appendChild(scratch);
  scratch.select();
  let copied = false;
  try {
    copied = document.execCommand("copy");
  } finally {
    scratch.remove();
    previous?.focus?.();
  }
  return copied;
}
