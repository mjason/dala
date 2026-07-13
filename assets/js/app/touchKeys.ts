/** Touch key bar → PTY byte sequences.
 *
 * Soft keyboards have no Esc/Tab/Ctrl/arrows, so the bar above the composer
 * strip sends them for TUIs. Ctrl is a sticky modifier (like mobile shift):
 * one tap latches it, the next key — a bar key here, or a single character
 * typed on the soft keyboard (see `applyCtrl`) — goes out with Ctrl applied,
 * then the latch releases.
 */

/** Keys on the bar (the buttons' `data-key` values); Ctrl itself is a
 * modifier, not a key. */
export type BarKey = "esc" | "tab" | "up" | "down" | "left" | "right" | "ctrl-c";

const PLAIN: Record<BarKey, string> = {
  esc: "\x1b",
  tab: "\t",
  up: "\x1b[A",
  down: "\x1b[B",
  left: "\x1b[D",
  right: "\x1b[C",
  "ctrl-c": "\x03",
};

/** Ctrl variants where one exists: xterm-style CSI 1;5 arrows (word
 * movement in shells/editors). Esc, Tab and ^C have no distinct Ctrl form
 * worth sending — they fall back to their plain sequence. */
const CTRL: Partial<Record<BarKey, string>> = {
  up: "\x1b[1;5A",
  down: "\x1b[1;5B",
  left: "\x1b[1;5D",
  right: "\x1b[1;5C",
};

/** The bytes a bar key sends, honoring a latched Ctrl. */
export function sequenceFor(key: BarKey, ctrl: boolean): string {
  return (ctrl && CTRL[key]) || PLAIN[key];
}

/**
 * Ctrl applied to ONE character typed on the soft keyboard: the classic
 * C0 mapping (`c` → \x03, `d` → \x04, `[` → \x1b, space → NUL, `?` → DEL).
 * Returns null when Ctrl cannot apply — multi-character input (IME commit,
 * paste) or a character outside the control range — so the caller keeps
 * the data untouched and the latch armed.
 */
export function applyCtrl(data: string): string | null {
  if (data.length !== 1) return null;
  if (data === " ") return "\x00";
  if (data === "?") return "\x7f";
  const code = data.toUpperCase().charCodeAt(0);
  // @ A–Z [ \ ] ^ _ → subtract 64 into the C0 control range.
  if (code >= 64 && code <= 95) return String.fromCharCode(code - 64);
  return null;
}

/** Latch state after a tap: Ctrl toggles itself; any sent key consumes it. */
export function nextLatch(key: BarKey | "ctrl", ctrl: boolean): boolean {
  return key === "ctrl" ? !ctrl : false;
}
