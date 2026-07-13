/**
 * Stable device identity for PTY size ownership (server side:
 * Dala.Terminal.Server). One UUID per browser profile, persisted in
 * localStorage: every terminal-channel join sends it, and the session's
 * size sticks to the DEVICE that owns it — reloads and reconnects of the
 * same browser silently re-own, while other devices become followers until
 * they explicitly take over.
 *
 * A raw string (not JSON), so it deliberately doesn't ride on createStore.
 * When storage is unavailable the id is memoized per page load — ownership
 * then lasts one session, which degrades to the old per-connection model.
 */

const KEY = "dala:device-id";

let memoized: string | null = null;

function generate(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // RFC 4122 v4 shape from Math.random — good enough for a device label.
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export function getDeviceId(): string {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored) return stored;
  } catch {
    // storage unavailable — fall through to the memoized id
  }
  if (!memoized) memoized = generate();
  try {
    localStorage.setItem(KEY, memoized);
  } catch {
    // storage unavailable — the memo keeps it stable for this page load
  }
  return memoized;
}
