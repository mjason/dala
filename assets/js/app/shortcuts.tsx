import React from "react";

/** Platform-aware shortcut labels: ⌘ on Apple devices, Ctrl elsewhere. */
export const isMac: boolean =
  typeof navigator !== "undefined" && /Mac|iP(hone|ad|od)/.test(navigator.platform);

export const modLabel = isMac ? "⌘" : "Ctrl";

export function modCombo(key: string): string {
  return isMac ? `⌘${key.toUpperCase()}` : `Ctrl+${key.toUpperCase()}`;
}

/** True when the event happened inside a text-entry element. */
export function inTextInput(e: { target: EventTarget | null }): boolean {
  const el = e.target as HTMLElement | null;
  if (!el) return false;
  if (el.closest?.("input, textarea, select, [contenteditable=true]")) return true;
  return false;
}

// Stacked Windowed instances: Escape must only close the topmost one, and
// panels underneath must know a window is still open.
const windowStack: symbol[] = [];

export function pushWindow(): symbol {
  const token = Symbol("window");
  windowStack.push(token);
  return token;
}

export function popWindow(token: symbol): void {
  const index = windowStack.indexOf(token);
  if (index >= 0) windowStack.splice(index, 1);
}

export function isTopWindow(token: symbol): boolean {
  return windowStack[windowStack.length - 1] === token;
}

export function hasOpenWindows(): boolean {
  return windowStack.length > 0;
}

export function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded border border-line bg-bg0 px-1 py-px font-mono text-[9px] leading-4 text-fg-muted">
      {children}
    </kbd>
  );
}

/** A `⌨ label` pair for hint bars. */
export function KeyHint({ keys, label }: { keys: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1 whitespace-nowrap">
      <Kbd>{keys}</Kbd>
      {label}
    </span>
  );
}
