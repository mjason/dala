import React from "react";

/** Platform-aware shortcut labels: ⌘ on Apple devices, Ctrl elsewhere. */
export const isMac: boolean =
  typeof navigator !== "undefined" && /Mac|iP(hone|ad|od)/.test(navigator.platform);

export const modLabel = isMac ? "⌘" : "Ctrl";

export function modCombo(key: string): string {
  return isMac ? `⌘${key.toUpperCase()}` : `Ctrl+${key.toUpperCase()}`;
}

export function modShiftCombo(key: string): string {
  return isMac ? `⇧⌘${key.toUpperCase()}` : `Ctrl+Shift+${key.toUpperCase()}`;
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

/**
 * Styled hover tooltip for toolbar buttons: action name, optional shortcut
 * badge and a one-line description — richer and faster than the native
 * `title` bubble. Anchored below the trigger, right-aligned (the header sits
 * at the top-right edge of the viewport).
 */
export function Tooltip({
  label,
  description,
  keys,
  children,
}: {
  label: string;
  description?: string;
  keys?: string;
  children: React.ReactNode;
}) {
  return (
    <span className="group/tip relative inline-flex">
      {children}
      <span
        role="tooltip"
        className="pointer-events-none invisible absolute right-0 top-full z-50 mt-1.5 flex w-max max-w-[17rem] flex-col gap-1 rounded-lg border border-line bg-bg1 px-2.5 py-2 opacity-0 shadow-xl shadow-black/40 transition-opacity delay-150 duration-100 group-hover/tip:visible group-hover/tip:opacity-100"
      >
        <span className="flex items-center gap-2 text-[12px] font-medium text-fg">
          {label}
          {keys && <Kbd>{keys}</Kbd>}
        </span>
        {description && (
          <span className="text-[11px] leading-4 text-fg-muted">{description}</span>
        )}
      </span>
    </span>
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
